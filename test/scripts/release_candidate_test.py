"""Consumer fixtures for immutable bytes, not package/runtime qualification.

Run: python3 -m unittest discover -s test/scripts -p release_candidate_test.py
"""

import hashlib
import importlib.util
import json
import stat
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/release_candidate.py"
SPEC = importlib.util.spec_from_file_location("release_candidate", SCRIPT)
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)


class ReleaseCandidateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.downloads = self.root / "downloads"
        self.downloads.mkdir()
        now = datetime.now(timezone.utc)
        self.context = {
            "repository": "jsmestad/minga", "source_sha": "a" * 40,
            "version": "0.1.0", "workflow_path": ".github/workflows/release.yml",
            "workflow_sha": "b" * 40, "run_id": 123, "run_attempt": 2,
            "run_started_at": (now - timedelta(minutes=1)).isoformat(),
        }
        self.created = now.isoformat()
        self.expires = (now + timedelta(days=7)).isoformat()
        self.metadata = []
        self.entries = {}
        self.builds = {}
        for filename, target in candidate.PAYLOADS.items():
            tools = dict(candidate.PINS)
            tools["xcode" if filename == "Minga.dmg" else "wrapper_zig"] = "26.3" if filename == "Minga.dmg" else "0.16.0"
            ids = ["package-contents", "native-architecture", "package-boot"]
            if filename == "Minga.dmg":
                ids += ["signature", "notarization", "stapling"]
            build = {
                "schema_version": 1, "context": dict(self.context),
                "filename": filename, "target": target, "toolchains": tools,
                "evidence": [{"id": identity, "result": "passed"} for identity in ids],
            }
            self.builds[filename] = build
            self.add_artifact(filename, [(filename, ("fixture final bytes: " + filename).encode()), (filename + ".build.json", json.dumps(build).encode())])
        self.call("checksums", "--output", str(self.root / "SHA256SUMS.txt"), success=True)
        self.add_artifact("checksums", [("SHA256SUMS.txt", (self.root / "SHA256SUMS.txt").read_bytes())])
        self.call("create", "--output", str(self.root / "manifest.json"), success=True)
        self.manifest = json.loads((self.root / "manifest.json").read_text())
        self.add_artifact("manifest", [("manifest.json", (self.root / "manifest.json").read_bytes())])
        self.handle_id = self.metadata[-1]["id"]
        self.handle_sha = hashlib.sha256((self.root / "manifest.json").read_bytes()).hexdigest()

    def add_artifact(self, label, entries):
        artifact = {
            "id": len(self.metadata) + 100,
            "name": candidate.artifact_name(self.context, label),
            "expired": False, "expires_at": self.expires, "created_at": self.created,
            "workflow_run": {"id": self.context["run_id"], "head_sha": self.context["workflow_sha"]},
        }
        self.metadata.append(artifact)
        self.entries[label] = entries
        self.rezip(label)

    def artifact(self, label):
        return next(item for item in self.metadata if item["name"] == candidate.artifact_name(self.context, label))

    def rezip(self, label):
        artifact = self.artifact(label)
        path = self.downloads / f'{artifact["id"]}.zip'
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for name, data in self.entries[label]:
                    archive.writestr(name, data)
        artifact["digest"] = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()

    def call(self, command, *arguments, success=False):
        (self.root / "context.json").write_text(json.dumps(self.context))
        (self.root / "artifacts.json").write_text(json.dumps(self.metadata))
        result = subprocess.run([
            sys.executable, str(SCRIPT), command,
            "--context", str(self.root / "context.json"),
            "--artifacts", str(self.root / "artifacts.json"),
            "--downloads", str(self.downloads), *arguments,
        ], capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def verify(self, success=False):
        return self.call("verify", "--manifest-artifact-id", str(self.handle_id),
                         "--manifest-sha256", self.handle_sha,
                         "--receipt", str(self.root / "receipt.json"), success=success)

    def reject(self, message):
        # Stale successful output must not survive any rejected invocation.
        (self.root / "receipt.json").write_text('{"result":"verified"}')
        result = self.verify()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertFalse((self.root / "receipt.json").exists())

    def replace_manifest(self):
        data = json.dumps(self.manifest).encode()
        self.entries["manifest"] = [("manifest.json", data)]
        self.rezip("manifest")
        self.handle_sha = hashlib.sha256(data).hexdigest()

    def replace_build(self, filename):
        self.entries[filename][1] = (filename + ".build.json", json.dumps(self.builds[filename]).encode())
        self.rezip(filename)

    def test_complete_round_trip_emits_exact_handle_and_received_byte_hashes(self):
        self.verify(success=True)
        receipt = json.loads((self.root / "receipt.json").read_text())
        self.assertEqual(receipt["handle"], {"manifest_artifact_id": self.handle_id, "manifest_sha256": self.handle_sha})
        self.assertEqual(len(receipt["payloads"]), 5)
        for payload in receipt["payloads"]:
            actual = self.entries[payload["filename"]][0][1]
            self.assertEqual(payload["size"], len(actual))
            self.assertEqual(payload["sha256"], hashlib.sha256(actual).hexdigest())
        self.assertNotIn("handle", self.manifest)
        self.assertLess((self.root / "receipt.json").stat().st_size, 8192)

    def test_hashes_actual_raw_transport_not_api_digest_echo(self):
        path = self.downloads / f'{self.metadata[0]["id"]}.zip'
        path.write_bytes(path.read_bytes() + b"changed transport")
        self.reject("transport digest mismatch")

    def test_changed_payload_even_with_valid_new_transport_fails(self):
        label = "minga_linux_aarch64"
        self.entries[label][0] = (label, b"different final bytes")
        self.rezip(label)
        self.reject("payload hash mismatch")

    def test_external_manifest_hash_is_not_manifest_self_assertion(self):
        self.handle_sha = "f" * 64
        self.reject("external manifest-file hash mismatch")

    def test_external_manifest_id_cannot_select_name_substitute(self):
        self.handle_id += 1
        self.reject("external manifest artifact ID")

    def test_missing_deleted_artifact_fails(self):
        self.metadata.pop(0)
        self.reject("missing, duplicate or unexpected artifacts")

    def test_missing_download_fails_instead_of_rebuilding(self):
        (self.downloads / f'{self.metadata[0]["id"]}.zip').unlink()
        self.reject("missing raw ZIP")

    def test_expired_status_fails(self):
        self.metadata[0]["expired"] = True
        self.reject("expired")

    def test_expiry_timestamp_fails_even_if_status_is_false(self):
        self.metadata[0]["expires_at"] = "2000-01-01T00:00:00Z"
        self.reject("expired")

    def test_duplicate_artifact_id_fails(self):
        self.metadata[1]["id"] = self.metadata[0]["id"]
        self.reject("duplicate artifact ID")

    def test_duplicate_artifact_name_fails(self):
        self.metadata[1]["name"] = self.metadata[0]["name"]
        self.reject("duplicate artifact name")

    def test_unexpected_artifact_fails(self):
        self.add_artifact("surprise", [("surprise", b"not a candidate")])
        self.reject("unexpected artifacts")

    def test_mixed_attempt_name_fails(self):
        self.metadata[0]["name"] = self.metadata[0]["name"].replace("-123-2-", "-123-1-")
        self.reject("wrong generation")

    def test_old_attempt_cannot_be_relabelled_with_new_name(self):
        self.metadata[0]["created_at"] = "2000-01-01T00:00:00Z"
        self.reject("older attempt")

    def test_wrong_api_run_and_workflow_provenance_fail(self):
        for field, wrong in (("id", 999), ("head_sha", "c" * 40)):
            with self.subTest(field=field):
                run = self.metadata[0]["workflow_run"]
                original = run[field]
                run[field] = wrong
                self.reject("run/workflow provenance")
                run[field] = original

    def test_independently_pinned_source_repository_version_cannot_be_overridden(self):
        for field, wrong in (("repository", "someone/else"), ("source_sha", "d" * 40), ("version", "0.2.0")):
            with self.subTest(field=field):
                original = self.context[field]
                self.context[field] = wrong
                self.reject("build provenance/generation")
                self.context[field] = original

    def test_manifest_inventory_hashes_and_evidence_are_compared_to_received_bytes(self):
        for mutation in ("missing", "duplicate", "unexpected", "hash", "evidence"):
            with self.subTest(mutation=mutation):
                original = json.loads(json.dumps(self.manifest))
                if mutation == "missing":
                    self.manifest["payloads"].pop()
                elif mutation == "duplicate":
                    self.manifest["payloads"].append(self.manifest["payloads"][0])
                elif mutation == "unexpected":
                    self.manifest["unexpected"] = "not accepted"
                elif mutation == "hash":
                    self.manifest["payloads"][0]["sha256"] = "0" * 64
                else:
                    self.manifest["payloads"][0]["build"]["evidence"][0]["id"] = "invented-check"
                self.replace_manifest()
                self.reject("manifest inventory")
                self.manifest = original

    def test_checksum_inventory_is_exact(self):
        self.entries["checksums"][0] = ("SHA256SUMS.txt", self.entries["checksums"][0][1] + b"0  unexpected\n")
        self.rezip("checksums")
        self.reject("checksum inventory")

    def test_missing_native_architecture_evidence_fails(self):
        label = "minga_linux_x86_64"
        self.builds[label]["evidence"] = [{"id": "package-contents", "result": "passed"}]
        self.replace_build(label)
        self.reject("missing required validation evidence")

    def test_failed_or_duplicate_evidence_is_not_ready(self):
        label = "Minga.dmg"
        self.builds[label]["evidence"][0]["result"] = "failed"
        self.replace_build(label)
        self.reject("failed validation evidence")
        self.builds[label]["evidence"][0]["result"] = "passed"
        self.builds[label]["evidence"].append(self.builds[label]["evidence"][0])
        self.replace_build(label)
        self.reject("duplicate or failed")

    def test_toolchain_and_target_facts_are_required(self):
        label = "minga_linux_x86_64"
        self.builds[label]["toolchains"]["go"] = "1.25.0"
        self.replace_build(label)
        self.reject("wrong pinned toolchain")
        self.builds[label]["toolchains"]["go"] = candidate.PINS["go"]
        self.builds[label]["target"] = {"os": "linux", "arch": "aarch64"}
        self.replace_build(label)
        self.reject("wrong build target")

    def test_archive_inventory_rejects_missing_duplicate_and_unexpected_members(self):
        label = "minga_linux_aarch64"
        original = list(self.entries[label])
        cases = [original[:1], [original[0], original[0]], original + [("secret", b"not allowed")]]
        for entries in cases:
            with self.subTest(entries=[name for name, _ in entries]):
                self.entries[label] = entries
                self.rezip(label)
                self.reject("ZIP entr")

    def test_archive_traversal_absolute_and_backslash_paths_never_write(self):
        label = "minga_linux_x86_64"
        for name in ("../escape", "/tmp/escape", "dir/../" + label, "dir\\" + label):
            with self.subTest(name=name):
                self.entries[label][0] = (name, b"must never be written")
                self.rezip(label)
                self.reject("unsafe or unexpected ZIP path")
                self.assertFalse((self.root / "escape").exists())

    def test_symlink_and_special_file_are_rejected_before_content_read(self):
        label = "minga_linux_x86_64"
        for mode in (stat.S_IFLNK | 0o777, stat.S_IFIFO | 0o600, stat.S_IFDIR | 0o755):
            with self.subTest(mode=mode):
                entry = zipfile.ZipInfo(label)
                entry.create_system = 3
                entry.external_attr = mode << 16
                self.entries[label][0] = (entry, b"../escape")
                self.rezip(label)
                self.reject("non-regular ZIP entry")

    def test_invalid_zip_with_matching_transport_digest_fails(self):
        artifact = self.metadata[0]
        path = self.downloads / f'{artifact["id"]}.zip'
        path.write_bytes(b"not a ZIP")
        artifact["digest"] = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
        self.reject("not a zip file")

    def test_duplicate_manifest_json_key_is_not_last_value_wins(self):
        data = b'{"schema_version":1,"schema_version":1}'
        self.entries["manifest"] = [("manifest.json", data)]
        self.rezip("manifest")
        self.handle_sha = hashlib.sha256(data).hexdigest()
        self.reject("duplicate JSON key")

    def test_missing_transport_digest_is_not_warning_only(self):
        self.metadata[0].pop("digest")
        self.reject("missing SHA256 transport digest")

    def test_manifest_numbers_cannot_be_replaced_with_json_booleans(self):
        self.manifest["schema_version"] = True
        self.replace_manifest()
        self.reject("manifest inventory")

    def test_build_from_a_different_attempt_cannot_be_combined(self):
        label = "minga_linux_aarch64"
        self.builds[label]["context"]["run_attempt"] = 1
        self.replace_build(label)
        self.reject("build provenance/generation")

    def test_oversized_manifest_fails_before_materializing_metadata(self):
        data = b" " * (candidate.MAX_JSON + 1)
        self.entries["manifest"] = [("manifest.json", data)]
        self.rezip("manifest")
        self.handle_sha = hashlib.sha256(data).hexdigest()
        self.reject("oversized metadata member")


if __name__ == "__main__":
    unittest.main()
