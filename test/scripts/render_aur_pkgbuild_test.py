#!/usr/bin/env python3
"""The AUR PKGBUILD pins the published release bytes and sorts rolling builds before stable ones."""

import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts/render-aur-pkgbuild"
SHA = "0123456789abcdef0123456789abcdef01234567"
X86_64, AARCH64 = "a" * 64, "b" * 64
SOURCES = {"LICENSE": "LICENSE", "desktop": "packaging/linux/minga.desktop", "icon": "packaging/linux/minga.png"}
DIGESTS = {name: hashlib.sha256((REPO / path).read_bytes()).hexdigest() for name, path in SOURCES.items()}


def render(version="0.1.0-dev.42", source_sha=SHA, x86_64=X86_64, aarch64=AARCH64, *extra):
    return subprocess.run(
        [sys.executable, SCRIPT, "--version", version, "--source-sha", source_sha, "--x86-64-sha256", x86_64,
         "--aarch64-sha256", aarch64, *extra],
        capture_output=True, text=True, timeout=20,
    )


class RenderAurPkgbuildTest(unittest.TestCase):
    def test_pins_the_release_assets_and_the_source_commit_files(self):
        result = render()
        self.assertEqual(result.returncode, 0, result.stderr)
        pkgbuild = result.stdout
        for line in (
            "pkgname=minga-bin", "_release=0.1.0-dev.42", "pkgver=0.1.0dev.42", "pkgrel=1",
            "arch=('x86_64' 'aarch64')", "provides=('minga')", "conflicts=('minga')",
            f"sha256sums=('{DIGESTS['LICENSE']}' '{DIGESTS['desktop']}' '{DIGESTS['icon']}')",
            f"sha256sums_x86_64=('{X86_64}')", f"sha256sums_aarch64=('{AARCH64}')",
            f'source=("LICENSE-$_release::https://raw.githubusercontent.com/jsmestad/minga/{SHA}/LICENSE"',
            f'        "minga-$_release.desktop::https://raw.githubusercontent.com/jsmestad/minga/{SHA}/packaging/linux/minga.desktop"',
            f'        "minga-$_release.png::https://raw.githubusercontent.com/jsmestad/minga/{SHA}/packaging/linux/minga.png")',
            '  install -Dm644 "minga-$_release.desktop" "$pkgdir/usr/share/applications/minga.desktop"',
            '  install -Dm644 "minga-$_release.png" "$pkgdir/usr/share/icons/hicolor/512x512/apps/minga.png"',
            'source_x86_64=("https://github.com/jsmestad/minga/releases/download/v$_release/minga_${_release}_linux_x86_64.tar.gz")',
            'source_aarch64=("https://github.com/jsmestad/minga/releases/download/v$_release/minga_${_release}_linux_aarch64.tar.gz")',
        ):
            with self.subTest(line=line):
                self.assertIn(line + "\n", pkgbuild)

    def test_repository_package_is_named_minga_and_excludes_the_aur_package(self):
        result = render("0.1.0-dev.42", SHA, X86_64, AARCH64, "--pkgname", "minga")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("\npkgname=minga\n", result.stdout)
        self.assertIn("\nconflicts=('minga-bin')\n", result.stdout)
        self.assertNotIn("provides=", result.stdout)
        rejected = render("0.1.0-dev.42", SHA, X86_64, AARCH64, "--pkgname", "minga-git")
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(rejected.stdout, "")

    def test_sources_copies_the_local_files_makepkg_needs_under_their_source_names(self):
        with tempfile.TemporaryDirectory() as directory:
            result = render("0.1.0-dev.42", SHA, X86_64, AARCH64, "--sources", directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            names = {"LICENSE": "LICENSE-0.1.0-dev.42", "desktop": "minga-0.1.0-dev.42.desktop",
                     "icon": "minga-0.1.0-dev.42.png"}
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()), sorted(names.values()))
            for key, name in names.items():
                self.assertEqual((Path(directory) / name).read_bytes(), (REPO / SOURCES[key]).read_bytes())

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
        )
        for arguments, message in cases:
            with self.subTest(arguments=arguments):
                result = render(**arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
