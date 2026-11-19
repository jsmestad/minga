"""Offline tests for the Homebrew Formula generator's CLI."""

import hashlib
import io
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/render-tui-formula"
VERSION = "1.2.3"


class RenderTuiFormulaTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="minga formula ")
        self.addCleanup(temporary.cleanup)
        self.arm64 = Path(temporary.name) / "minga_macos_aarch64.tar.gz"
        self.intel = Path(temporary.name) / "minga_macos_x86_64.tar.gz"
        for archive_path, data in ((self.arm64, b"arm launch fixture"), (self.intel, b"intel launch fixture")):
            with tarfile.open(archive_path, "w:gz") as archive:
                launcher = tarfile.TarInfo("minga/launchers/minga")
                launcher.mode = 0o755
                launcher.size = len(data)
                archive.addfile(launcher, io.BytesIO(data))

    def render(self, version=VERSION, arm64=None, intel=None):
        args = [str(SCRIPT), "--arm64", str(arm64 or self.arm64), "--x86-64", str(intel or self.intel)]
        if version is not None:
            args += ["--version", version]
        return subprocess.run(args, capture_output=True, text=True)

    def assert_rejected(self, result, diagnostic):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn(diagnostic, result.stderr)

    def test_pins_both_architectures_to_the_explicit_release_and_final_bytes(self):
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        formula = result.stdout
        self.assertIn("class Minga < Formula\n", formula)
        self.assertIn(f'  version "{VERSION}"\n', formula)
        for arch, archive in (("arm", self.arm64), ("intel", self.intel)):
            with self.subTest(arch=arch):
                sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()
                url = f"https://github.com/jsmestad/minga/releases/download/v{VERSION}/{archive.name}"
                self.assertIn(f'  on_{arch} do\n    url "{url}"\n    sha256 "{sha256}"\n  end\n', formula)
        self.assertIn("  depends_on macos: :sequoia\n", formula)
        self.assertIn('    libexec.install Dir.children(".")\n    bin.install_symlink libexec/"launchers/minga"\n', formula)
        self.assertIn('    assert_equal "minga #{version}", shell_output("#{bin}/minga --version").strip\n', formula)
        self.assertNotIn(str(self.arm64.parent), formula)

    def test_requires_an_explicit_release_version(self):
        for version in ("latest", "v1.2.3", "1.2.3/../latest", '1.2.3"', "1.2.3\n"):
            with self.subTest(version=version):
                self.assert_rejected(self.render(version=version), "explicit release version")
        self.assert_rejected(self.render(version=None), "--version")

    def test_rejects_an_archive_for_the_other_architecture(self):
        self.assert_rejected(self.render(arm64=self.intel, intel=self.arm64), "expected minga_macos_aarch64.tar.gz")

    def test_does_not_emit_a_partial_formula_when_the_second_archive_is_unavailable(self):
        self.intel.unlink()
        self.assert_rejected(self.render(), self.intel.name)
        self.intel.touch()
        self.assert_rejected(self.render(), "not a nonempty archive file")


if __name__ == "__main__":
    unittest.main()
