"""Offline tests for the Homebrew recipe generator's CLI."""

import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/render-tui-formula"
VERSION = "1.2.3"
RELEASE_URL = "https://github.com/jsmestad/minga/releases/download"


class RenderTuiFormulaTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="minga formula ")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.arm64 = root / "minga_macos_aarch64.tar.gz"
        self.intel = root / "minga_macos_x86_64.tar.gz"
        self.dmg = root / "Minga.dmg"
        self.dmg.write_bytes(b"GUI disk image fixture")
        self.output = root / "Homebrew recipes"
        for archive_path, data in ((self.arm64, b"arm launch fixture"), (self.intel, b"intel launch fixture")):
            with tarfile.open(archive_path, "w:gz") as archive:
                launcher = tarfile.TarInfo("minga/launchers/minga")
                launcher.mode = 0o755
                launcher.size = len(data)
                archive.addfile(launcher, io.BytesIO(data))

    def render(self, version=VERSION, arm64=None, intel=None, *, dmg=None, output=None):
        args = [str(SCRIPT), "--arm64", str(arm64 or self.arm64), "--x86-64", str(intel or self.intel)]
        if version is not None:
            args += ["--version", version]
        if dmg is not None:
            args += ["--dmg", str(dmg)]
        if output is not None:
            args += ["--output", str(output)]
        return subprocess.run(args, capture_output=True, text=True)

    def recipe_pair(self, version=VERSION, output=None):
        output = self.output if output is None else output
        result = self.render(version=version, dmg=self.dmg, output=output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual({path.name for path in output.iterdir()}, {"minga.rb", "minga-mac.rb"})
        return tuple((output / name).read_text(encoding="utf-8") for name in ("minga.rb", "minga-mac.rb"))

    def assert_cask(self, cask, display_version, package_version, asset):
        self.assertIn('cask "minga-mac" do\n', cask)
        self.assertIn(f'  version "{package_version}"\n', cask)
        self.assertIn(f'  url "{RELEASE_URL}/v{display_version}/{asset}"\n', cask)
        self.assertIn(f'  sha256 "{hashlib.sha256(self.dmg.read_bytes()).hexdigest()}"\n', cask)
        self.assertIn("  depends_on arch: :arm64\n", cask)
        self.assertIn("  depends_on macos: :sequoia\n", cask)
        self.assertIn('  app "Minga.app"\n', cask)
        self.assertIn(
            '  zap trash: [\n'
            '    "~/Library/Application Support/minga",\n'
            '    "~/Library/Preferences/com.minga.minga-mac.plist",\n'
            '    "~/Library/Caches/com.minga.minga-mac",\n'
            '  ]\n',
            cask,
        )
        self.assertNotIn(str(self.dmg.parent), cask)

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
                url = f"{RELEASE_URL}/v{VERSION}/{archive.name}"
                self.assertIn(f'  on_{arch} do\n    url "{url}"\n    sha256 "{sha256}"\n  end\n', formula)
        self.assertIn("  depends_on macos: :sequoia\n", formula)
        self.assertIn('    libexec.install Dir.children(".")\n    bin.install_symlink libexec/"launchers/minga"\n', formula)
        self.assertIn('    assert_equal "minga #{version}", shell_output("#{bin}/minga --version").strip\n', formula)
        self.assertNotIn(str(self.arm64.parent), formula)

    def test_stable_pair_preserves_stdout_formula_and_tap_cask(self):
        self.output.mkdir()
        formula, cask = self.recipe_pair()
        self.assertEqual(formula, self.render().stdout)
        self.assert_cask(cask, VERSION, VERSION, "Minga.dmg")

    def test_rolling_pair_pins_versioned_assets_and_keeps_runtime_version(self):
        display_version = "3.14.5-dev.42"
        package_version = "3.14.5beta42"
        formula, cask = self.recipe_pair(display_version)
        self.assertIn(f'  version "{package_version}"\n', formula)
        self.assertIn(
            f'    assert_equal "minga {display_version}", shell_output("#{{bin}}/minga --version").strip\n',
            formula,
        )
        for arch, suffix, archive in (("arm", "aarch64", self.arm64), ("intel", "x86_64", self.intel)):
            with self.subTest(arch=arch):
                sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()
                url = f"{RELEASE_URL}/v{display_version}/minga_{display_version}_macos_{suffix}.tar.gz"
                self.assertIn(f'  on_{arch} do\n    url "{url}"\n    sha256 "{sha256}"\n  end\n', formula)
        self.assert_cask(cask, display_version, package_version, f"Minga_{display_version}.dmg")

    def test_formula_upgrades_to_stable_and_homebrew_loads_the_cask(self):
        brew = shutil.which("brew")
        if brew is None:
            self.skipTest("Homebrew is unavailable")

        versions = []
        for display_version in (f"{VERSION}-dev.9", f"{VERSION}-dev.10", VERSION):
            recipes = self.recipe_pair(display_version, output=self.output / display_version)
            versions.append(re.search(r'^  version "([^"]+)"$', recipes[0], re.MULTILINE)[1])
        orderings = json.dumps(versions)
        ruby = f'''require "version"
older, newer, stable = {orderings}
unless Version.new(older) < Version.new(newer) && Version.new(newer) < Version.new(stable)
  abort "expected #{{older}} < #{{newer}} < #{{stable}} in Homebrew"
end
if RUBY_PLATFORM.include?("darwin")
  require "cask/cask_loader"
  cask = Cask::CaskLoader.load(Pathname(ARGV.fetch(0)))
  abort "wrong Homebrew cask version" unless cask.version.to_s == newer
  macos = cask.depends_on.macos
  abort "wrong cask macOS floor" unless macos.comparator == ">=" && macos.version.to_s == "15"
end'''
        result = subprocess.run(
            [brew, "ruby", "-e", ruby, str(self.output / f"{VERSION}-dev.10" / "minga-mac.rb")],
            env={
                **os.environ,
                "HOMEBREW_DEVELOPER": "1",
                "HOMEBREW_NO_AUTO_UPDATE": "1",
                "HOMEBREW_NO_ANALYTICS": "1",
            },
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_requires_an_explicit_release_version(self):
        for version in ("latest", "v1.2.3", "1.2.3/../latest", '1.2.3"', "1.2.3\n"):
            with self.subTest(version=version):
                self.assert_rejected(self.render(version=version), "explicit release version")
        self.assert_rejected(self.render(version=None), "--version")

    def test_rejects_malformed_rolling_versions_without_writing_recipes(self):
        for prerelease in ("dev", "dev.", "dev.0", "dev.03", "dev.foo", "dev.3.extra"):
            with self.subTest(prerelease=prerelease):
                result = self.render(version=f"{VERSION}-{prerelease}", dmg=self.dmg, output=self.output)
                self.assert_rejected(result, "base-dev.N")
                self.assertFalse(self.output.exists())

    def test_rejects_an_archive_for_the_other_architecture(self):
        self.assert_rejected(self.render(arm64=self.intel, intel=self.arm64), "expected minga_macos_aarch64.tar.gz")

    def test_does_not_emit_a_partial_formula_when_the_second_archive_is_unavailable(self):
        self.intel.unlink()
        self.assert_rejected(self.render(), self.intel.name)
        self.intel.touch()
        self.assert_rejected(self.render(), "not a nonempty archive file")

    def test_requires_dmg_and_output_together(self):
        for kwargs in ({"dmg": self.dmg}, {"output": self.output}):
            with self.subTest(kwargs=kwargs):
                self.assert_rejected(self.render(**kwargs), "--dmg and --output must be supplied together")
        self.assert_rejected(self.render(dmg=self.dmg, output=""), "--output must name a directory")
        self.assertFalse(self.output.exists())

    def test_rejects_invalid_dmg_without_writing_recipes(self):
        wrong_name = self.dmg.with_name("Minga_1.2.3.dmg")
        wrong_name.write_bytes(self.dmg.read_bytes())
        self.assert_rejected(self.render(dmg=wrong_name, output=self.output), "expected Minga.dmg")
        self.assertFalse(self.output.exists())

        self.dmg.unlink()
        self.assert_rejected(self.render(dmg=self.dmg, output=self.output), self.dmg.name)
        self.assertFalse(self.output.exists())

        self.dmg.touch()
        self.assert_rejected(self.render(dmg=self.dmg, output=self.output), "not a nonempty DMG file")
        self.assertFalse(self.output.exists())

    def test_rejects_output_collision_without_leaving_half_a_pair(self):
        self.output.mkdir()
        existing = self.output / "minga-mac.rb"
        existing.write_bytes(b"existing cask")
        self.assert_rejected(self.render(dmg=self.dmg, output=self.output), existing.name)
        self.assertEqual(list(self.output.iterdir()), [existing])
        self.assertEqual(existing.read_bytes(), b"existing cask")


if __name__ == "__main__":
    unittest.main()
