import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "dev_profile.py"


class DevProfileTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.home = self.root / "installed"
        self.home.mkdir()
        self.sentinel = self.home / "sentinel"
        self.sentinel.write_text("installed state")
        self.env = {**os.environ, "HOME": str(self.home), "XDG_CONFIG_HOME": str(self.home),
                    "ANTHROPIC_API_KEY": "synthetic-installed-key"}

    def worktree(self, name):
        root = self.root / name
        (root / "scripts").mkdir(parents=True)
        shutil.copy(SCRIPT, root / "scripts")
        (root / "bin" / "lib").mkdir(parents=True)
        shutil.copy(SCRIPT.parents[1] / "bin" / "minga", root / "bin")
        launcher = root / "bin" / "lib" / "minga"
        launcher.write_text(f"#!{sys.executable}\n" +
                            "import json, os, pathlib, sys\n"
                            "config = pathlib.Path(os.environ['XDG_CONFIG_HOME']) / 'sentinel'\n"
                            "print(json.dumps([config.read_text() if config.exists() else None, os.environ.get('ANTHROPIC_API_KEY')]), flush=True)\n"
                            "config.write_text(sys.argv[1])\n"
                            "if len(sys.argv) > 2: input()\n")
        launcher.chmod(0o700)
        return root

    def cmd(self, *args):
        if args[:2] == ("launch", "minga"):
            return ["bin/minga", *args[2:]]
        return [sys.executable, "scripts/dev_profile.py", *args]

    def call(self, tree, *args, check=True):
        env = {**self.env, "MINGA_DEV_PROFILE": str(tree / ".minga-dev" / "profile")}
        return subprocess.run(self.cmd(*args), cwd=tree, env=env, text=True,
                              capture_output=True, check=check, timeout=10)

    def test_launch_keeps_worktree_profiles_separate_and_fresh_runs_disposable(self):
        first, second = self.worktree("first"), self.worktree("second")
        for tree, mode, value, previous in [
            (first, "launch", "first run", None), (second, "launch", "second", None),
            (first, "fresh", "disposable", None), (first, "launch", "next", "first run"),
        ]:
            result = self.call(tree, mode, "minga", value)
            self.assertEqual(json.loads(result.stdout), [previous, None])
        self.call(first, "clean")
        self.assertEqual(json.loads(self.call(first, "launch", "minga", "reset").stdout), [None, None])
        self.assertEqual(json.loads(self.call(second, "launch", "minga", "next").stdout), ["second", None])
        self.assertEqual(self.sentinel.read_text(), "installed state")

    def test_launch_keeps_the_login_name_for_build_tools(self):
        tree = self.worktree("login")
        (tree / "bin" / "lib" / "minga").write_text(
            f"#!{sys.executable}\n"
            "import json, os\n"
            "print(json.dumps([os.environ.get('USER'), os.environ.get('LOGNAME')]), flush=True)\n")
        self.env.update(USER="synthetic-user", LOGNAME="synthetic-user")
        result = self.call(tree, "launch", "minga")
        self.assertEqual(json.loads(result.stdout), ["synthetic-user", "synthetic-user"])

    def test_clean_refuses_a_running_launcher_and_a_symlink(self):
        tree = self.worktree("source")
        with subprocess.Popen(self.cmd("launch", "minga", "live", "wait"), cwd=tree, env=self.env,
                              text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as launch:
            try:
                self.assertEqual(json.loads(launch.stdout.readline()), [None, None])
                refused = self.call(tree, "clean", check=False)
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn("profile is in use", refused.stderr)
            finally:
                launch.communicate("\n", timeout=10)
        self.call(tree, "clean")
        (tree / ".minga-dev" / "profile").symlink_to(self.home, target_is_directory=True)
        self.assertNotEqual(self.call(tree, "clean", check=False).returncode, 0)
        self.assertEqual(self.sentinel.read_text(), "installed state")


if __name__ == "__main__":
    unittest.main()
