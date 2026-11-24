#!/usr/bin/env python3
"""The AUR PKGBUILD pins the published release bytes and sorts rolling builds before stable ones."""

from pathlib import Path
import shutil
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/render-aur-pkgbuild"
SHA = "0123456789abcdef0123456789abcdef01234567"
X86_64, AARCH64, LICENSE = "a" * 64, "b" * 64, "c" * 64


def render(version="0.1.0-dev.42", source_sha=SHA, x86_64=X86_64, aarch64=AARCH64, license_sha=LICENSE, *extra):
    return subprocess.run(
        [sys.executable, SCRIPT, "--version", version, "--source-sha", source_sha, "--x86-64-sha256", x86_64,
         "--aarch64-sha256", aarch64, "--license-sha256", license_sha, *extra],
        capture_output=True, text=True, timeout=20,
    )


class RenderAurPkgbuildTest(unittest.TestCase):
    def test_pins_the_release_assets_license_and_commit(self):
        result = render()
        self.assertEqual(result.returncode, 0, result.stderr)
        pkgbuild = result.stdout
        for line in (
            "pkgname=minga-bin", "_release=0.1.0-dev.42", "pkgver=0.1.0dev.42", "pkgrel=1",
            "arch=('x86_64' 'aarch64')", "provides=('minga')", "conflicts=('minga')",
            f"sha256sums=('{LICENSE}')", f"sha256sums_x86_64=('{X86_64}')", f"sha256sums_aarch64=('{AARCH64}')",
            f'source=("LICENSE-$_release::https://raw.githubusercontent.com/jsmestad/minga/{SHA}/LICENSE")',
            'source_x86_64=("https://github.com/jsmestad/minga/releases/download/v$_release/minga_${_release}_linux_x86_64.tar.gz")',
            'source_aarch64=("https://github.com/jsmestad/minga/releases/download/v$_release/minga_${_release}_linux_aarch64.tar.gz")',
        ):
            with self.subTest(line=line):
                self.assertIn(line + "\n", pkgbuild)

    def test_repository_package_is_named_minga_and_excludes_the_aur_package(self):
        result = render("0.1.0-dev.42", SHA, X86_64, AARCH64, LICENSE, "--pkgname", "minga")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("\npkgname=minga\n", result.stdout)
        self.assertIn("\nconflicts=('minga-bin')\n", result.stdout)
        self.assertNotIn("provides=", result.stdout)
        rejected = render("0.1.0-dev.42", SHA, X86_64, AARCH64, LICENSE, "--pkgname", "minga-git")
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(rejected.stdout, "")

    def test_stable_versions_keep_their_number(self):
        result = render(version="0.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("\npkgver=0.1.0\n", result.stdout)

    @unittest.skipUnless(shutil.which("bash"), "bash is required to parse the PKGBUILD")
    def test_output_is_valid_bash(self):
        subprocess.run(["bash", "-n"], input=render().stdout, text=True, check=True)

    def test_rejects_versions_and_digests_that_do_not_name_one_release(self):
        cases = (
            ({"version": "0.1.0-rc.1"}, "version must be"),
            ({"version": "0.1.0-dev.0"}, "version must be"),
            ({"source_sha": SHA[:12]}, "source SHA"),
            ({"x86_64": "A" * 64}, "x86_64 SHA-256"),
            ({"aarch64": ""}, "aarch64 SHA-256"),
            ({"license_sha": "c" * 63}, "LICENSE SHA-256"),
        )
        for arguments, message in cases:
            with self.subTest(arguments=arguments):
                result = render(**arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
