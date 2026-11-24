#!/usr/bin/env python3
"""The uploader publishes packages before the indexes that name them and keeps the previous version."""

from datetime import datetime, timedelta, timezone
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/upload-package-repos"
LOADER = importlib.machinery.SourceFileLoader("upload_package_repos", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
uploader = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(uploader)

NOW = datetime(2026, 11, 24, 12, tzinfo=timezone.utc)
TREE = (
    "minga.asc", "repo.json",
    "apt/minga.sources", "apt/pool/main/minga_0.1.0-dev.8_amd64.deb",
    "apt/dists/stable/main/binary-amd64/Packages", "apt/dists/stable/main/binary-amd64/Packages.gz",
    "apt/dists/stable/Release", "apt/dists/stable/InRelease", "apt/dists/stable/Release.gpg",
    "rpm/minga.repo", "rpm/x86_64/minga-0.1.0-dev.8.x86_64.rpm",
    "rpm/x86_64/repodata/abc-primary.xml.gz", "rpm/x86_64/repodata/repomd.xml", "rpm/x86_64/repodata/repomd.xml.asc",
    "arch/minga.conf", "arch/x86_64/minga-0.1.0dev.8-1-x86_64.pkg.tar.zst",
    "arch/x86_64/minga-0.1.0dev.8-1-x86_64.pkg.tar.zst.sig", "arch/x86_64/minga.db", "arch/x86_64/minga.db.sig",
    "arch/x86_64/minga.files", "arch/x86_64/minga.db.tar.gz",
)


class UploadPackageReposTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.tree = Path(temporary.name)
        for key in TREE:
            (self.tree / key).parent.mkdir(parents=True, exist_ok=True)
            (self.tree / key).write_text(key)
        (self.tree / "repo.json").write_text(json.dumps({"version": "0.1.0-dev.8", "source_sha": "a" * 40}))
        self.uploads = []
        self.deletes = []
        self.remote = []

    def fake_aws(self, *args, capture=False):
        if args[:2] == ("s3api", "put-object"):
            self.uploads.append(args[args.index("--key") + 1])
            self.assertEqual(args[args.index("--cache-control") + 1], uploader.REVALIDATE)
        elif args[:2] == ("s3api", "list-objects-v2"):
            return json.dumps({"Contents": self.remote})
        elif args[:2] == ("s3api", "delete-object"):
            self.deletes.append(args[args.index("--key") + 1])
        else:
            self.fail(f"unexpected aws call: {args}")
        return ""

    def publish(self, previous):
        with mock.patch.object(uploader, "aws", side_effect=self.fake_aws), \
                mock.patch.object(uploader, "published_manifest", return_value=previous):
            return uploader.publish(self.tree, NOW)

    def test_uploads_packages_then_indexes_then_signed_entry_points(self):
        self.assertTrue(self.publish(None))
        self.assertEqual(sorted(self.uploads), sorted(TREE))
        waves = [uploader.wave(key) for key in self.uploads]
        self.assertEqual(waves, sorted(waves))
        for key in ("apt/pool/main/minga_0.1.0-dev.8_amd64.deb", "arch/x86_64/minga-0.1.0dev.8-1-x86_64.pkg.tar.zst.sig"):
            self.assertEqual(uploader.wave(key), 0, key)
        for key in ("apt/dists/stable/main/binary-amd64/Packages.gz", "rpm/x86_64/repodata/abc-primary.xml.gz", "minga.asc"):
            self.assertEqual(uploader.wave(key), 1, key)
        for key in ("apt/dists/stable/InRelease", "rpm/x86_64/repodata/repomd.xml.asc", "arch/x86_64/minga.db.sig"):
            self.assertEqual(uploader.wave(key), 2, key)
        self.assertEqual(uploader.wave("repo.json"), 3)
        self.assertEqual(self.uploads[-1:], ["repo.json"])
        self.assertEqual(json.loads((self.tree / "repo.json").read_text())["files"], sorted(TREE))

    def test_never_replaces_the_same_or_a_newer_published_version(self):
        for version in ("0.1.0-dev.8", "0.1.0-dev.9", "0.1.0"):
            with self.subTest(version=version):
                self.assertFalse(self.publish({"version": version, "files": []}))
                self.assertEqual(self.uploads, [])

    def test_rolling_builds_sort_numerically_and_before_stable(self):
        order = ["0.1.0-dev.9", "0.1.0-dev.10", "0.1.0", "0.1.1-dev.1", "0.2.0"]
        self.assertEqual(sorted(reversed(order), key=uploader.release_order), order)
        with self.assertRaises(ValueError):
            uploader.release_order("0.1.0-rc.1")

    def test_check_served_accepts_this_or_a_newer_version_only(self):
        for served, expected in (("0.1.0-dev.8", True), ("0.1.0-dev.10", True), ("0.1.0", True),
                                 ("0.1.0-dev.7", False)):
            with self.subTest(served=served), \
                    mock.patch.object(uploader, "published_manifest", return_value={"version": served}):
                self.assertEqual(uploader.serves_at_least("0.1.0-dev.8")[0], expected)
        with mock.patch.object(uploader, "published_manifest", return_value=None):
            self.assertFalse(uploader.serves_at_least("0.1.0-dev.8")[0])

    def test_keeps_the_previous_version_and_recent_files_and_deletes_older_versions(self):
        old = (NOW - timedelta(days=3)).isoformat()
        recent = (NOW - timedelta(minutes=10)).isoformat()
        previous_deb = "apt/pool/main/minga_0.1.0-dev.7_amd64.deb"
        older_deb = "apt/pool/main/minga_0.1.0-dev.6_amd64.deb"
        racing_deb = "apt/pool/main/minga_0.1.0-dev.5_amd64.deb"
        self.remote = [{"Key": key, "LastModified": stamp} for key, stamp in (
            (previous_deb, old), (older_deb, old), (racing_deb, recent), ("apt/dists/stable/InRelease", old))]
        self.assertTrue(self.publish({"version": "0.1.0-dev.7", "files": [previous_deb]}))
        self.assertEqual(self.deletes, [older_deb])


if __name__ == "__main__":
    unittest.main()
