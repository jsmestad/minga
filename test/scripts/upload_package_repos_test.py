#!/usr/bin/env python3
"""The uploader publishes packages before the indexes that name them and keeps the previous version."""

from datetime import datetime, timedelta, timezone
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.error

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


    def test_a_refused_manifest_read_fails_the_upload_before_any_upload(self):
        refused = OSError("GET https://packages.mingacode.dev/repo.json returned HTTP 403 Forbidden")
        with mock.patch.object(uploader, "published_manifest", side_effect=refused), \
                mock.patch.object(uploader, "aws") as aws, \
                mock.patch.object(uploader.sys, "argv", ["upload-package-repos", str(self.tree)]), \
                mock.patch.object(uploader.sys, "stderr", new_callable=io.StringIO) as stderr:
            self.assertEqual(uploader.main(), 1)
        aws.assert_not_called()
        self.assertIn("HTTP 403", stderr.getvalue())


class PublishedManifestTest(unittest.TestCase):
    """repo.json is read with an explicit agent; only 404 means nothing is published."""

    def fetch(self, outcome):
        requests = []

        def fake_urlopen(request, timeout):
            requests.append(request)
            if isinstance(outcome, Exception):
                raise outcome
            return io.BytesIO(json.dumps(outcome).encode())

        with mock.patch.object(uploader.urllib.request, "urlopen", side_effect=fake_urlopen):
            result = uploader.published_manifest()
        return result, requests

    def http_error(self, code, reason):
        return urllib.error.HTTPError(f"{uploader.PUBLIC_URL}/repo.json", code, reason, {}, None)

    def test_sends_the_release_uploader_agent_instead_of_the_python_default(self):
        manifest, requests = self.fetch({"version": "0.1.0-dev.8"})
        self.assertEqual(manifest, {"version": "0.1.0-dev.8"})
        self.assertEqual([request.full_url for request in requests], [f"{uploader.PUBLIC_URL}/repo.json"])
        self.assertEqual(requests[0].get_header("User-agent"), "minga-release-uploader/1")

    def test_missing_manifest_means_first_publication(self):
        self.assertIsNone(self.fetch(self.http_error(404, "Not Found"))[0])

    def test_refused_or_failed_requests_fail_with_the_url_and_status(self):
        for code, reason in ((403, "Forbidden"), (500, "Internal Server Error")):
            with self.subTest(code=code), self.assertRaises(OSError) as raised:
                self.fetch(self.http_error(code, reason))
            self.assertIn(f"{uploader.PUBLIC_URL}/repo.json", str(raised.exception))
            self.assertIn(f"HTTP {code}", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
