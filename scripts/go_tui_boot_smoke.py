#!/usr/bin/env python3
"""Check production Go renderer protocol startup, not rendered output.

The ready packet precedes Bubble Tea rendering.
It proves only startup and terminal sizing.
Real terminal-output evidence is scripts/go_tui_capture.py; model-only coverage (#2101) and legacy Zig snapshots prove different contracts.

Usage: python3 scripts/go_tui_boot_smoke.py [path/to/minga-renderer-go]
"""

import errno
import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import termios
import time
import tty

OP_READY = 0x03
MIN_READY_PAYLOAD = 5
READ_TIMEOUT_SECONDS = 10.0
MAX_STREAM_BYTES = 32 * 1024 * 1024


def default_binary_path() -> str:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(root, "priv", "minga-renderer-go")


class RendererProcess:
    """One real PTY plus separate protocol pipes, drained together with stderr.

    All I/O is nonblocking.
    Callers supply absolute deadlines and may retain stream chunks through on_data(kind, bytes).
    close() always reaps the child, including after startup, callback, protocol, or byte-limit failures.
    """

    def __init__(self, binary, columns=80, rows=24, on_data=None):
        self.proc = None
        self.master = self.slave = None
        self.close_error = None
        self.shutdown_action = None
        self.readers = {}
        self.on_data = on_data
        self.stderr = bytearray()
        self.protocol = bytearray()
        self.reading_ready = True
        self.stream_bytes = 0
        self.tty_pending = bytearray()
        try:
            self.master, self.slave = pty.openpty()
            tty.setraw(self.slave)
            fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                        struct.pack("HHHH", rows, columns, 0, 0))
            self.tty_path = os.ttyname(self.slave)
            env = dict(os.environ, MINGA_TTY=self.tty_path,
                       COLUMNS=str(columns), LINES=str(rows), TERM="xterm-256color",
                       COLORTERM="truecolor")
            self.proc = subprocess.Popen(
                [os.fspath(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, env=env, close_fds=True, bufsize=0,
            )
            self.readers = {self.master: "terminal", self.proc.stdout.fileno(): "protocol",
                            self.proc.stderr.fileno(): "stderr"}
            for fd in (*self.readers, self.proc.stdin.fileno()):
                os.set_blocking(fd, False)
        except BaseException:
            self.close()
            raise

    def pump(self, deadline, write_fd=None, pending=None):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("renderer read/wall deadline exceeded")
        writers = []
        if pending:
            writers.append(write_fd)
        if self.tty_pending:
            writers.append(self.master)
        readable, writable, _ = select.select(list(self.readers), writers, [], min(remaining, 0.05))
        for fd in readable:
            try:
                chunk = os.read(fd, 65536)
            except OSError as error:
                if error.errno == errno.EIO and fd == self.master:
                    chunk = b""
                else:
                    raise
            kind = self.readers[fd]
            if not chunk:
                del self.readers[fd]
                continue
            self.stream_bytes += len(chunk)
            if kind == "stderr":
                self.stderr.extend(chunk[:max(0, 65536 - len(self.stderr))])
            if self.on_data:
                self.on_data(kind, chunk)
            if self.stream_bytes > MAX_STREAM_BYTES:
                raise RuntimeError("renderer stream byte limit exceeded")
            if kind == "protocol" and self.reading_ready:
                self.protocol.extend(chunk)
        for fd in writable:
            data = self.tty_pending if fd == self.master else pending
            try:
                count = os.write(fd, data)
            except BlockingIOError:
                continue
            del data[:count]

    def check_alive(self):
        code = self.proc.poll()
        if code is not None:
            raise RuntimeError(f"renderer exited unexpectedly (status {code})")

    def ready(self, columns, rows, deadline):
        while len(self.protocol) < 4:
            self.pump(deadline)
            self.check_alive()
            if self.proc.stdout.fileno() not in self.readers:
                raise EOFError("renderer closed protocol before ready")
        length = struct.unpack(">I", self.protocol[:4])[0]
        if not MIN_READY_PAYLOAD <= length <= 65536:
            raise ValueError(f"invalid ready payload length: {length}")
        while len(self.protocol) < length + 4:
            self.pump(deadline)
            self.check_alive()
        payload = bytes(self.protocol[4:length + 4])
        self.protocol.clear()
        self.reading_ready = False
        if payload[0] != OP_READY:
            raise ValueError(f"first protocol opcode is 0x{payload[0]:02x}, not ready")
        width, height = struct.unpack(">HH", payload[1:5])
        if (width, height) != (columns, rows):
            raise ValueError(f"ready size {width}x{height}, expected {columns}x{rows}")
        return payload

    def send_packet(self, payload, deadline):
        pending = bytearray(struct.pack(">I", len(payload)) + payload)
        if self.on_data:
            self.on_data("input", bytes(pending))
        while pending:
            self.check_alive()
            self.pump(deadline, self.proc.stdin.fileno(), pending)

    def close(self):
        if self.proc is not None:
            if self.proc.stdin is not None:
                self.proc.stdin.close()
            # EOF is the production shutdown path.
            # Keep both output channels moving while it exits; never read stderr synchronously to EOF.
            for action in (None, "terminate", "kill"):
                if action and self.proc.poll() is None:
                    self.shutdown_action = action
                    getattr(self.proc, action)()
                deadline = time.monotonic() + 0.2
                while time.monotonic() < deadline:
                    try:
                        self.pump(deadline)
                    except (OSError, ValueError, RuntimeError, TimeoutError) as error:
                        self.close_error = self.close_error or str(error)
                        self.on_data = None
                    if self.proc.poll() is not None and not select.select(list(self.readers), [], [], 0)[0]:
                        break
                if self.proc.poll() is not None:
                    break
            if self.proc.poll() is None:
                self.shutdown_action = "kill"
                self.proc.kill()
            self.proc.wait()
            for stream in (self.proc.stdout, self.proc.stderr):
                if stream is not None:
                    stream.close()
        for fd in (self.master, self.slave):
            if fd is not None:
                os.close(fd)
        self.master = self.slave = None
        self.readers.clear()


def main() -> int:
    binary = sys.argv[1] if len(sys.argv) > 1 else default_binary_path()
    child = None
    try:
        child = RendererProcess(binary)
        child.ready(80, 24, time.monotonic() + READ_TIMEOUT_SECONDS)
    except (OSError, ValueError, RuntimeError, EOFError, TimeoutError) as error:
        if child:
            child.close()
        stderr = child.stderr.decode(errors="replace") if child else ""
        print(f"[go-tui-boot-smoke] FAIL: {error}\nrenderer stderr:\n{stderr}", file=sys.stderr)
        return 1
    else:
        child.close()
    print("[go-tui-boot-smoke] PASS: Go renderer emitted an 80x24 ready packet (protocol startup only)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
