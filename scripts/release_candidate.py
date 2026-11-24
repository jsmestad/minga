#!/usr/bin/env python3
"""Local-only immutable release-candidate construction and verification.

Workflows acquire trusted context, REST metadata, and raw artifact ZIPs. This
module owns decisions only: it never networks, executes a payload, or rebuilds.
See docs/RELEASING.md for the external handle and acquisition commands.
"""

import argparse
import hashlib
import json
import re
import stat
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

MANIFEST_VERSION = 2
PAYLOADS = {
    "Minga.dmg": {"os": "macos", "arch": "aarch64"},
    "minga_macos_aarch64.tar.gz": {"os": "macos", "arch": "aarch64"},
    "minga_macos_x86_64.tar.gz": {"os": "macos", "arch": "x86_64"},
    "minga_linux_x86_64.tar.gz": {"os": "linux", "arch": "x86_64"},
    "minga_linux_aarch64.tar.gz": {"os": "linux", "arch": "aarch64"},
}
# The former wrapper inventory is accepted by verification, never by creation.
LEGACY_PAYLOADS = {
    "Minga.dmg": {"os": "macos", "arch": "aarch64"},
    "minga_macos_aarch64": {"os": "macos", "arch": "aarch64"},
    "minga_macos_x86_64": {"os": "macos", "arch": "x86_64"},
    "minga_linux_x86_64": {"os": "linux", "arch": "x86_64"},
    "minga_linux_aarch64": {"os": "linux", "arch": "aarch64"},
}
TOOLCHAIN_KEYS = {"elixir": "elixir", "erlang": "otp", "golang": "go", "zig": "native_zig"}
MANIFEST_PAYLOADS = {1: LEGACY_PAYLOADS, MANIFEST_VERSION: PAYLOADS}
# Rolling manifests: version 3 carried only Apple Silicon; version 4 adds both Linux tarballs.
HOMEBREW_MANIFEST_VERSION = 3
ROLLING_MANIFEST_VERSION = 4
MANIFEST_PAYLOADS[HOMEBREW_MANIFEST_VERSION] = {
    name: target for name, target in PAYLOADS.items() if target == {"os": "macos", "arch": "aarch64"}
}
MANIFEST_PAYLOADS[ROLLING_MANIFEST_VERSION] = {
    name: target for name, target in PAYLOADS.items()
    if target == {"os": "macos", "arch": "aarch64"} or target["os"] == "linux"
}
LEGACY_PINS = {"elixir": "1.20.5-otp-29", "otp": "29.1.2", "go": "1.26.4", "native_zig": "0.16.0"}
CONTEXT_KEYS = {"repository", "source_sha", "version", "workflow_path", "workflow_sha", "run_id", "run_attempt", "run_started_at"}
HEX = re.compile(r"[0-9a-f]{64}\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")
MAX_JSON = 1024 * 1024


class CandidateError(ValueError):
    """An unavailable or invalid candidate; never permission to substitute."""


def require(condition, message):
    if not condition:
        raise CandidateError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def decode_json(data):
    require(len(data) <= MAX_JSON, "JSON input too large")
    return json.loads(data, object_pairs_hook=unique_object)


def read_json(path):
    with Path(path).open("rb") as stream:
        return decode_json(stream.read(MAX_JSON + 1))


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def timestamp(value):
    require(isinstance(value, str), "missing timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.tzinfo is not None, "timestamp lacks timezone")
    return parsed


def positive_int(value):
    return type(value) is int and value > 0


def validate_context(context):
    require(isinstance(context, dict), "invalid context inventory")
    if "channel" in context:
        require(set(context) == CONTEXT_KEYS | {"channel"} and context["channel"] == "homebrew",
                "invalid Homebrew context inventory")
    else:
        require(set(context) == CONTEXT_KEYS, "invalid context inventory")
    require(isinstance(context["repository"], str) and len(context["repository"]) <= 200 and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", context["repository"]) is not None, "invalid repository")
    for field in ("source_sha", "workflow_sha"):
        require(isinstance(context[field], str) and SHA.fullmatch(context[field]), f"invalid full {field}")
    require(context["workflow_path"] == ".github/workflows/release.yml", "wrong producing workflow")
    require(isinstance(context["version"], str) and len(context["version"]) <= 128 and re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", context["version"]), "invalid version")
    if "channel" in context:
        require(context["source_sha"] == context["workflow_sha"]
                and re.fullmatch(r"\d+\.\d+\.\d+-dev\.[1-9][0-9]*", context["version"]),
                "invalid rolling Homebrew source or version")
    require(positive_int(context["run_id"]) and positive_int(context["run_attempt"]), "invalid run generation")
    timestamp(context["run_started_at"])
    return context


def artifact_name(context, filename):
    return f'candidate-{context["run_id"]}-{context["run_attempt"]}-{filename}'


def digest_file(path):
    digest = hashlib.sha256()
    size = 0
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
            size += len(block)
    return size, digest.hexdigest()


def artifact_ref(artifact):
    return {key: artifact[key] for key in ("id", "name", "digest")}


def artifact_inventory(artifacts, context):
    require(isinstance(artifacts, list), "artifact metadata must be an array")
    by_name = {}
    ids = set()
    now = datetime.now(timezone.utc)
    for artifact in artifacts:
        require(isinstance(artifact, dict), "invalid artifact metadata")
        identity = artifact.get("id")
        name = artifact.get("name")
        require(positive_int(identity) and identity not in ids, "invalid or duplicate artifact ID")
        require(isinstance(name, str) and name not in by_name, "invalid or duplicate artifact name")
        require(artifact.get("expired") is False, "artifact missing expiry status or expired")
        require(timestamp(artifact.get("expires_at")) > now, "artifact expired")
        require(timestamp(artifact.get("created_at")) >= timestamp(context["run_started_at"]), "artifact belongs to an older attempt")
        run = artifact.get("workflow_run", {})
        require(run.get("id") == context["run_id"] and run.get("head_sha") == context["workflow_sha"], "wrong artifact run/workflow provenance")
        require(isinstance(artifact.get("digest"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", artifact["digest"]), "missing SHA256 transport digest")
        ids.add(identity)
        by_name[name] = artifact
    return by_name


def validate_artifacts(artifacts, context, labels):
    require(isinstance(artifacts, list) and len(artifacts) == len(labels), "missing, duplicate or unexpected artifacts")
    by_name = artifact_inventory(artifacts, context)
    require(set(by_name) == {artifact_name(context, label) for label in labels}, "wrong generation or artifact inventory")
    return {label: by_name[artifact_name(context, label)] for label in labels}


def verification_artifacts(artifacts, context):
    """Select one complete supported generation inventory, never mixed formats."""
    schemas = (HOMEBREW_MANIFEST_VERSION, ROLLING_MANIFEST_VERSION) if "channel" in context else (1, MANIFEST_VERSION)
    require(isinstance(artifacts, list) and any(len(artifacts) == len(MANIFEST_PAYLOADS[schema]) + 2 for schema in schemas),
            "missing, duplicate or unexpected artifacts")
    by_name = artifact_inventory(artifacts, context)
    for schema in schemas:
        payloads = MANIFEST_PAYLOADS[schema]
        labels = [*payloads, "checksums", "manifest"]
        if set(by_name) == {artifact_name(context, label) for label in labels}:
            return schema, {label: by_name[artifact_name(context, label)] for label in labels}
    raise CandidateError("wrong generation or artifact inventory")


class Archive:
    """Validate the complete directory before reading any fixed-name member.

    No archive-controlled path is ever written. Payloads are streamed for hashing;
    only bounded JSON/checksum members are materialized. ZIP CRC checks remain on.
    """

    def __init__(self, downloads, artifact, inventory):
        path = Path(downloads) / f'{artifact["id"]}.zip'
        require(path.is_file() and not path.is_symlink(), f'missing raw ZIP for artifact {artifact["id"]}')
        _, digest = digest_file(path)
        require("sha256:" + digest == artifact["digest"], "raw ZIP transport digest mismatch")
        self.zip = zipfile.ZipFile(path)
        try:
            entries = self.zip.infolist()
            require(len(entries) == len(inventory), "missing, duplicate or unexpected ZIP entries")
            names = set()
            for entry in entries:
                # Exact flat inventory also rejects traversal, absolute paths,
                # backslashes, directories, NUL-truncated names and duplicates.
                require(entry.filename == entry.orig_filename and entry.filename in inventory, "unsafe or unexpected ZIP path")
                require(entry.filename not in names, "duplicate ZIP entry")
                mode = entry.external_attr >> 16
                require(stat.S_IFMT(mode) in (0, stat.S_IFREG), "non-regular ZIP entry (symlink/directory/device)")
                require(not entry.is_dir() and not entry.flag_bits & 1, "directory or encrypted ZIP entry")
                names.add(entry.filename)
            require(names == set(inventory), "missing ZIP entries")
        except Exception:
            self.zip.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.zip.close()

    def identity(self, name):
        digest = hashlib.sha256()
        size = 0
        with self.zip.open(name) as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
                size += len(block)
        require(size == self.zip.getinfo(name).file_size, "ZIP member size mismatch")
        return {"filename": name, "size": size, "sha256": digest.hexdigest()}

    def bounded(self, name, limit=MAX_JSON):
        require(self.zip.getinfo(name).file_size <= limit, "oversized metadata member")
        with self.zip.open(name) as stream:
            value = stream.read(limit + 1)
        require(len(value) <= limit, "oversized metadata member")
        return value


def read_toolchains(path):
    """Read the toolchain pins acquired from the independently verified source revision."""
    pins = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.partition("#")[0].split()
        if fields and (key := TOOLCHAIN_KEYS.get(fields[0])):
            require(len(fields) == 2 and key not in pins, "invalid or duplicate source toolchain pin")
            pins[key] = fields[1]
    require(len(pins) == len(TOOLCHAIN_KEYS), "missing source toolchain pins")
    return pins


def validate_build(build, context, filename, target, schema, pins):
    require(isinstance(build, dict) and set(build) == {"schema_version", "context", "filename", "target", "toolchains", "evidence"}, "invalid build facts inventory")
    require(type(build["schema_version"]) is int and build["schema_version"] == 1 and validate_context(build["context"]) == context, "wrong build provenance/generation")
    require(build["filename"] == filename and build["target"] == target, "wrong build target")
    tools = build["toolchains"]
    require(isinstance(tools, dict), "missing toolchains")
    pins = LEGACY_PINS if schema == 1 else pins
    require(all(tools.get(key) == value for key, value in pins.items()), "wrong pinned toolchain")
    if filename == "Minga.dmg":
        require(isinstance(tools.get("xcode"), str) and bool(tools["xcode"].strip()), "missing actual xcode version")
    elif schema == 1:
        require(isinstance(tools.get("wrapper_zig"), str) and bool(tools["wrapper_zig"].strip()),
                "missing actual wrapper_zig version")
    else:
        require("wrapper_zig" not in tools, "unexpected wrapper toolchain for native tarball")
        require(tools.get("python") == "3.14.10" and tools.get("erts") == "17.1.1", "wrong Python or ERTS pin")
        host = tools.get("host_erts_arch")
        require(isinstance(host, str) and host.startswith(target["arch"] + "-"), "wrong native host ERTS architecture")
        receipt = tools.get("erts_source")
        require(isinstance(receipt, dict) and type(receipt.get("version")) is int and receipt["version"] == 2
                and receipt.get("kind") == "local-source-build" and receipt.get("os") == target["os"]
                and receipt.get("arch") == target["arch"] and receipt.get("otp_version") == pins["otp"]
                and receipt.get("erts_version") == tools["erts"], "missing or mismatched source-runtime receipt")
    evidence = build["evidence"]
    require(isinstance(evidence, list) and 1 <= len(evidence) <= 64, "missing or unbounded validation evidence")
    ids = set()
    for item in evidence:
        require(isinstance(item, dict), "invalid evidence")
        identity = item.get("id")
        require(isinstance(identity, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,79}", identity), "invalid evidence identity")
        require(identity not in ids and item.get("result") == "passed", "duplicate or failed validation evidence")
        ids.add(identity)
    required = {"package-contents", "native-architecture", "package-boot"}
    if filename == "Minga.dmg":
        required |= {"signature", "notarization", "stapling"}
    elif schema != 1:
        required.add("package-runtime-abi")
    require(required <= ids, "missing required validation evidence")


def payload_descriptors(context, artifacts, downloads, schema, pins):
    descriptors = []
    for filename, target in MANIFEST_PAYLOADS[schema].items():
        artifact = artifacts[filename]
        build_name = filename + ".build.json"
        with Archive(downloads, artifact, {filename, build_name}) as archive:
            build = decode_json(archive.bounded(build_name))
            validate_build(build, context, filename, target, schema, pins)
            payload = archive.identity(filename)
            require(payload["size"] > 0, "empty payload")
            facts = archive.identity(build_name)
        facts.update(toolchains=build["toolchains"], evidence=build["evidence"])
        payload.update(target=target, artifact=artifact_ref(artifact), build=facts)
        descriptors.append(payload)
    return descriptors


def checksum_bytes(payloads):
    return "".join(f'{item["sha256"]}  {item["filename"]}\n' for item in payloads).encode("ascii")


def candidate_manifest(context, artifacts, downloads, schema, pins):
    payloads = payload_descriptors(context, artifacts, downloads, schema, pins)
    artifact = artifacts["checksums"]
    with Archive(downloads, artifact, {"SHA256SUMS.txt"}) as archive:
        require(archive.bounded("SHA256SUMS.txt", 2048) == checksum_bytes(payloads), "checksum inventory or payload hash mismatch")
        checksums = archive.identity("SHA256SUMS.txt")
    checksums["artifact"] = artifact_ref(artifact)
    return {"schema_version": schema, "context": context, "payloads": payloads, "checksums": checksums}


def verify(context, metadata, downloads, manifest_artifact_id, manifest_sha256, pins):
    require(positive_int(manifest_artifact_id), "invalid manifest artifact ID")
    require(isinstance(manifest_sha256, str) and HEX.fullmatch(manifest_sha256), "invalid manifest-file SHA256")
    schema, artifacts = verification_artifacts(metadata, context)
    manifest_artifact = artifacts["manifest"]
    require(manifest_artifact["id"] == manifest_artifact_id, "wrong external manifest artifact ID")
    with Archive(downloads, manifest_artifact, {"manifest.json"}) as archive:
        require(archive.identity("manifest.json")["sha256"] == manifest_sha256, "external manifest-file hash mismatch")
        manifest = decode_json(archive.bounded("manifest.json"))
    # Reconstruct from independently expected context, current immutable API
    # metadata and actual bytes. No self-asserted manifest provenance is trusted.
    expected = candidate_manifest(context, artifacts, downloads, schema, pins)
    require(json.dumps(manifest, sort_keys=True) == json.dumps(expected, sort_keys=True), "manifest inventory, provenance, evidence or final-byte identity mismatch")
    return {
        "schema_version": 1,
        "result": "verified",
        "handle": {"manifest_artifact_id": manifest_artifact_id, "manifest_sha256": manifest_sha256},
        "context": context,
        "payloads": [{key: item[key] for key in ("filename", "size", "sha256")} for item in expected["payloads"]],
        "checks": ["exact-inventory", "expected-provenance", "single-generation", "unexpired-artifacts", "raw-zip-sha256", "safe-archive-inventory", "final-byte-sha256", "exact-checksums", "toolchain-pins", "declared-evidence-identities"],
        "qualification": "Byte/provenance rehearsal only; no installed, UI, sustained-use or release approval.",
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("checksums", "create", "verify"):
        command = commands.add_parser(name)
        command.add_argument("--context", required=True, type=Path)
        command.add_argument("--artifacts", required=True, type=Path)
        command.add_argument("--downloads", required=True, type=Path)
        command.add_argument("--source-tool-versions", required=True, type=Path)
        if name == "verify":
            command.add_argument("--manifest-artifact-id", required=True, type=int)
            command.add_argument("--manifest-sha256", required=True)
            command.add_argument("--receipt", required=True, type=Path)
        else:
            command.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        # Never leave an old success receipt behind on a failed invocation.
        if args.command == "verify":
            args.receipt.unlink(missing_ok=True)
        context = validate_context(read_json(args.context))
        metadata = read_json(args.artifacts)
        pins = read_toolchains(args.source_tool_versions)
        if args.command == "verify":
            receipt = verify(context, metadata, args.downloads, args.manifest_artifact_id, args.manifest_sha256, pins)
            write_json(args.receipt, receipt)
            print(json.dumps(receipt, sort_keys=True))
        else:
            schema = ROLLING_MANIFEST_VERSION if "channel" in context else MANIFEST_VERSION
            labels = list(MANIFEST_PAYLOADS[schema]) + (["checksums"] if args.command == "create" else [])
            artifacts = validate_artifacts(metadata, context, labels)
            if args.command == "create":
                write_json(args.output, candidate_manifest(context, artifacts, args.downloads, schema, pins))
            else:
                args.output.write_bytes(checksum_bytes(payload_descriptors(context, artifacts, args.downloads, schema, pins)))
    except (CandidateError, OSError, ValueError, TypeError, KeyError, AttributeError, zipfile.BadZipFile, RuntimeError, NotImplementedError) as error:
        print(f"candidate unavailable: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
