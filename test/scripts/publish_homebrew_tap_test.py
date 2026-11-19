"""Drive tap promotion against a disposable bare repository, never GitHub."""

import importlib.machinery
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/publish-homebrew-tap"
LOADER = importlib.machinery.SourceFileLoader("publish_homebrew_tap", str(SCRIPT))
PROMOTION = importlib.util.module_from_spec(importlib.util.spec_from_loader(LOADER.name, LOADER))
LOADER.exec_module(PROMOTION)

SOURCE = "a" * 40
FORMULA = "Formula/minga.rb"
CASK = "Casks/minga-mac.rb"
MAIN = "refs/heads/main"


def recipes(version, checksum="1" * 64):
    return {
        FORMULA: (f'class Minga < Formula\n  version "{version}"\n  on_arm do\n'
                  f'    sha256 "{checksum}"\n  end\nend\n').encode(),
        CASK: (f'cask "minga-mac" do\n  version "{version}"\n  sha256 "{checksum}"\nend\n').encode(),
    }


class PublishHomebrewTapTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="minga tap ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.remote = self.root / "tap.git"
        self.writer = self.root / "writer"
        self.git("init", "--bare", "--initial-branch=main", self.remote)
        self.git("init", "--initial-branch=main", self.writer)
        self.git("remote", "add", "origin", self.remote.as_uri(), cwd=self.writer)
        (self.writer / "README.md").write_text("unrelated tap content\n", encoding="utf-8")

    def git(self, *args, cwd=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        return subprocess.run(
            ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", *map(str, args)],
            cwd=cwd or self.root, env=env, check=True, capture_output=True,
        ).stdout

    def seed(self, pair):
        for recipe, data in pair.items():
            path = self.writer / recipe
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.git("add", "--all", cwd=self.writer)
        self.git("commit", "-m", "Seed tap", cwd=self.writer)
        self.git("push", "origin", MAIN, cwd=self.writer)
        return self.tip()

    def tip(self):
        return self.git("rev-parse", MAIN, cwd=self.remote).strip().decode("ascii")

    def bundle(self, version, name="bundle", checksum="1" * 64):
        base, run = version.split("-dev.")
        bundle = self.root / name
        bundle.mkdir()
        for path, data in recipes(f"{base}beta{run}", checksum).items():
            (bundle / Path(path).name).write_bytes(data)
        return bundle

    def promote(self, action, bundle, version, worktree, *, source=SOURCE):
        return PROMOTION.promote(action, bundle, version, source, worktree, remote=self.remote.as_uri())

    def test_bootstraps_with_one_commit_for_both_exact_recipes(self):
        baseline = self.seed(recipes("0.1.0", "PLACEHOLDER"))
        version = "0.1.0-dev.10"
        bundle = self.bundle(version)
        worktree = self.root / "prepared"
        self.assertEqual(self.promote("prepare", bundle, version, worktree), "publish")
        self.assertEqual(self.tip(), baseline)
        self.assertEqual(self.git("rev-parse", "--is-shallow-repository", cwd=worktree), b"true\n")
        self.assertEqual(self.git("rev-parse", "HEAD^", cwd=worktree).strip().decode(), baseline)

        self.promote("push", bundle, version, worktree)
        self.assertEqual(self.tip(), self.git("rev-parse", "HEAD", cwd=worktree).strip().decode())
        self.assertEqual(self.git("rev-list", "--count", MAIN, cwd=self.remote), b"2\n")
        paths = self.git("diff-tree", "--no-commit-id", "--name-only", "-r", MAIN, cwd=self.remote)
        self.assertEqual(set(paths.decode().splitlines()), {FORMULA, CASK})
        for recipe in (FORMULA, CASK):
            self.assertEqual(self.git("show", f"{MAIN}:{recipe}", cwd=self.remote),
                             (bundle / Path(recipe).name).read_bytes())

        fresh = self.root / "retry"
        self.assertEqual(self.promote("prepare", bundle, version, fresh), "current")
        with self.assertRaisesRegex(ValueError, "rev-parse"):
            self.promote("push", bundle, version, fresh)

    def test_orders_both_the_release_base_and_workflow_run_numerically(self):
        baseline = self.seed(recipes("0.9.0beta10"))
        for index, (version, expected) in enumerate((
            ("0.9.0-dev.9", "stale"), ("0.9.0-dev.11", "publish"),
            ("0.8.0-dev.11", "stale"), ("0.10.0-dev.9", "stale"),
            ("0.10.0-dev.11", "publish"),
        )):
            with self.subTest(version=version):
                bundle = self.bundle(version, name=f"bundle-{index}")
                self.assertEqual(self.promote("prepare", bundle, version, self.root / f"tap-{index}"), expected)
        self.assertEqual(self.tip(), baseline)

    def test_does_not_supersede_a_real_stable_release_with_an_older_beta(self):
        baseline = self.seed(recipes("1.2.3"))
        for index, (version, expected) in enumerate((
            ("1.1.0-dev.1000", "stale"), ("1.2.3-dev.1000", "stale"), ("1.2.4-dev.1001", "publish"),
        )):
            with self.subTest(version=version):
                bundle = self.bundle(version, name=f"bundle-{index}")
                self.assertEqual(self.promote("prepare", bundle, version, self.root / f"tap-{index}"), expected)
        self.assertEqual(self.tip(), baseline)

    def test_rejects_inconsistent_or_ambiguous_tap_recipes(self):
        version = "0.1.0-dev.11"
        bundle = self.bundle(version)
        stable = recipes("0.1.0")
        placeholder = recipes("0.1.0", "PLACEHOLDER")
        ahead = recipes("0.1.0beta10")
        for index, (pair, error) in enumerate((
            ({FORMULA: stable[FORMULA], CASK: ahead[CASK]}, "versions disagree"),
            ({FORMULA: placeholder[FORMULA], CASK: stable[CASK]}, "paired .* placeholders"),
            ({FORMULA: stable[FORMULA], CASK: stable[CASK] + b'version "0.1.0"\n'}, "one explicit"),
            ({FORMULA: stable[FORMULA], CASK: stable[CASK].replace(b'"0.1.0"', b':latest')}, "one explicit"),
        )):
            with self.subTest(error=error):
                baseline = self.seed(pair)
                with self.assertRaisesRegex(ValueError, error):
                    self.promote("prepare", bundle, version, self.root / f"tap-{index}")
                self.assertEqual(self.tip(), baseline)

    def test_same_workflow_run_cannot_change_recipe_bytes_or_release_base(self):
        baseline = self.seed(recipes("0.1.0beta10"))
        for version in ("0.1.0-dev.10", "0.2.0-dev.10"):
            with self.subTest(version=version):
                bundle = self.bundle(version, name=version, checksum="2" * 64)
                with self.assertRaisesRegex(ValueError, "different recipes for this run number"):
                    self.promote("prepare", bundle, version, self.root / f"tap-{version}")
                self.assertEqual(self.tip(), baseline)

    def test_push_requires_the_prepared_commit_source_and_exact_bundle(self):
        baseline = self.seed(recipes("0.1.0beta9"))
        version = "0.1.0-dev.10"
        bundle = self.bundle(version)
        changed = self.bundle(version, name="changed", checksum="2" * 64)
        worktree = self.root / "prepared"
        self.assertEqual(self.promote("prepare", bundle, version, worktree), "publish")
        with self.assertRaisesRegex(ValueError, "identity does not match"):
            self.promote("push", bundle, version, worktree, source="b" * 40)
        with self.assertRaisesRegex(ValueError, "exact verified formula and cask"):
            self.promote("push", changed, version, worktree)
        self.git("remote", "set-url", "--push", "origin", (self.root / "elsewhere").as_uri(), cwd=worktree)
        with self.assertRaisesRegex(ValueError, "origin does not match"):
            self.promote("push", bundle, version, worktree)
        self.git("commit", "--allow-empty", "-m", "Replace prepared HEAD", cwd=worktree)
        with self.assertRaisesRegex(ValueError, "HEAD changed"):
            self.promote("push", bundle, version, worktree)
        self.assertEqual(self.tip(), baseline)

    def test_concurrent_update_requires_fresh_prepare(self):
        self.seed(recipes("0.1.0beta9"))
        first, second = "0.1.0-dev.10", "0.1.0-dev.11"
        first_bundle, second_bundle = self.bundle(first, name=first), self.bundle(second, name=second)
        first_tap, second_tap = self.root / "first", self.root / "second"
        self.assertEqual(self.promote("prepare", first_bundle, first, first_tap), "publish")
        self.assertEqual(self.promote("prepare", second_bundle, second, second_tap), "publish")
        self.promote("push", first_bundle, first, first_tap)
        advanced = self.tip()
        with self.assertRaisesRegex(ValueError, "tap main advanced"):
            self.promote("push", second_bundle, second, second_tap)
        self.assertEqual(self.tip(), advanced)

        refreshed = self.root / "refreshed"
        self.assertEqual(self.promote("prepare", second_bundle, second, refreshed), "publish")
        self.promote("push", second_bundle, second, refreshed)
        self.assertEqual(self.promote("prepare", first_bundle, first, self.root / "stale"), "stale")

    def test_candidate_identity_is_validated_before_cloning(self):
        bundle = self.bundle("0.1.0-dev.10")
        worktree = self.root / "uncreated"
        for version, source, error in (
            ("0.1.0-dev.0", SOURCE, "canonical"), ("0.1.0-dev.01", SOURCE, "canonical"),
            ("0.1.0-dev.10", "A" * 40, "SOURCE_SHA"), ("0.1.0-dev.11", SOURCE, "do not match VERSION"),
        ):
            with self.subTest(version=version, source=source):
                with self.assertRaisesRegex(ValueError, error):
                    self.promote("prepare", bundle, version, worktree, source=source)
                self.assertFalse(worktree.exists())

    def test_cli_requires_the_tap_token_and_prints_no_status_on_failure(self):
        env = {key: value for key, value in os.environ.items() if key != "HOMEBREW_TAP_TOKEN"}
        result = subprocess.run([SCRIPT, "prepare", "missing", "0.1.0-dev.10", SOURCE, "unused"],
                                cwd=self.root, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("HOMEBREW_TAP_TOKEN is required", result.stderr)


if __name__ == "__main__":
    unittest.main()
