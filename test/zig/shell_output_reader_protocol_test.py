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
import unittest


HELPER = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else None
DEMAND = struct.pack(">I", 1) + b"\x05"


class Reader:
    def __init__(self, helper, temporary):
        self.process = subprocess.Popen(
            [str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=dict(os.environ, TMPDIR=temporary), bufsize=0,
        )
        ready = self.frame()
        assert ready[:1] == b"\x01", ready
        self.fifo = Path(ready[1:].decode("utf-8"))
        assert self.fifo.is_absolute() and b"\x00" not in ready[1:]
        assert self.fifo.parent.parent == Path(temporary)
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

    def exited(self, expected=0):
        code = self.process.wait(timeout=3)
        assert code == expected, (code, self.process.stderr.read())
        assert not self.fifo.exists()
        assert not self.fifo.parent.exists()
        assert self.process.stderr.read() == b""


class ProtocolTest(unittest.TestCase):
    @contextlib.contextmanager
    def reader(self):
        with tempfile.TemporaryDirectory(prefix="minga-reader-contract-") as temporary:
            reader = Reader(HELPER, temporary)
            try:
                yield reader
            finally:
                if not reader.process.stdin.closed:
                    reader.process.stdin.close()
                if reader.process.poll() is None:
                    reader.process.wait(timeout=3)
                reader.process.stdout.close()
                reader.process.stderr.close()
            self.assertEqual(list(Path(temporary).iterdir()), [])

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

    @unittest.skipUnless(hasattr(fcntl, "F_SETPIPE_SZ"), "Linux pipe-capacity fixture")
    def test_control_close_cleans_blocked_response_write(self):
        with self.reader() as reader:
            fcntl.fcntl(reader.process.stdout, fcntl.F_SETPIPE_SZ, 4096)
            writer = os.open(reader.fifo, os.O_WRONLY | os.O_NONBLOCK)
            try:
                n = os.write(writer, b"x" * 65536)
                self.assertGreaterEqual(n, 4096)
                reader.send()
                self.assertTrue(select.select([reader.process.stdout], [], [], 3)[0])
                # Do not drain stdout: header + payload exceeds its pipe capacity.
                reader.process.stdin.close()
                reader.exited()
            finally:
                os.close(writer)


if __name__ == "__main__":
    if HELPER is None:
        raise SystemExit("usage: shell_output_reader_protocol_test.py /absolute/path/to/helper")
    unittest.main(verbosity=2)
