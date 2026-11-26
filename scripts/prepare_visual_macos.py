"""Prepare a Finder-launchable native Minga for a live visual check."""

import argparse
import os
import sys
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def build():
    subprocess.run(["mix", "protocol.gen"], cwd=ROOT, check=True)
    subprocess.run(["make", "xcodegen-generate", "native.tui"], cwd=ROOT, check=True)
    subprocess.run(["mix", "release", "minga_macos", "--overwrite"], cwd=ROOT, check=True)
    subprocess.run([
        "mix", "swift.build", "--", "-project", "macos/Minga.xcodeproj",
        "-scheme", "Minga", "-configuration", "Debug", "-derivedDataPath",
        "macos/DerivedData", "-destination", "platform=macOS", "build",
    ], cwd=ROOT, check=True)


def prepare(renderer, release, target):
    if not (release / "bin/minga_macos").is_file():
        raise ValueError(f"Missing embedded editor core at {release}")

    run = Path(tempfile.mkdtemp(prefix="minga-visual-", dir="/private/tmp"))
    app = run / "Minga.app"
    try:
        subprocess.run(["ditto", renderer, app], check=True)
        resources = app / "Contents/Resources"
        embedded = resources / "release"
        if embedded.exists():
            shutil.rmtree(embedded)
        subprocess.run(["ditto", release, embedded], check=True)
        plist = app / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        if info["CFBundleIdentifier"] != "com.minga.editor.dev":
            raise ValueError("Expected the worktree's Debug renderer")
        executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
        profile = {"MINGA_DEV_PROFILE": run}
        for variable, name in [
            ("HOME", "home"), ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
            ("XDG_CACHE_HOME", "cache"), ("XDG_STATE_HOME", "state"), ("TMPDIR", "tmp"),
        ]:
            directory = run / name
            directory.mkdir(mode=0o700)
            profile[variable] = directory
        if target is None:
            target = profile["HOME"] / "visual-check.md"
            target.write_text("# Minga visual verification\n")
        # Set the profile in the app's own entry point. Finder and GUI automation
        # launch by bundle path without inheriting the terminal's environment.
        launcher = executable.with_name("VisualLauncher")
        exports = [f"export {k}={shlex.quote(str(v))}" for k, v in profile.items()]
        command = shlex.join([str(executable), "--minga-ipc-runtime-parent",
                              str(profile["TMPDIR"]), str(target)])
        launcher.write_text("\n".join(["#!/bin/sh", "set -eu", *exports,
                                       'cd "$HOME"', f"exec {command}", ""]))
        launcher.chmod(0o755)
        info["CFBundleExecutable"] = launcher.name
        info["CFBundleIdentifier"] = "com.minga.visual." + run.name.replace("_", "-")
        plist.write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", "--options",
                        "runtime", "--entitlements", ROOT / "macos/Entitlements.plist", app],
                       check=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", app], check=True)
    except BaseException:
        shutil.rmtree(run)
        raise
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", nargs="?", type=Path, help="file or directory to open")
    parser.add_argument("--reuse-build", action="store_true",
                        help="use this worktree's existing Debug renderer and dev release")
    parser.add_argument("--prepare-only", action="store_true", help="print the bundle path for a GUI driver")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("requires macOS and Xcode")
    target = args.target.resolve(strict=True) if args.target else None
    os.environ["MIX_ENV"] = "dev"
    build_dir = Path(os.environ.setdefault("MIX_BUILD_PATH", str(ROOT / "_build/dev")))
    if not args.reuse_build:
        build()
    app = prepare(ROOT / "macos/DerivedData/Build/Products/Debug/Minga.app",
                  ROOT / build_dir / "rel/minga_macos", target)
    print(app, flush=True)
    if not args.prepare_only:
        subprocess.run(["open", "-n", "-a", app], check=True)
