#!/usr/bin/env python3
"""Stage the exact verified Homebrew candidate without executing its contents."""

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import release_candidate as candidate


def stage(recipes, output, manifest_id, manifest_sha, expected_context, downloads):
    manifest_path = recipes / "manifest.json"
    _, actual_sha = candidate.digest_file(manifest_path)
    candidate.require(actual_sha == manifest_sha, "wrong manifest hash")
    manifest = candidate.read_json(manifest_path)
    context = candidate.validate_context(manifest["context"])
    candidate.require(context == expected_context and context.get("channel") == "homebrew",
                      "wrong rolling candidate context")
    candidate.require(manifest["schema_version"] == candidate.HOMEBREW_MANIFEST_VERSION,
                      "not a rolling Homebrew manifest")
    receipt_path = recipes / "preparation-receipt.json"
    receipt = candidate.read_json(receipt_path)
    candidate.require(receipt["result"] == "verified" and receipt["context"] == context and receipt["handle"] == {
        "manifest_artifact_id": manifest_id, "manifest_sha256": manifest_sha,
    }, "preparation receipt does not match candidate")
    names = ("minga_macos_aarch64.tar.gz", "Minga.dmg")
    payloads = manifest["payloads"]
    candidate.require(len(payloads) == len(names) and {p["filename"] for p in payloads} == set(names),
                      "wrong rolling payload inventory")
    output.mkdir()
    downloads.mkdir()
    for payload in payloads:
        name, artifact = payload["filename"], payload["artifact"]
        identity = artifact["id"]
        candidate.require(candidate.positive_int(identity) and artifact["name"] == candidate.artifact_name(context, name),
                          "wrong payload artifact identity")
        with (downloads / f"{identity}.zip").open("xb") as transport:
            subprocess.run(["gh", "api", f"repos/{context['repository']}/actions/artifacts/{identity}/zip"],
                           stdout=transport, check=True)
        with candidate.Archive(downloads, artifact, {name, name + ".build.json"}) as archive:
            path = output / name
            with archive.zip.open(name) as source, path.open("xb") as destination:
                shutil.copyfileobj(source, destination, length=1024 * 1024)
            candidate.require(candidate.digest_file(path) == (payload["size"], payload["sha256"]),
                              f"wrong payload bytes: {name}")
    subprocess.run([
        sys.executable, str(Path(__file__).with_name("render-tui-formula")),
        "--version", context["version"], "--arm64", str(output / names[0]),
        "--dmg", str(output / names[1]), "--output", str(output),
    ], check=True)
    for name in ("minga.rb", "minga-mac.rb"):
        candidate.require((recipes / name).read_bytes() == (output / name).read_bytes(),
                          f"recipe does not match payloads: {name}")
    version = context["version"]
    (output / names[0]).rename(output / f"minga_{version}_macos_aarch64.tar.gz")
    (output / names[1]).rename(output / f"Minga_{version}.dmg")
    shutil.copyfile(receipt_path, output / receipt_path.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recipes", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("downloads", type=Path)
    args = parser.parse_args()
    try:
        context = candidate.decode_json(os.environ["CANDIDATE_CONTEXT"].encode())
        candidate.require(context["repository"] == "jsmestad/minga" and context["source_sha"] == os.environ["GITHUB_SHA"],
                          "publisher must use this protected main push")
        manifest_sha = os.environ["MANIFEST_SHA"]
        manifest_id = os.environ["MANIFEST_ID"]
        candidate.require(re.fullmatch(r"[a-f0-9]{64}", manifest_sha) and re.fullmatch(r"[1-9][0-9]*", manifest_id),
                          "invalid manifest handle")
        stage(args.recipes, args.output, int(manifest_id), manifest_sha, context, args.downloads)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Homebrew candidate unavailable: {error}\n")


if __name__ == "__main__":
    main()
