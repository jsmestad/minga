#!/usr/bin/env python3
"""Offline CLI fixtures: the publisher's gh subprocess only sees a local server model."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/publish-homebrew-release"
REPO = "jsmestad/minga"
RELEASES = f"repos/{REPO}/releases"
VERSION = "0.1.0-dev.37"
TAG = f"v{VERSION}"
REF = f"refs/tags/{TAG}"
SHA = "0123456789abcdef0123456789abcdef01234567"
WRONG_SHA = "f" * 40
RELEASE_ID = 47
TUI = f"minga_{VERSION}_macos_aarch64.tar.gz"
DMG = f"Minga_{VERSION}.dmg"
LINUX = (f"minga_{VERSION}_linux_x86_64.tar.gz", f"minga_{VERSION}_linux_aarch64.tar.gz",
         f"minga_{VERSION}_amd64.deb", f"minga_{VERSION}_arm64.deb",
         f"minga-{VERSION}.x86_64.rpm", f"minga-{VERSION}.aarch64.rpm")
PAYLOADS = {TUI: b"test TUI archive", DMG: b"test signed disk image",
            **{name: f"test Linux package {name}".encode() for name in LINUX}}
ALL = list(PAYLOADS)
UPLOADS = [f"upload:{name}" for name in ALL]


def release(draft=True, **fields):
    return dict({"id": RELEASE_ID, "tag_name": TAG, "target_commitish": SHA,
                 "draft": draft, "prerelease": True}, **fields)


def tag(sha=SHA, kind="commit"):
    return {"ref": REF, "object": {"type": kind, "sha": sha}}


def asset(name, data=None, **fields):
    if data is None:
        data = PAYLOADS[name]
    return dict({"name": name, "size": len(data), "state": "uploaded",
                 "digest": "sha256:" + hashlib.sha256(data).hexdigest()}, **fields)


def fixture_gh(args):
    state_path = Path(os.environ["MINGA_RELEASE_FIXTURE_STATE"])
    state = json.loads(state_path.read_text())
    current = state["release"]
    assets = state["assets"]
    assert os.environ.get("GH_TOKEN") == "fixture-token"
    include = "--include" in args

    def event(name):
        state["events"].append(name)
        if name in state.get("fail", {}):
            reply(state["fail"][name], {"message": "fixture GitHub error"})

    def reply(status, body):
        state_path.write_text(json.dumps(state))
        if include:
            print(f"HTTP/2.0 {status} Fixture Status\r\nContent-Type: application/json\r\n\r\n", end="")
        print(json.dumps(body))
        if status >= 400:
            print(f"gh: {body['message']} (HTTP {status})", file=sys.stderr)
            sys.exit(1)
        sys.exit(0)

    if args[:2] == ["release", "create"]:
        event("create-draft")
        assert args[2] == TAG
        assert args[args.index("--repo") + 1] == f"github.com/{REPO}"
        assert args[args.index("--target") + 1] == SHA
        assert {"--draft", "--prerelease", "--latest=false"}.issubset(args)
        assert not current
        state["release"] = release()
        reply(201, state["release"])

    assert args[0] == "api" and args[args.index("--hostname") + 1] == "github.com", args
    endpoint = args[1]
    method = args[args.index("--method") + 1] if "--method" in args else "GET"
    if (method, endpoint) == ("GET", f"{RELEASES}/tags/{TAG}"):
        event("read-public")
        if current and not current["draft"]:
            reply(200, current)
        reply(404, {"message": "Not Found"})
    if (method, endpoint) == ("GET", f"repos/{REPO}/git/ref/tags/{TAG}"):
        event("read-tag")
        if state["tag"]:
            reply(200, state["tag"])
        reply(404, {"message": "Not Found"})
    if endpoint == "graphql":
        event("find-draft")
        assert f"tag={TAG}" in args
        assert any('repository(owner: "jsmestad", name: "minga")' in arg for arg in args)
        value = {"databaseId": current["id"]} if current else None
        reply(200, {"data": {"repository": {"release": value}}})
    if (method, endpoint) == ("GET", f"{RELEASES}/{RELEASE_ID}"):
        event("read-release-by-id")
        reply(200, current)
    if (method, endpoint) == ("GET", f"{RELEASES}/{RELEASE_ID}/assets?per_page={len(PAYLOADS) + 1}"):
        event(f"read-assets:{'draft' if current['draft'] else 'public'}:{len(assets)}")
        reply(200, assets[:len(PAYLOADS) + 1])
    if (method, endpoint) == ("DELETE", f"{RELEASES}/assets/7"):
        event("delete-starter")
        assert current["draft"]
        assets[:] = [item for item in assets if item.get("id") != 7]
        reply(204, {})
    if method == "POST" and endpoint.startswith(f"https://uploads.github.com/{RELEASES}/{RELEASE_ID}/assets?name="):
        name = endpoint.split("=", 1)[1]
        if state.get("fail", {}).get(f"upload:{name}") == 502:
            assets.append(asset(name, b"", state="starter", id=7, digest=None))
        event(f"upload:{name}")
        assert current["draft"] and name in PAYLOADS and all(old["name"] != name for old in assets)
        file = Path(args[args.index("--input") + 1])
        data = file.read_bytes()
        assert file.name == name
        remote_asset = asset(name, data, **state.get("upload_override", {}).get(name, {}))
        assets.append(remote_asset)
        reply(201, remote_asset)
    if (method, endpoint) == ("PATCH", f"{RELEASES}/{RELEASE_ID}"):
        event("publish")
        assert current["draft"]
        assert {"draft=false", "make_latest=false", f"target_commitish={SHA}"}.issubset(args)
        current["draft"] = False
        state["tag"] = state.get("published_tag", state["tag"] or tag())
        reply(200, current)
    raise AssertionError(f"unexpected gh invocation: {args}")


class PublishHomebrewReleaseTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="minga release fixture ")
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.bundle = root / "bundle"
        self.bundle.mkdir()
        for name, data in PAYLOADS.items():
            (self.bundle / name).write_bytes(data)
        # Use this file as an executable gh fixture. No test invokes the real CLI.
        (root / "gh").symlink_to(Path(__file__).resolve())
        self.state_path = root / "state.json"
        self.env = {
            **os.environ,
            "PATH": f"{root}{os.pathsep}{os.environ['PATH']}",
            "GH_TOKEN": "fixture-token",
            "GH_HOST": "example.invalid",
            "GITHUB_REPOSITORY": REPO,
            "MINGA_RELEASE_FIXTURE_STATE": str(self.state_path),
        }
        self.seed()

    def seed(self, **fields):
        self.state_path.write_text(json.dumps(dict({"release": None, "tag": None, "assets": [], "events": []}, **fields)))

    def state(self):
        return json.loads(self.state_path.read_text())

    def run_publisher(self, version=VERSION, sha=SHA, **env):
        return subprocess.run(
            [SCRIPT, self.bundle, version, sha], env={**self.env, **env},
            text=True, capture_output=True, timeout=20,
        )

    def mutations(self):
        return [event for event in self.state()["events"] if event.startswith(("create-", "upload:", "publish", "delete-"))]

    def assert_failure(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertNotIn("Verified public prerelease", result.stdout)

    def test_creates_draft_verifies_remote_bytes_then_publishes_and_is_idempotent(self):
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"https://github.com/{REPO}/releases/tag/{TAG}", result.stdout)
        self.assertEqual(self.mutations(), ["create-draft", *UPLOADS, "publish"])
        state = self.state()
        self.assertEqual(state["assets"], [asset(name) for name in ALL])
        self.assertEqual(state["tag"], tag())
        events = state["events"]
        start, confirm, publish = (events.index(item) for item in (UPLOADS[-1], f"read-assets:draft:{len(ALL)}", "publish"))
        self.assertLess(start, confirm)
        self.assertLess(confirm, publish)
        self.assertIn("read-tag", events[publish + 1:])
        self.assertIn(f"read-assets:public:{len(ALL)}", events[publish + 1:])

        repeated = self.run_publisher()
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(self.mutations(), ["create-draft", *UPLOADS, "publish"])

    def test_resumes_pinned_draft_and_uploads_only_the_missing_asset(self):
        present = [asset(name) for name in ALL if name != TUI]
        self.seed(release=release(), tag=tag(), assets=present)
        result = self.run_publisher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(), [f"upload:{TUI}", "publish"])
        self.assertEqual(self.state()["assets"], [*present, asset(TUI)])

    def test_rejects_wrong_or_annotated_tag_without_creating_a_release(self):
        for ref, message in ((tag(WRONG_SHA), "does not point to"), (tag(kind="tag"), "not a lightweight")):
            with self.subTest(ref=ref):
                self.seed(tag=ref)
                self.assert_failure(self.run_publisher(), message)
                self.assertEqual(self.mutations(), [])

    def test_rejects_conflicting_draft_metadata_and_assets_without_writes(self):
        cases = [
            (release(target_commitish="main"), [asset(TUI)], "wrong target"),
            (release(target_commitish=WRONG_SHA), [asset(TUI)], "wrong target"),
            (release(tag_name="v0.1.0-dev.36"), [], "wrong tag"),
            (release(prerelease=False), [], "not a prerelease"),
            (release(), [asset(TUI, digest="sha256:" + "0" * 64)], "does not match"),
            (release(), [asset(TUI, size=1)], "does not match"),
            (release(), [asset(TUI, state="starter", digest=None)], "does not match"),
            (release(), [asset(TUI, digest=None)], "does not match"),
            (release(), [asset(TUI), asset(TUI)], "unexpected or duplicate"),
            (release(), [*map(asset, ALL), asset("extra.txt", b"extra")], "unexpected or duplicate"),
        ]
        for metadata, assets, message in cases:
            with self.subTest(metadata=metadata, assets=assets):
                self.seed(release=metadata, tag=tag(), assets=assets)
                self.assert_failure(self.run_publisher(), message)
                self.assertEqual(self.mutations(), [])

    def test_rejects_incomplete_or_conflicting_public_releases_without_writes(self):
        for assets, message in (([asset(TUI)], "missing required assets"),
                                ([asset(TUI), asset(DMG, size=1)], "does not match"),
                                ([asset(name) for name in ALL if name != LINUX[0]], "missing required assets")):
            with self.subTest(assets=assets):
                self.seed(release=release(draft=False), tag=tag(), assets=assets)
                self.assert_failure(self.run_publisher(), message)
                self.assertEqual(self.mutations(), [])

    def test_partial_upload_failure_leaves_draft_and_retry_uses_existing_bytes(self):
        self.seed(fail={f"upload:{DMG}": 502})
        self.assert_failure(self.run_publisher(), "HTTP 502")
        state = self.state()
        self.assertTrue(state["release"]["draft"])
        self.assertEqual(state["assets"], [asset(TUI), asset(DMG, b"", state="starter", id=7, digest=None)])
        remaining = [f"upload:{name}" for name in ALL[1:]]
        self.assertNotIn("publish", state["events"])

        state.pop("fail")
        state["events"] = []
        self.seed(**state)
        recovered = self.run_publisher()
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(self.mutations(), ["delete-starter", *remaining, "publish"])

    def test_successful_upload_request_does_not_prove_correct_remote_bytes(self):
        self.seed(upload_override={DMG: {"digest": "sha256:" + "0" * 64}})
        self.assert_failure(self.run_publisher(), "does not match")
        self.assertTrue(self.state()["release"]["draft"])
        self.assertNotIn("publish", self.mutations())

    def test_failed_publication_leaves_complete_draft_without_success(self):
        self.seed(fail={"publish": 403})
        self.assert_failure(self.run_publisher(), "HTTP 403")
        state = self.state()
        self.assertTrue(state["release"]["draft"])
        self.assertEqual(state["assets"], [asset(name) for name in ALL])

    def test_successful_publish_request_does_not_prove_the_tag_sha(self):
        for ref, message in ((None, "HTTP 404"), (tag(WRONG_SHA), "does not point to")):
            with self.subTest(ref=ref):
                self.seed(published_tag=ref)
                self.assert_failure(self.run_publisher(), message)
                self.assertIn("publish", self.mutations())

    def test_api_failure_is_not_treated_as_a_missing_release(self):
        self.seed(fail={"read-public": 403})
        self.assert_failure(self.run_publisher(), "HTTP 403")
        self.assertEqual(self.state()["events"], ["read-public"])

    def test_bad_input_fails_before_contacting_github(self):
        self.assert_failure(self.run_publisher(version="0.1.0-dev.037"), "VERSION must be")
        self.assert_failure(self.run_publisher(sha=SHA[:12]), "SOURCE_SHA must be")
        self.assert_failure(self.run_publisher(GITHUB_REPOSITORY="elsewhere/minga"), "GITHUB_REPOSITORY must be")
        self.assert_failure(self.run_publisher(GH_TOKEN=""), "GH_TOKEN is required")
        (self.bundle / LINUX[-1]).unlink()
        self.assert_failure(self.run_publisher(), "missing bundle asset")
        self.assertEqual(self.state()["events"], [])


if __name__ == "__main__":
    if Path(sys.argv[0]).name == "gh":
        fixture_gh(sys.argv[1:])
    else:
        unittest.main()
