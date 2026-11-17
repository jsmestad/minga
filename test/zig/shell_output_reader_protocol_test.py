#!/usr/bin/env python3
"""Standalone packet4 client for the native shell reader; no BEAM or model needed."""

import contextlib
import fcntl
import os
from pathlib import Path
import select
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import termios
import unittest


HELPER = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else None
DEMAND = struct.pack(">I", 1) + b"\x05"


class Reader:
    def __init__(self, helper, temporary, output_fd=None):
        self.process = subprocess.Popen(
            [str(helper)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE if output_fd is None else output_fd,
            stderr=subprocess.PIPE, env=dict(os.environ, TMPDIR=temporary), bufsize=0,
        )

    def await_ready(self, temporary):
        ready = self.frame()
        assert ready[:1] == b"\x01", ready
        self.fifo = Path(ready[1:].decode("utf-8"))
        assert self.fifo.is_absolute() and b"\x00" not in ready[1:]
        assert self.fifo.parent.parent == Path(temporary).resolve(strict=True)
        assert stat.S_IMODE(self.fifo.parent.stat().st_mode) == 0o700
        assert stat.S_ISFIFO(self.fifo.stat().st_mode)
        assert stat.S_IMODE(self.fifo.stat().st_mode) == 0o600

    def exact(self, count):
        result = bytearray()
        deadline = time.monotonic() + 3
        while len(result) < count:
            assert select.select([self.process.stdout], [], [], max(0, deadline - time.monotonic()))[0], "frame timed out"
            chunk = os.read(self.process.stdout.fileno(), count - len(result))
            assert chunk, ("unexpected protocol EOF", self.process.poll(), self.process.stderr.read())
            result.extend(chunk)
        return bytes(result)

    def frame(self):
        length, = struct.unpack(">I", self.exact(4))
        assert 1 <= length <= 65537, length
        return self.exact(length)

    def send(self, packet=DEMAND):
        self.process.stdin.write(packet)

    def quiet(self):
        assert not select.select([self.process.stdout], [], [], 0.1)[0], "unsolicited response"

    def close(self):
        try:
            with contextlib.ExitStack() as cleanup:
                for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                    cleanup.callback(stream.close)
        finally:
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=3)
                raise

    def exited(self, expected=0):
        code = self.process.wait(timeout=3)
        assert code == expected, (code, self.process.stderr.read())
        assert not self.fifo.exists()
        assert not self.fifo.parent.exists()
        assert self.process.stderr.read() == b""


class ProtocolTest(unittest.TestCase):
    @contextlib.contextmanager
    def reader(self, output_pipe=None):
        with tempfile.TemporaryDirectory(prefix="minga-reader-contract-") as temporary, contextlib.ExitStack() as streams:
            output_stream = None
            if output_pipe is not None:
                output_stream = streams.enter_context(os.fdopen(output_pipe[0], "rb", buffering=0, closefd=False))
            reader = Reader(HELPER, temporary, None if output_pipe is None else output_pipe[1])
            try:
                if output_stream is not None:
                    reader.process.stdout = output_stream
                reader.await_ready(temporary)
                yield reader
            finally:
                reader.close()
            self.assertEqual(list(Path(temporary).iterdir()), [])

    @contextlib.contextmanager
    def output_pipe(self):
        pipe = list(os.pipe())
        try:
            yield pipe
        finally:
            for fd in pipe:
                if fd is not None:
                    os.close(fd)

    def test_small_binary_output_is_immediate_and_one_demand_gated(self):
        with self.reader() as reader:
            writer = os.open(reader.fifo, os.O_WRONLY)
            try:
                reader.quiet()  # Dummy writer prevents startup EOF, no demand.
                os.write(writer, b"\x00\xffsmall\n")
                reader.quiet()
                reader.send()
                self.assertEqual(reader.frame(), b"\x02\x00\xffsmall\n")
                # Writer is still open: the short read cannot wait for EOF.
                os.write(writer, b"next\x80")
                reader.quiet()
                reader.send()
                self.assertEqual(reader.frame(), b"\x02next\x80")
            finally:
                os.close(writer)
            reader.quiet()  # EOF also requires its own credit.
            reader.send()
            self.assertEqual(reader.frame(), b"\x03")
            reader.exited()

    def test_exact_binary_identity_across_bounded_frames(self):
        corpus = bytes(range(256)) * 528  # 135168 exact, including every byte value.
        with self.reader() as reader:
            writer = os.open(reader.fifo, os.O_WRONLY)
            failures = []

            def produce():
                try:
                    remaining = memoryview(corpus)
                    while remaining:
                        n = os.write(writer, remaining)
                        remaining = remaining[n:]
                except BaseException as error:
                    failures.append(error)
                finally:
                    os.close(writer)

            producer = threading.Thread(target=produce)
            producer.start()
            actual = bytearray()
            while True:
                reader.send()
                frame = reader.frame()
                if frame == b"\x03":
                    break
                self.assertEqual(frame[0], 2)
                self.assertTrue(1 <= len(frame) - 1 <= 65536)
                actual.extend(frame[1:])
            producer.join(timeout=3)
            self.assertFalse(producer.is_alive())
            self.assertEqual(failures, [])
            self.assertEqual(actual, corpus)
            reader.exited()

    def test_first_demand_releases_dummy_writer_for_empty_eof(self):
        with self.reader() as reader:
            writer = os.open(reader.fifo, os.O_WRONLY)
            os.close(writer)
            reader.quiet()
            reader.send()
            self.assertEqual(reader.frame(), b"\x03")
            reader.exited()

    def test_pending_credit_observes_later_writer_close_without_another_request(self):
        with self.reader() as reader:
            writer = os.open(reader.fifo, os.O_WRONLY)
            try:
                reader.send()
                reader.quiet()
            finally:
                os.close(writer)
            self.assertEqual(reader.frame(), b"\x03")
            reader.exited()

    def test_pending_credit_waits_for_later_bytes_without_fabricating_eof(self):
        with self.reader() as reader:
            writer = os.open(reader.fifo, os.O_WRONLY)
            try:
                reader.send()
                reader.quiet()
                os.write(writer, b"later\x00\xff")
                self.assertEqual(reader.frame(), b"\x02later\x00\xff")
                reader.quiet()
            finally:
                os.close(writer)
            reader.send()
            self.assertEqual(reader.frame(), b"\x03")
            reader.exited()

    def test_fragmented_request_is_not_a_credit_until_complete(self):
        with self.reader() as reader:
            writer = os.open(reader.fifo, os.O_WRONLY)
            try:
                os.write(writer, b"one")
                for byte in DEMAND[:-1]:
                    reader.send(bytes([byte]))
                    reader.quiet()
                reader.send(DEMAND[-1:])
                self.assertEqual(reader.frame(), b"\x02one")
            finally:
                os.close(writer)
            reader.send()
            self.assertEqual(reader.frame(), b"\x03")
            reader.exited()

    def test_idle_and_pending_control_close_cleanup(self):
        for pending in (False, True):
            with self.subTest(pending=pending), self.reader() as reader:
                writer = os.open(reader.fifo, os.O_WRONLY)
                try:
                    if pending:
                        reader.send()
                        reader.quiet()
                    reader.process.stdin.close()
                    reader.exited()
                finally:
                    os.close(writer)

    def test_partial_request_control_close_cleanup(self):
        with self.reader() as reader:
            reader.send(b"\x00\x00")
            reader.process.stdin.close()
            self.assertEqual(reader.frame()[0], 4)
            reader.exited(expected=1)

    def test_malformed_and_oversized_packets_fail_explicitly(self):
        for packet in (struct.pack(">I", 0), struct.pack(">I", 2),
                       struct.pack(">I", 0xFFFFFFFF), struct.pack(">I", 1) + b"\xff"):
            with self.subTest(packet=packet), self.reader() as reader:
                reader.send(packet)
                frame = reader.frame()
                self.assertEqual(frame[0], 4)
                self.assertTrue(1 <= len(frame) - 1 <= 1024)
                reader.exited(expected=1)

    def test_second_pending_demand_fails_without_prefetch(self):
        with self.reader() as reader:
            writer = os.open(reader.fifo, os.O_WRONLY)
            try:
                reader.send()
                reader.quiet()
                reader.send()
                self.assertEqual(reader.frame(), b"\x04DemandAlreadyPending")
                reader.exited(expected=1)
            finally:
                os.close(writer)

    def test_parent_output_close_cleans_idle_and_pending_readers(self):
        for pending in (False, True):
            with self.subTest(pending=pending), self.reader() as reader:
                writer = os.open(reader.fifo, os.O_WRONLY)
                try:
                    if pending:
                        reader.send()
                        reader.quiet()
                    reader.process.stdout.close()
                    reader.exited()
                finally:
                    os.close(writer)

    def test_channel_close_cleans_blocked_response_write(self):
        for closure in ("control", "control_with_unread_bytes", "output"):
            with self.subTest(closure=closure), self.output_pipe() as pipe, self.reader(pipe) as reader:
                os.set_blocking(pipe[1], False)
                filled = 0
                while True:
                    try:
                        filled += os.write(pipe[1], b"x" * 65536)
                        self.assertLessEqual(filled, 1024 * 1024, "output pipe did not reach finite backpressure")
                    except BlockingIOError:
                        break
                writer = os.open(reader.fifo, os.O_WRONLY | os.O_NONBLOCK)
                try:
                    os.write(writer, b"blocked response")
                    reader.send()
                    deadline = time.monotonic() + 3
                    while struct.unpack("i", fcntl.ioctl(writer, termios.FIONREAD, struct.pack("i", 0)))[0]:
                        self.assertLess(time.monotonic(), deadline, "helper did not consume the requested FIFO bytes")
                        threading.Event().wait(0.005)
                    # FIFO bytes were consumed, but the full stdout pipe prevents even the response header from being delivered.
                    if closure == "output":
                        reader.process.stdout.close()
                        os.close(pipe[0])
                        pipe[0] = None
                    else:
                        if closure == "control_with_unread_bytes":
                            reader.send(b"\x00\x00")
                        reader.process.stdin.close()
                    reader.exited()
                finally:
                    os.close(writer)


if __name__ == "__main__":
    if HELPER is None:
        raise SystemExit("usage: shell_output_reader_protocol_test.py /absolute/path/to/helper")
    unittest.main(verbosity=2)
