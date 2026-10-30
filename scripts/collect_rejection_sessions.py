#!/usr/bin/env python3
"""Collect operator-bracketed, log-verified session candidates for #3513."""

import argparse
from collections import Counter
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import uuid

HEADER = "--- Minga debug log session ---"
REJECTION = re.compile(
    r"Rejected(?: stale)? semantic activation surface=(\S+) generation=(.*?) id=(.*?) reason=(\S+)$"
)
WARNING_LEVELS = {"debug", "info", "warning"}
EVIDENCE_FILES = ("debug.log", "canonical.log", "native-output.log", "launcher-output.log")
DEBUG_FAILURES = (
    "debug_log_write_failed", "debug_log_not_running", "debug_log_session_header_failed",
    "debug log final flush failed", "debug log close failed", "failed to stop debug log",
)


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def save_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def evidence_fingerprint(path):
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return {"size": size, "sha256": digest.hexdigest()}


def payload_digest(app):
    """Hash paths, permissions, file contents, and internal symlink targets."""
    digest = hashlib.sha256()
    for directory, folders, files in os.walk(app, followlinks=False):
        folders.sort()
        for name in sorted(folders + files):
            path = Path(directory) / name
            relative = str(path.relative_to(app))
            if path.is_symlink():
                if not path.resolve().is_relative_to(app.resolve()):
                    raise ValueError(f"Bundle symlink escapes the payload: {relative}")
                entry = [relative, "symlink", os.readlink(path)]
            elif path.is_dir():
                continue
            else:
                entry = [relative, path.stat().st_mode & 0o777, evidence_fingerprint(path)["sha256"]]
            digest.update(json.dumps(entry, ensure_ascii=True).encode() + b"\n")
    return digest.hexdigest()


def canonical_snapshot(path):
    try:
        stream = path.open("rb")
    except FileNotFoundError:
        return None
    with stream:
        stat = os.fstat(stream.fileno())
        boundary = max(0, stat.st_size - 4096)
        stream.seek(boundary)
        prefix = stream.read(stat.st_size - boundary)
        return {
            "device": stat.st_dev, "inode": stat.st_ino, "offset": stat.st_size,
            "boundary": boundary, "boundary_sha256": hashlib.sha256(prefix).hexdigest(),
        }


def retain_canonical_interval(path, before, destination):
    """Retain only this bracket's byte interval; reject replacement or truncation."""
    with path.open("rb") as source, destination.open("wb") as output:
        stat = os.fstat(source.fileno())
        offset = 0
        if before is not None:
            if (stat.st_dev, stat.st_ino) != (before["device"], before["inode"]):
                raise ValueError("Canonical log was replaced or rotated")
            offset = before["offset"]
            if stat.st_size < offset:
                raise ValueError("Canonical log was truncated")
            source.seek(before["boundary"])
            prefix = source.read(offset - before["boundary"])
            if hashlib.sha256(prefix).hexdigest() != before["boundary_sha256"]:
                raise ValueError("Canonical log boundary changed")
        source.seek(offset)
        remaining = stat.st_size - offset
        while remaining:
            chunk = source.read(min(remaining, 1024 * 1024))
            if not chunk:
                raise ValueError("Canonical log changed while reading")
            output.write(chunk)
            remaining -= len(chunk)
        return {"device": stat.st_dev, "inode": stat.st_ino, "offset": stat.st_size}


def inspect_log(path, debug=False, clean_quit=False):
    messages = Counter()
    groups = Counter()
    problems = []
    headers = 0
    markers = []
    last_line = ""
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            if any(marker in line.lower() for marker in DEBUG_FAILURES):
                problems.append(f"Debug writer failure: {line.strip()}")
            if line.strip():
                last_line = line.strip()
            headers += line.strip() == HEADER
            if debug and "[debug-log] " in line:
                markers.append(line.strip())
            start = line.find("Rejected semantic activation")
            if start < 0:
                start = line.find("Rejected stale semantic activation")
            if start < 0:
                continue
            message = line[start:].rstrip("\r\n")
            match = REJECTION.fullmatch(message)
            if match is None:
                problems.append(f"Unrecognized rejection: {message}")
                continue
            surface, generation, _item_id, reason = match.groups()
            messages[message] += 1
            groups[(surface, generation, reason)] += 1
    if debug and headers != 1:
        problems.append(f"Expected one debug session header, found {headers}")
    orderly_shutdown = (
        clean_quit and markers == ["[debug-log] events registry down: :shutdown"]
        and last_line == markers[0]
    )
    if markers and not orderly_shutdown:
        problems.append("Debug-log event registry gap or recovery marker")
    return messages, groups, problems


def analyze(session):
    metadata = json.loads((session / "session.json").read_text())
    problems = list(metadata.get("problems", []))
    if metadata.get("boundary_kind") != "operator_bracketed" or "finished_at" not in metadata:
        problems.append("No completed operator-bracketed collection boundary")
    if metadata.get("launcher_exit_code") != 0:
        problems.append("The prescribed private-app launch command did not complete successfully")
    if metadata.get("session_attested") is not True:
        problems.append("Operator has not confirmed exact launch, uninterrupted use, clean quit, and warning capture")
    if metadata.get("declared_editor_warning_level") not in WARNING_LEVELS:
        problems.append("Operator has not confirmed an editor warning-enabled level")
    if "canonical_after" not in metadata:
        problems.append("Canonical log interval was not completed")
    fingerprints = {}
    for name in EVIDENCE_FILES:
        try:
            fingerprints[name] = evidence_fingerprint(session / name)
            if fingerprints[name] != metadata.get("retained_logs", {}).get(name):
                problems.append(f"Retained evidence is missing its receipt or changed: {name}")
        except OSError as error:
            problems.append(f"Incomplete retained evidence: {error}")
    if "canonical_after" in metadata and "canonical.log" in fingerprints:
        before = metadata.get("canonical_before")
        length = metadata["canonical_after"]["offset"] - (before["offset"] if before else 0)
        if fingerprints["canonical.log"]["size"] != length:
            problems.append("Retained canonical log does not match its recorded byte interval")
    observed, groups, canonical = Counter(), Counter(), Counter()
    try:
        observed, groups, debug_problems = inspect_log(
            session / "debug.log", debug=True, clean_quit=metadata.get("session_attested") is True
        )
        canonical, _unused, canonical_problems = inspect_log(session / "canonical.log")
        problems.extend(debug_problems + canonical_problems)
        for name in ("native-output.log", "launcher-output.log"):
            messages, _unused, diagnostics = inspect_log(session / name)
            problems.extend(diagnostics)
            if messages:
                problems.append(f"Rejection warnings reached {name} outside the canonical log")
    except (OSError, UnicodeError) as error:
        problems.append(f"Incomplete capture: {error}")
    for message, count in observed.items():
        if canonical[message] != count:
            problems.append(
                f"Missing or ambiguous canonical correlation: debug={count} canonical={canonical[message]} {message}"
            )
    if canonical - observed:
        problems.append("Canonical rejection warnings are unattributed; cannot establish a complete session count")
    problems = sorted(set(problems))
    complete = not problems
    return {
        "session": session.name, "kind": metadata["kind"],
        "source_commit": metadata["build"]["source_commit"],
        "boundary_kind": metadata.get("boundary_kind"),
        "debug_log_sha256": fingerprints.get("debug.log", {}).get("sha256"),
        "started_at": metadata["started_at"], "finished_at": metadata.get("finished_at"),
        "note": metadata["note"], "warning_level_evidence": "operator declaration, not runtime sampling",
        "integrity": "complete" if complete else "unknown",
        "real_candidate": complete and metadata["kind"] == "real",
        "rejection_count": sum(observed.values()) if complete else None,
        "observed_rejection_count": sum(observed.values()),
        "unattributed_canonical_rejections": sum((canonical - observed).values()),
        "surfaces": [
            {"surface": surface, "generation": generation, "reason": reason, "count": count}
            for (surface, generation, reason), count in sorted(groups.items())
        ],
        "problems": problems,
    }


def require_no_running_app():
    result = subprocess.run(["pgrep", "-x", "Minga"], capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError(f"Could not check running apps: {result.stderr.strip()}")
    if result.returncode == 0:
        raise ValueError("Minga is still running. Leave it intact and quit it normally before continuing.")


@contextmanager
def bracket_lock(path):
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(descriptor, "r+") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Another collection operation is using the canonical log") from None
        yield stream


def begin(args):
    require_no_running_app()
    receipt = json.loads(args.build.read_text())
    app = Path(receipt["app_path"]).resolve()
    if not re.fullmatch(r"[0-9a-f]{40}", receipt["source_commit"]):
        raise ValueError("Build receipt must identify an immutable source commit")
    if payload_digest(app) != receipt["payload_sha256"]:
        raise ValueError("App payload does not match its build receipt")
    launcher = app / "Contents/Resources/bin/minga"
    if not launcher.is_file() or not os.access(launcher, os.X_OK):
        raise ValueError(f"Bundled launcher is unavailable: {launcher}")
    if args.warning_level not in WARNING_LEVELS:
        raise ValueError("Confirm :log_level_editor is :debug, :info, or :warning before collection")
    canonical = args.canonical.expanduser().absolute()
    canonical.parent.mkdir(parents=True, exist_ok=True)
    session = args.root.expanduser().resolve() / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8])
    lock = canonical.resolve().with_name(canonical.resolve().name + ".rejection-session")
    with bracket_lock(lock) as stream:
        owner = stream.read().strip()
        if owner:
            raise ValueError(f"An unfinished collection bracket owns this log: {owner}; finish it first")
        session.mkdir(parents=True, mode=0o700)
        metadata = {
            "kind": args.kind, "note": args.note, "build": receipt, "boundary_kind": "operator_bracketed",
            "declared_editor_warning_level": args.warning_level, "started_at": utc_now(),
            "canonical_path": str(canonical), "canonical_before": canonical_snapshot(canonical),
            "lock_path": str(lock), "problems": [],
        }
        save_json(session / "session.json", metadata)
        native_output = shlex.quote(str(session / "native-output.log"))
        open_script = session / "open-with-log"
        open_script.write_text(f'#!/bin/sh\nexec /usr/bin/open --stdout {native_output} --stderr {native_output} "$@"\n')
        open_script.chmod(0o700)
        command = (
            f"MINGA_APP_PATH={shlex.quote(str(app))} MINGA_OPEN_BIN={shlex.quote(str(open_script))} "
            + shlex.join([str(launcher), "--debug-log", str(session / "debug.log"),
                          *(str(Path(file).expanduser().resolve()) for file in args.files)])
        )
        launch_script = session / "launch.sh"
        launch_script.write_text(
            "#!/bin/sh\n" + command + f" >{shlex.quote(str(session / 'launcher-output.log'))} 2>&1\n"
            + "status=$?\n" + f"printf '%s\\n' \"$status\" >{shlex.quote(str(session / 'launcher-exit-code'))}\n"
            + 'exit "$status"\n'
        )
        launch_script.chmod(0o700)
        stream.write(str(session) + "\n")
        stream.flush()
    print(f"Session: {session}\nRun: {shlex.quote(str(launch_script))}")
    print("Use that private app for one uninterrupted session. Click its Dock icon if its window is restored closed.")
    print("Finish: " + shlex.join([sys.executable, str(Path(__file__).resolve()), "finish", str(session)]))
    print("If collection is cancelled or uncertain, finish and answer no; the count stays unknown.")
    return 0


def finish(args):
    require_no_running_app()
    session = args.session.expanduser().resolve()
    metadata = json.loads((session / "session.json").read_text())
    lock = Path(metadata["lock_path"])
    with bracket_lock(lock) as stream:
        owner = stream.read().strip()
        if "finished_at" not in metadata:
            if owner != str(session):
                raise ValueError("This collection bracket does not own its canonical log")
            metadata["finished_at"] = utc_now()
            try:
                metadata["canonical_after"] = retain_canonical_interval(
                    Path(metadata["canonical_path"]), metadata["canonical_before"], session / "canonical.log"
                )
                app = Path(metadata["build"]["app_path"])
                if payload_digest(app) != metadata["build"]["payload_sha256"]:
                    metadata["problems"].append("App payload changed during collection")
                metadata["launcher_exit_code"] = int((session / "launcher-exit-code").read_text().strip())
            except (OSError, ValueError) as error:
                metadata["problems"].append(str(error))
            try:
                metadata["retained_logs"] = {name: evidence_fingerprint(session / name) for name in EVIDENCE_FILES}
            except OSError as error:
                metadata["problems"].append(f"Could not fingerprint retained evidence: {error}")
            metadata["session_attested"] = False
            try:
                qualification = "normal work, " if metadata["kind"] == "real" else ""
                answer = input(
                    f"Confirm the prescribed launch, one uninterrupted session with no replacement/restart, {qualification}"
                    "clean app quit (not crash/force quit), and warnings enabled throughout [yes/no]: "
                )
                metadata["session_attested"] = answer.strip().lower() == "yes"
            except (EOFError, KeyboardInterrupt):
                metadata["problems"].append("Session confirmation unavailable")
            save_json(session / "session.json", metadata)
        if owner == str(session):
            stream.seek(0)
            stream.truncate()
            stream.flush()
    result = analyze(session)
    save_json(session / "report.json", result)
    print(json.dumps(result, indent=2))
    return 0 if result["integrity"] == "complete" else 2


def report(args):
    sessions = [analyze(path.parent) for path in sorted(args.root.glob("*/session.json"))]
    seen = {}
    for session in sessions:
        if session["real_candidate"]:
            identity = session["debug_log_sha256"]
            if identity in seen:
                session["real_candidate"] = False
                session["duplicate_of"] = seen[identity]
            else:
                seen[identity] = session["session"]
    result = {
        "complete_real_candidates": sum(session["real_candidate"] for session in sessions),
        "required_real_sessions": 10,
        "review_required": "Operator-bracketed candidates require review of normal use, exact launch, warning declarations, and post-A provenance.",
        "sessions": sessions,
    }
    print(json.dumps(result, indent=2))
    return 0


def main():
    data = Path.home() / ".local/share/minga"
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    start = commands.add_parser("begin", help="Record a collection bracket and print the standard private-app launch command")
    start.add_argument("--build", type=Path, required=True, help="Receipt from the actual private app build, not checkout HEAD")
    start.add_argument("--root", type=Path, default=data / "rejection-sessions")
    start.add_argument("--canonical", type=Path, default=data / "minga.log", help="Actual native app log; shell-only XDG settings are not inherited")
    start.add_argument("--kind", choices=["real", "smoke"], required=True)
    start.add_argument("--warning-level", choices=["debug", "info", "warning", "error", "none"], required=True)
    start.add_argument("--note", required=True, help="Normal work performed, or the purpose of a synthetic smoke")
    start.add_argument("files", nargs="*")
    start.set_defaults(run=begin)
    end = commands.add_parser("finish", help="Seal an operator bracket after quitting the app normally")
    end.add_argument("session", type=Path)
    end.set_defaults(run=finish)
    summarize = commands.add_parser("report", help="Report candidates; never count smoke captures as real")
    summarize.add_argument("--root", type=Path, default=data / "rejection-sessions")
    summarize.set_defaults(run=report)
    args = parser.parse_args()
    try:
        if sys.platform != "darwin" and args.command != "report":
            raise ValueError("Native session collection requires macOS")
        return args.run(args)
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print(f"Collection unavailable: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
