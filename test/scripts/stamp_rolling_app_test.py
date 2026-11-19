"""Offline CLI tests for stamping an assembled rolling app."""

from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/stamp-rolling-app"


class StampRollingAppTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="minga bundle ")
        self.addCleanup(temporary.cleanup)
        self.app = Path(temporary.name) / "Minga.app"
        self.plist = self.app / "Contents/Info.plist"
        self.plist.parent.mkdir(parents=True)
        self.info = {
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "1",
            "CFBundleExecutable": "Minga",
        }

    def stamp(self, version="1.2.3-dev.12345"):
        return subprocess.run([str(SCRIPT), self.app, version], capture_output=True, text=True)

    def test_stamps_only_the_build_version_in_xml_and_binary_plists(self):
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            with self.subTest(fmt=fmt):
                self.plist.write_bytes(plistlib.dumps(self.info, fmt=fmt))
                result = self.stamp()
                self.assertEqual(result.returncode, 0, result.stderr)
                content = self.plist.read_bytes()
                self.assertEqual(plistlib.loads(content, fmt=fmt), dict(self.info, CFBundleVersion="12345"))

    def test_rejects_invalid_versions_without_writing(self):
        original = plistlib.dumps(self.info)
        self.plist.write_bytes(original)
        for version in ("1.2.3", "1.2.3-dev.0", "1.2.3-dev.01", "1.2.3-dev.١", "1.2.3-dev.1\n"):
            with self.subTest(version=version):
                result = self.stamp(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("VERSION must be BASE-dev.N", result.stderr)
                self.assertEqual(self.plist.read_bytes(), original)

    def test_rejects_mismatched_or_missing_marketing_version_without_writing(self):
        for info in (dict(self.info, CFBundleShortVersionString="1.2.4"), {"CFBundleVersion": "1"}):
            with self.subTest(info=info):
                original = plistlib.dumps(info)
                self.plist.write_bytes(original)
                result = self.stamp()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("CFBundleShortVersionString must match the base version 1.2.3", result.stderr)
                self.assertEqual(self.plist.read_bytes(), original)

    def test_rejects_missing_or_unreadable_plist(self):
        for content in (None, b"<?xml version='1.0'?><plist><dict>"):
            with self.subTest(content=content):
                if content is not None:
                    self.plist.write_bytes(content)
                result = self.stamp()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Info.plist", result.stderr)


if __name__ == "__main__":
    unittest.main()
