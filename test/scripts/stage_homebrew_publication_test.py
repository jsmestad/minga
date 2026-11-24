"""The publisher accepts only the exact artifacts from the verified attempt."""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("stage_homebrew_publication", SCRIPTS / "stage-homebrew-publication.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


PAYLOADS = ("minga_macos_aarch64.tar.gz", "Minga.dmg", "minga_linux_x86_64.tar.gz", "minga_linux_aarch64.tar.gz")


class StageHomebrewPublicationTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.recipes = self.root / "recipes"
        self.recipes.mkdir()
        self.output = self.root / "bundle"
        self.downloads = self.root / "downloads"
        self.context = {
            "repository": "jsmestad/minga", "source_sha": "a" * 40, "workflow_sha": "a" * 40,
            "workflow_path": ".github/workflows/release.yml", "channel": "homebrew",
            "version": "0.1.0-dev.123", "run_id": 42, "run_attempt": 2,
            "run_started_at": datetime.now(timezone.utc).isoformat(),
        }
        self.payloads = []
        for identity, name in enumerate(PAYLOADS, 1):
            payload = self.root / name
            payload.write_bytes(f"fixture bytes: {name}".encode())
            transport = self.root / f"{identity}.zip"
            with zipfile.ZipFile(transport, "w") as archive:
                archive.write(payload, name)
                archive.writestr(f"{name}.build.json", b"{}")
            size, sha = publisher.candidate.digest_file(payload)
            self.payloads.append({"filename": name, "size": size, "sha256": sha, "artifact": {
                "id": identity, "name": publisher.candidate.artifact_name(self.context, name),
                "digest": "sha256:" + publisher.candidate.digest_file(transport)[1],
            }})
        self.write_manifest()
        subprocess.run([sys.executable, str(SCRIPTS / "render-tui-formula"), "--version", self.context["version"],
                        "--arm64", str(self.root / "minga_macos_aarch64.tar.gz"),
                        "--dmg", str(self.root / "Minga.dmg"), "--output", str(self.recipes)], check=True)

    def write_manifest(self):
        manifest = self.recipes / "manifest.json"
        manifest.write_text(json.dumps({"schema_version": 4, "context": self.context, "payloads": self.payloads}))
        self.manifest_sha = publisher.candidate.digest_file(manifest)[1]
        (self.recipes / "preparation-receipt.json").write_text(json.dumps({
            "result": "verified", "context": self.context,
            "handle": {"manifest_artifact_id": 99, "manifest_sha256": self.manifest_sha},
        }))

    def stage(self):
        real_run = subprocess.run

        def transport_fixture(args, **kwargs):
            if args[0] != "gh":
                return real_run(args, **kwargs)
            self.assertEqual(args[:2], ["gh", "api"])
            self.assertIn(args[2], [f"repos/jsmestad/minga/actions/artifacts/{n}/zip" for n in range(1, len(PAYLOADS) + 1)])
            identity = args[2].split("/")[-2]
            kwargs["stdout"].write((self.root / f"{identity}.zip").read_bytes())

        with patch.object(publisher.subprocess, "run", side_effect=transport_fixture):
            publisher.stage(self.recipes, self.output, 99, self.manifest_sha, self.context, self.downloads)

    def test_stages_original_bytes_under_the_public_names(self):
        self.stage()
        for original, published in (("minga_macos_aarch64.tar.gz", "minga_0.1.0-dev.123_macos_aarch64.tar.gz"),
                                    ("Minga.dmg", "Minga_0.1.0-dev.123.dmg"),
                                    ("minga_linux_x86_64.tar.gz", "minga_0.1.0-dev.123_linux_x86_64.tar.gz"),
                                    ("minga_linux_aarch64.tar.gz", "minga_0.1.0-dev.123_linux_aarch64.tar.gz")):
            self.assertEqual((self.output / published).read_bytes(), (self.root / original).read_bytes())
        self.assertFalse(any((self.output / original).exists() for original in PAYLOADS))
        self.assertEqual((self.output / "minga-mac.rb").read_bytes(), (self.recipes / "minga-mac.rb").read_bytes())

    def test_rejects_transport_substitution(self):
        (self.root / "2.zip").write_bytes((self.root / "1.zip").read_bytes())
        with self.assertRaisesRegex(publisher.candidate.CandidateError, "transport digest mismatch"):
            self.stage()

    def test_rejects_recipe_generated_from_different_payloads(self):
        (self.recipes / "minga-mac.rb").write_text("different recipe for the same version")
        with self.assertRaisesRegex(publisher.candidate.CandidateError, "recipe does not match payloads"):
            self.stage()

    def test_rejects_a_rolling_manifest_without_the_linux_payloads(self):
        self.payloads = self.payloads[:2]
        self.write_manifest()
        with self.assertRaisesRegex(publisher.candidate.CandidateError, "wrong rolling payload inventory"):
            self.stage()

    def test_rejects_manifest_from_another_attempt(self):
        self.context["run_attempt"] += 1
        with self.assertRaisesRegex(publisher.candidate.CandidateError, "wrong rolling candidate context"):
            self.stage()


if __name__ == "__main__":
    unittest.main()
