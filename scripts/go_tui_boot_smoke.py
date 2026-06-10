#!/usr/bin/env python3
"""Boot smoke test for the default Go/Bubble Tea terminal renderer.

Boots the production `minga-renderer-go` binary the way the BEAM launch path
does: it allocates a real PTY, points `MINGA_TTY` at it (so the renderer can
drive a terminal), and keeps stdin/stdout as the packet protocol channel. The
renderer emits a `{:packet, 4}`-framed "ready" frame as its first action; this
script reads that frame and verifies it is a well-formed first frame with a
sane terminal size.

This is the headless first-frame check for ticket #2222 (AC4 + AC5): the
renderer consumes `MINGA_TTY` and produces a rendered first frame, with no
real controlling terminal required (CI runs have none).

Usage:
    python3 scripts/go_tui_boot_smoke.py [path/to/minga-renderer-go]

Exit codes:
    0  ready frame received and valid
    1  smoke test failed (no frame, malformed frame, or renderer error)
"""

import os
import pty
import select
import struct
import subprocess
import sys
import time

OP_READY = 0x03
# 4-byte big-endian length prefix + at least opcode + width(2) + height(2).
MIN_READY_PAYLOAD = 5
READ_TIMEOUT_SECONDS = 10.0


def default_binary_path() -> str:
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(repo_root, "priv", "minga-renderer-go")


def read_exact(fd: int, count: int, deadline: float) -> bytes:
    """Read exactly count bytes from fd, honoring an absolute deadline."""
    buffer = b""
    while len(buffer) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(
                f"timed out reading {count} bytes (got {len(buffer)})"
            )
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            continue
        chunk = os.read(fd, count - len(buffer))
        if not chunk:
            raise EOFError(
                f"renderer closed the protocol channel after {len(buffer)} bytes"
            )
        buffer += chunk
    return buffer


def main() -> int:
    binary = sys.argv[1] if len(sys.argv) > 1 else default_binary_path()

    if not os.path.exists(binary):
        print(
            f"[go-tui-boot-smoke] FAIL: renderer binary not found at {binary}\n"
            "Build it first: mix native.build.go_tui",
            file=sys.stderr,
        )
        return 1

    # Allocate a PTY. The slave becomes the renderer's MINGA_TTY so it can drive
    # a "terminal" without inheriting CI's (absent) controlling terminal.
    pty_master, pty_slave = pty.openpty()
    tty_path = os.ttyname(pty_slave)

    # The protocol channel is a plain pipe on the renderer's stdin/stdout, kept
    # separate from the PTY exactly like the BEAM Port boundary.
    proto_read, proto_write = os.pipe()  # renderer stdout -> us
    stdin_read, stdin_write = os.pipe()  # us -> renderer stdin (unused input)

    env = dict(os.environ)
    env["MINGA_TTY"] = tty_path
    env.setdefault("COLUMNS", "80")
    env.setdefault("LINES", "24")

    proc = subprocess.Popen(
        [binary],
        stdin=stdin_read,
        stdout=proto_write,
        stderr=subprocess.PIPE,
        env=env,
        close_fds=True,
    )

    # Close our copies of the child's ends so EOF propagates correctly.
    os.close(proto_write)
    os.close(stdin_read)

    deadline = time.monotonic() + READ_TIMEOUT_SECONDS
    try:
        length_bytes = read_exact(proto_read, 4, deadline)
        (length,) = struct.unpack(">I", length_bytes)

        if length < MIN_READY_PAYLOAD:
            print(
                f"[go-tui-boot-smoke] FAIL: first frame too short ({length} bytes)",
                file=sys.stderr,
            )
            return 1

        payload = read_exact(proto_read, length, deadline)
    except (TimeoutError, EOFError) as error:
        stderr = drain_stderr(proc)
        print(
            f"[go-tui-boot-smoke] FAIL: {error}\nrenderer stderr:\n{stderr}",
            file=sys.stderr,
        )
        return 1
    finally:
        terminate(proc)
        for fd in (pty_master, pty_slave, proto_read, stdin_write):
            close_quietly(fd)

    opcode = payload[0]
    if opcode != OP_READY:
        print(
            f"[go-tui-boot-smoke] FAIL: first frame opcode 0x{opcode:02x}, "
            f"expected ready (0x{OP_READY:02x})",
            file=sys.stderr,
        )
        return 1

    width, height = struct.unpack(">HH", payload[1:5])
    if width == 0 or height == 0:
        print(
            f"[go-tui-boot-smoke] FAIL: ready frame has zero size ({width}x{height})",
            file=sys.stderr,
        )
        return 1

    print(
        f"[go-tui-boot-smoke] PASS: Go renderer booted and emitted a "
        f"{width}x{height} ready frame via MINGA_TTY={tty_path}"
    )
    return 0


def drain_stderr(proc: subprocess.Popen) -> str:
    try:
        return (proc.stderr.read() or b"").decode(errors="replace")
    except Exception:  # noqa: BLE001 - best-effort diagnostics only
        return "<unavailable>"


def terminate(proc: subprocess.Popen) -> None:
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def close_quietly(fd: int) -> None:
    try:
        os.close(fd)
    except OSError:
        pass


if __name__ == "__main__":
    sys.exit(main())
