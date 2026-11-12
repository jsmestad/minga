#!/usr/bin/env python3
"""Capture the shipped Go renderer's actual PTY output, not Model.View (#2101).

Install developer dependencies from go_tui_capture_requirements.txt in a private venv.
Usage: python scripts/go_tui_capture.py --binary PATH --corpus PATH --output OWNED_ROOT.
Raw ANSI, unmodified grids and diagnostics survive failure.
This is unrelated to legacy Zig snapshots and does not prove live interactions.
"""

import argparse
import base64
import binascii
import codecs
import fcntl
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import time
import uuid

from go_tui_boot_smoke import RendererProcess

MAX_BYTES = 32 * 1024 * 1024
MAX_WALL = 60.0
MAX_STEP = 5.0
MAX_RUNS = 5
MAX_CORPUS = 1024 * 1024
DIAGNOSTIC_RESERVE = 65536
SIZES = [("narrow", 60, 24), ("default", 80, 24), ("wide", 140, 40)]
MARKER = ".minga-go-tui-capture"
OWNER = "minga-go-tui-capture-v1\n"
RUN_NAME = re.compile(r"run-[0-9a-f]{32}\Z")
LABEL = re.compile(r"[a-zA-Z0-9_-]{1,64}\Z")


def decoder_dependencies():
    try:
        import pyte
        versions = {name: importlib.metadata.version(name) for name in ("pyte", "wcwidth")}
    except (ImportError, importlib.metadata.PackageNotFoundError) as error:
        raise RuntimeError("missing capture decoder; install scripts/go_tui_capture_requirements.txt in a private venv") from error
    if versions != {"pyte": "0.8.2", "wcwidth": "0.2.13"}:
        raise RuntimeError(f"capture requires pinned decoder versions, got {versions}")
    return pyte, versions


def read_corpus(path):
    with path.open("rb") as stream:
        raw = stream.read(MAX_CORPUS + 1)
    if len(raw) > MAX_CORPUS:
        raise ValueError("corpus exceeds 1 MiB input bound")
    corpus = json.loads(raw)
    if corpus.get("version") != 1 or corpus.get("theme") != "astrodark":
        raise ValueError("expected version 1 astrodark corpus")
    sizes = corpus.get("sizes", [])
    if [(s.get("name"), s.get("columns"), s.get("rows")) for s in sizes] != SIZES:
        raise ValueError("corpus must contain narrow60x24, default80x24, wide140x40 in order")
    labels = {}
    for size in sizes:
        steps = size.get("steps")
        if not isinstance(steps, list) or not 1 <= len(steps) <= 8:
            raise ValueError("each size needs 1..8 labeled steps")
        labels[size["name"]] = set()
        for step in steps:
            label = step.get("label", "")
            if not LABEL.fullmatch(label) or label in labels[size["name"]]:
                raise ValueError("step labels must be unique safe filenames")
            labels[size["name"]].add(label)
            try:
                payload = base64.b64decode(step["payload_base64"], validate=True)
            except (KeyError, ValueError, binascii.Error) as error:
                raise ValueError(f"invalid payload for {label}") from error
            if not payload:
                raise ValueError(f"empty payload for {label}")
            for key in ("present", "absent"):
                values = step.get(key)
                if not isinstance(values, list) or (key == "present" and not values):
                    raise ValueError(f"{label} needs present/absent label lists and nonempty present")
                if len(values) > 64 or any(not isinstance(v, str) or not v or len(v) > size["columns"] or
                                          not all(32 <= ord(c) <= 126 for c in v) for v in values):
                    raise ValueError(f"{label} has invalid expected ASCII labels")
    masks = corpus.get("dynamic_cells")
    if not isinstance(masks, list) or len(masks) > 128:
        raise ValueError("dynamic_cells must be an explicit bounded list")
    for mask in masks:
        size = next((s for s in sizes if s["name"] == mask.get("size")), None)
        if size is None or mask.get("step") not in labels[size["name"]]:
            raise ValueError("dynamic mask references an unknown size/step")
        row, col, length = (mask.get(k) for k in ("row", "col", "length"))
        if not all(type(v) is int for v in (row, col, length)) or not (0 <= row < size["rows"] and
                0 <= col < size["columns"] and 1 <= length <= size["columns"] - col):
            raise ValueError("dynamic mask is outside the terminal")
        if not isinstance(mask.get("reason"), str) or not mask["reason"].strip() or len(mask["reason"]) > 256:
            raise ValueError("dynamic mask needs a bounded reason")
    return corpus, raw


class Artifacts:
    def __init__(self, root, max_bytes, retain):
        root = root.absolute()
        if any(p.is_symlink() for p in (root, *root.parents)):
            raise ValueError("output root must not traverse symlinks")
        root.mkdir(parents=True, exist_ok=True)
        self.lock = os.open(root / ".go-tui-capture.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            owned = []
            for path in root.iterdir():
                if not RUN_NAME.fullmatch(path.name) or not stat.S_ISDIR(path.lstat().st_mode):
                    continue
                marker = path / MARKER
                if marker.is_symlink() or not marker.is_file():
                    continue
                with marker.open("rb") as stream:
                    marked = stream.read(128) == OWNER.encode()
                if marked:
                    owned.append(path)
            owned.sort(key=lambda p: (p.stat().st_mtime_ns, p.name))
            for path in owned[:max(0, len(owned) - retain + 1)]:
                shutil.rmtree(path)
            self.path = root / f"run-{uuid.uuid4().hex}"
            self.path.mkdir(mode=0o700)
            self.used = 0
            self.limit = max_bytes
            self.write(MARKER, OWNER.encode())
        except BaseException:
            os.close(self.lock)
            raise

    def write(self, name, data, diagnostic=False):
        ceiling = self.limit if diagnostic else self.limit - DIAGNOSTIC_RESERVE
        available = max(0, ceiling - self.used)
        retained = data[:available]
        with (self.path / name).open("ab") as stream:
            stream.write(retained)
        self.used += len(retained)
        if len(retained) != len(data):
            raise RuntimeError(f"capture artifact byte limit exceeded ({self.limit} bytes)")

    def json(self, name, value, diagnostic=False):
        self.write(name, (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode(), diagnostic)

    def close(self):
        os.close(self.lock)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_identity(binary, deadline):
    root = Path(__file__).resolve().parents[1]
    result = {"path": str(binary), "sha256": sha256_file(binary),
              "bytes": binary.stat().st_size, "mtime_ns": binary.stat().st_mtime_ns}
    checkout = {"path": str(root),
                "meaning": "Capture checkout context only; not provenance of the supplied binary."}
    for target, key, command in ((checkout, "source_revision", ["git", "rev-parse", "HEAD"]),
                                (result, "go_build_info", ["go", "version", "-m", str(binary)])):
        try:
            completed = subprocess.run(command, cwd=root, capture_output=True, timeout=max(0.01, min(2, deadline - time.monotonic())), check=False)
            target[key] = {"status": completed.returncode, "stdout": completed.stdout[:8192].decode(errors="replace"),
                           "stderr": completed.stderr[:2048].decode(errors="replace")}
        except (OSError, subprocess.TimeoutExpired) as error:
            target[key] = {"unavailable": str(error)}
    # These files belong to this capture checkout, not necessarily --binary's build.
    sources = {}
    for path in sorted((root / "go/tui").rglob("*")):
        if path.is_file() and path.suffix in (".go", ".mod", ".sum"):
            sources[str(path.relative_to(root))] = sha256_file(path)
    checkout["go_tui_source_sha256"] = hashlib.sha256(json.dumps(sources, sort_keys=True).encode()).hexdigest()
    checkout["driver_sources"] = {name: sha256_file(root / "scripts" / name) for name in (
        "go_tui_capture.py", "go_tui_boot_smoke.py", "go_tui_capture_requirements.txt")}
    result["capture_checkout_context"] = checkout
    return result


class TerminalGrid:
    """Thin pyte adapter: incremental UTF-8, stateful VT parsing, DSR replies.

    Qualification is emitted-output-specific, not full xterm compatibility.
    Private color/mouse/synchronized-output modes may be ignored by pyte: text grids do not prove color, animation, pixel placement, or live interactions.
    """

    def __init__(self, pyte, columns, rows):
        self.replies = bytearray()
        replies = self.replies

        class Screen(pyte.Screen):
            def write_process_input(self, data):
                replies.extend(data.encode())

        self.screen = Screen(columns, rows)
        self.stream = pyte.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")("strict")
        self.bytes = 0

    def feed(self, chunk):
        self.bytes += len(chunk)
        self.stream.feed(self.decoder.decode(chunk))

    def lines(self):
        return list(self.screen.display)


def matches(lines, step):
    # Visible labels must be complete ASCII words/phrases: STATUS_NEW must not accept STATUS_NEWS after a renderer forgets to erase a shortened line.
    # Absence intentionally stays substring-based to catch all stale residues.
    return (any(line.strip() for line in lines) and
            all(any(re.search(r"(?<![A-Za-z0-9_])" + re.escape(label) + r"(?![A-Za-z0-9_])", line)
                    for line in lines) for label in step["present"]) and
            all(not any(label in line for line in lines) for label in step["absent"]))


def comparison_grid(lines, masks):
    # Columns here are terminal cells, not Python string offsets (wide glyphs).
    from wcwidth import wcwidth
    result = []
    for row, line in enumerate(lines):
        active = [m for m in masks if m["row"] == row]
        col = 0
        chars = []
        for char in line:
            width = max(0, wcwidth(char))
            masked = any(col < m["col"] + m["length"] and col + max(1, width) > m["col"] for m in active)
            chars.append(" " * width if masked else char)
            col += width
        result.append("".join(chars))
    return result


def capture_size(binary, size, corpus, pyte, artifacts, args, deadline, report):
    name = size["name"]
    started = time.monotonic()
    grid = TerminalGrid(pyte, size["columns"], size["rows"])
    child = None
    current_step = "startup"
    report.update(name=name, columns=size["columns"], rows=size["rows"], steps=[])

    def on_data(kind, chunk):
        artifacts.write(f"{name}.{kind}.bin", chunk)
        if kind == "terminal":
            grid.feed(chunk)
            if grid.replies and child is not None:
                if len(child.tty_pending) + len(grid.replies) > 4096:
                    raise RuntimeError("terminal query reply byte limit exceeded")
                child.tty_pending.extend(grid.replies)
                grid.replies.clear()

    try:
        child = RendererProcess(binary, size["columns"], size["rows"], on_data)
        ready = child.ready(size["columns"], size["rows"], min(deadline, time.monotonic() + args.step_timeout))
        report["ready_payload_base64"] = base64.b64encode(ready).decode()
        for step in size["steps"]:
            current_step = step["label"]
            step_deadline = min(deadline, time.monotonic() + args.step_timeout)
            before = grid.bytes
            child.send_packet(base64.b64decode(step["payload_base64"]), step_deadline)
            stable_since = None
            previous = None
            while True:
                child.pump(step_deadline)
                child.check_alive()
                lines = grid.lines()
                if grid.bytes > before and not grid.decoder.getstate()[0] and matches(lines, step):
                    if lines != previous:
                        stable_since = time.monotonic()
                    elif time.monotonic() - stable_since >= 0.1:
                        break
                else:
                    stable_since = None
                previous = lines if stable_since is not None else None
            artifacts.json(f"{name}.{current_step}.grid.json", lines)
            artifacts.write(f"{name}.{current_step}.txt", ("\n".join(lines) + "\n").encode())
            masks = [m for m in corpus["dynamic_cells"] if m["size"] == name and m["step"] == current_step]
            if masks:
                artifacts.write(f"{name}.{current_step}.comparison.txt", ("\n".join(comparison_grid(lines, masks)) + "\n").encode())
            report["steps"].append({"label": current_step, "terminal_byte_start": before,
                                    "terminal_byte_end": grid.bytes, "present": step["present"], "absent": step["absent"]})
        child.check_alive()
    except BaseException:
        report["failed_step"] = current_step
        # Preserve the last decoded state even when a required label never arrived.
        artifacts.json(f"{name}.{current_step}.partial.grid.json", grid.lines(), diagnostic=True)
        raise
    finally:
        if child is not None:
            child.close()
            report["exit_status"] = child.proc.returncode
            report["shutdown_action"] = child.shutdown_action
            report["stderr_excerpt"] = child.stderr.decode(errors="replace")[:8192]
        report["wall_seconds"] = round(time.monotonic() - started, 6)
        if child is not None and "failed_step" not in report and (
                child.close_error or child.shutdown_action or child.proc.returncode != 0):
            report["failed_step"] = "shutdown"
            artifacts.json(f"{name}.shutdown.partial.grid.json", grid.lines(), diagnostic=True)
            raise RuntimeError(f"renderer shutdown failed (status {child.proc.returncode}, forced action {child.shutdown_action}, cleanup error {child.close_error})")


def bounded_float(maximum):
    def parse(value):
        number = float(value)
        if not math.isfinite(number) or not 0 < number <= maximum:
            raise argparse.ArgumentTypeError(f"must be >0 and <= {maximum}")
        return number
    return parse


def bounded_int(minimum, maximum):
    def parse(value):
        number = int(value)
        if not minimum <= number <= maximum:
            raise argparse.ArgumentTypeError(f"must be {minimum}..{maximum}")
        return number
    return parse


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--step-timeout", type=bounded_float(MAX_STEP), default=MAX_STEP)
    parser.add_argument("--wall-timeout", type=bounded_float(MAX_WALL), default=MAX_WALL)
    parser.add_argument("--max-bytes", type=bounded_int(128 * 1024, MAX_BYTES), default=MAX_BYTES)
    parser.add_argument("--retain-runs", type=bounded_int(1, MAX_RUNS), default=MAX_RUNS)
    args = parser.parse_args(argv)
    started = time.monotonic()
    deadline = started + args.wall_timeout
    artifacts = None
    metadata = {"version": 1, "status": "failed", "sizes": []}
    try:
        pyte, versions = decoder_dependencies()
        corpus, raw = read_corpus(args.corpus)
        binary = args.binary.resolve(strict=True)
        artifacts = Artifacts(args.output, args.max_bytes, args.retain_runs)
        artifacts.write("corpus.json", raw)
        metadata.update(binary=build_identity(binary, deadline), theme=corpus["theme"],
                        corpus={"path": str(args.corpus.absolute()), "sha256": hashlib.sha256(raw).hexdigest()},
                        emulator=versions, dynamic_cells=corpus["dynamic_cells"],
                        qualification="Stateful pyte text grid of emitted PTY bytes; not pixel/color/animation or live-interaction proof.",
                        bounds={"step_seconds": args.step_timeout, "wall_seconds": args.wall_timeout,
                                "artifact_bytes": args.max_bytes, "retained_runs": args.retain_runs,
                                "cleanup_grace_seconds_per_size": 0.6},
                        terminal={"TERM": "xterm-256color", "COLORTERM": "truecolor", "winsize": "TIOCSWINSZ"})
        for size in corpus["sizes"]:
            report = {}
            metadata["sizes"].append(report)
            capture_size(binary, size, corpus, pyte, artifacts, args, deadline, report)
        if time.monotonic() > deadline:
            raise TimeoutError("total capture wall deadline exceeded")
        metadata["status"] = "passed"
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, EOFError, TimeoutError) as error:
        metadata["error"] = f"{type(error).__name__}: {error}"
        print(f"[go-tui-capture] FAIL: {metadata['error']}", file=sys.stderr)
    finally:
        metadata["wall_seconds"] = round(time.monotonic() - started, 6)
        if artifacts is not None:
            try:
                metadata["stored_bytes_before_metadata"] = artifacts.used
                artifacts.json("metadata.json", metadata, diagnostic=True)
            except (OSError, RuntimeError) as error:
                metadata["status"] = "failed"
                print(f"[go-tui-capture] FAIL: retaining metadata: {error}", file=sys.stderr)
            print(f"[go-tui-capture] artifacts: {artifacts.path}", file=sys.stderr)
            artifacts.close()
    if metadata["status"] != "passed":
        return 1
    print(f"[go-tui-capture] PASS: {artifacts.path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
