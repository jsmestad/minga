#!/usr/bin/env python3
"""Exercise acquisition, process ownership, unsafe inputs and receipt invalidation.

No synthetic successful source-build receipt substitutes for native qualification.
"""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/build-release-erts.py"
SPEC = importlib.util.spec_from_file_location("release_erts_producer", SCRIPT)
PRODUCER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCER)
MANIFEST = json.loads(SCRIPT.with_name("release_erts_sources.json").read_text())
HOST_OS = {"Darwin": "macos", "Linux": "linux"}[platform.system()]
HOST_ARCH = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64"}[platform.machine()]


class Response(io.BytesIO):
    status = 200

    def geturl(self):
        return "https://source.example/official.tar.gz"


class ProducerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="erts-producer-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / "output"
        self.output.mkdir()

    def command_runner(self, seconds=5):
        work = self.root / "commands"
        work.mkdir()
        return PRODUCER.Commands(work, PRODUCER.private_environment(work), seconds=seconds)

    def fail_build(self, callback):
        (self.output / "receipt.json").write_text('{"kind":"local-source-build"}')
        (self.output / "erts.tar.gz").write_bytes(b"stale archive")
        with mock.patch.object(PRODUCER, "native_build", side_effect=callback):
            with self.assertRaises(PRODUCER.BuildError) as failure:
                PRODUCER.produce(HOST_OS, HOST_ARCH, self.output, worker=HOST_OS == "linux")
        self.assertFalse((self.output / "receipt.json").exists())
        self.assertFalse((self.output / ".producer.lock").exists())
        return str(failure.exception)

    def test_corrupt_download_is_removed_and_never_retried(self):
        source = {"url": "https://source.example/official.tar.gz",
                  "sha256": hashlib.sha256(b"official source").hexdigest()}
        destination = self.root / "source.tar.gz"
        with mock.patch.object(PRODUCER.urllib.request, "urlopen", return_value=Response(b"corrupt source")) as fetch:
            with self.assertRaises(PRODUCER.BuildError):
                PRODUCER.download(source, destination)
        fetch.assert_called_once()
        self.assertFalse(destination.exists())

    def test_download_timeout_is_not_retried_or_replaced(self):
        source = {"url": "https://source.example/official.tar.gz", "sha256": "0" * 64}
        destination = self.root / "source.tar.gz"
        with mock.patch.object(PRODUCER.urllib.request, "urlopen", side_effect=TimeoutError("bounded")) as fetch:
            with self.assertRaises(TimeoutError):
                PRODUCER.download(source, destination)
        fetch.assert_called_once()
        self.assertFalse(destination.exists())

    def test_redirect_outside_https_is_rejected(self):
        response = Response(b"source")
        response.geturl = lambda: "http://source.example/source"
        with mock.patch.object(PRODUCER.urllib.request, "urlopen", return_value=response):
            with self.assertRaises(PRODUCER.BuildError):
                PRODUCER.download({"url": "https://source.example/source", "sha256": "0" * 64}, self.root / "source")

    def test_unexpected_archive_root_and_traversal_never_extract(self):
        for name in ("another-root/file", "otp/../outside", "/otp/file"):
            with self.subTest(name=name):
                archive = self.root / "source.tar.gz"
                with tarfile.open(archive, "w:gz") as tar:
                    member = tarfile.TarInfo(name)
                    member.size = 1
                    tar.addfile(member, io.BytesIO(b"x"))
                with self.assertRaises(PRODUCER.BuildError):
                    PRODUCER.unpack_source(archive, self.root, "otp")
                self.assertFalse((self.root / "otp").exists())
                self.assertFalse((self.root / "outside").exists())

    def test_regularization_preserves_link_bytes_modes_and_directory_contents(self):
        source = self.root / "otp"
        source.mkdir()
        library = source / "library"
        library.mkdir()
        executable = library / "program"
        executable.write_bytes(b"native program bytes")
        executable.chmod(0o755)
        (source / "directory-alias").symlink_to("library", target_is_directory=True)
        (source / "file-alias").symlink_to("library/program")
        os.link(executable, source / "hard-alias")
        destination = self.root / "regular"
        PRODUCER.regularize_tree(source, destination)
        for relative in ("library/program", "directory-alias/program", "file-alias", "hard-alias"):
            path = destination / relative
            self.assertFalse(path.is_symlink())
            self.assertEqual(path.read_bytes(), b"native program bytes")
            self.assertEqual(path.stat().st_mode & 0o777, 0o755)
        self.assertFalse(any(p.is_symlink() for p in destination.rglob("*")))

    def test_dangling_outside_and_cyclic_release_links_fail_closed(self):
        outside = self.root / "outside"
        outside.write_bytes(b"not a release input")
        for link in ("../outside", "missing", "."):
            with self.subTest(link=link):
                source = self.root / ("source-" + str(len(list(self.root.iterdir()))))
                source.mkdir()
                (source / "bad").symlink_to(link)
                with self.assertRaises((PRODUCER.BuildError, OSError, RuntimeError)):
                    PRODUCER.regularize_tree(source, self.root / (source.name + "-regular"))

    def test_special_release_files_are_rejected(self):
        source = self.root / "otp"
        source.mkdir()
        os.mkfifo(source / "pipe")
        with self.assertRaises(PRODUCER.BuildError):
            PRODUCER.regularize_tree(source, self.root / "regular")

    def test_wrong_native_cpu_and_fat_macos_inputs_are_rejected(self):
        native = self.root / "native"
        native.mkdir()
        elf = bytearray(64)
        elf[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", elf, 18, 62)
        path = native / "beam.smp"
        path.write_bytes(elf)
        with self.assertRaises(PRODUCER.BuildError):
            PRODUCER.native_files(native, "linux", "aarch64")
        path.write_bytes(b"\xcf\xfa\xed\xfe" + struct.pack("<I", 0x1000007) + bytes(24))
        with self.assertRaises(PRODUCER.BuildError):
            PRODUCER.native_files(native, "macos", "aarch64")
        path.write_bytes(b"\xca\xfe\xba\xbe" + bytes(24))
        with self.assertRaises(PRODUCER.BuildError):
            PRODUCER.native_files(native, "macos", "aarch64")

    def test_missing_runtime_and_interface_inputs_are_rejected(self):
        with self.assertRaises(PRODUCER.BuildError):
            PRODUCER.require_layout(self.root, MANIFEST)
        erts = "erts-" + MANIFEST["otp"]["erts_version"]
        for directory in (erts, "releases", "lib", "misc", "usr"):
            (self.root / directory).mkdir()
        files = ("Install", "bin/erl", erts + "/bin/erl", erts + "/bin/beam.smp", erts + "/bin/erlexec",
                 erts + "/include/erl_nif.h", "usr/include/erl_nif.h",
                 "usr/include/erl_driver.h", "usr/lib/libei.a", "lib/crypto-1/priv/lib/crypto.so")
        for name in files:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"layout-only fixture, not a native runtime")
            path.chmod(0o755)
        for missing in ("usr/include/erl_nif.h", "usr/lib/libei.a", erts + "/bin/erl", "bin/erl"):
            with self.subTest(missing=missing):
                path = self.root / missing
                contents = path.read_bytes()
                mode = path.stat().st_mode & 0o777
                path.unlink()
                with self.assertRaises(PRODUCER.BuildError):
                    PRODUCER.require_layout(self.root, MANIFEST)
                path.write_bytes(contents)
                path.chmod(mode)
        launcher = self.root / erts / "bin/erl"
        launcher.chmod(0o644)
        with self.assertRaises(PRODUCER.BuildError):
            PRODUCER.require_layout(self.root, MANIFEST)

    def test_cli_wrong_target_invalidates_stale_success_before_build(self):
        (self.output / "receipt.json").write_text('{"kind":"local-source-build"}')
        (self.output / "erts.tar.gz").write_bytes(b"stale")
        wrong_arch = "aarch64" if HOST_ARCH == "x86_64" else "x86_64"
        result = subprocess.run([sys.executable, str(SCRIPT), "--os", HOST_OS, "--arch", wrong_arch,
                                 "--output", str(self.output)], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native target mismatch", result.stderr)
        self.assertFalse((self.output / "receipt.json").exists())
        self.assertFalse((self.output / "erts.tar.gz").exists())

    def test_cli_invalid_target_also_invalidates_stale_success(self):
        (self.output / "receipt.json").write_text("stale success")
        result = subprocess.run([sys.executable, str(SCRIPT), "--os", HOST_OS, "--arch", "invalid",
                                 "--output", str(self.output)], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported native target", result.stderr)
        self.assertFalse((self.output / "receipt.json").exists())

    def test_missing_build_command_cannot_reuse_stale_receipt(self):
        runner = self.command_runner()
        def missing(*args):
            runner.run([str(self.root / "missing-compiler")])
        self.fail_build(missing)

    def test_failed_build_cannot_reuse_stale_receipt(self):
        runner = self.command_runner()
        script = self.root / "compiler.py"
        script.write_text("import sys\nsys.stderr.write('earlier compiler output\\n' * 2000)\nsys.stderr.write('native compiler fixture rejected input\\n')\nsys.exit(23)\n")
        def failed(*args):
            runner.run([sys.executable, script])
        error = self.fail_build(failed)
        self.assertIn("native compiler fixture rejected input", error)
        self.assertLess(len(error.encode("utf-8")), 10 * 1024)

    def test_timeout_reaps_owned_process_and_removes_stale_receipt(self):
        runner = self.command_runner(seconds=5)
        pid_file = self.root / "pid"
        def timed_out(*args):
            terminated = str(self.root / "terminated")
            code = (
                "import os,pathlib,signal,sys,time\n"
                "def stop(signum, frame):\n"
                " pathlib.Path(%r).write_text('terminated')\n"
                " sys.exit(0)\n"
                "signal.signal(signal.SIGTERM, stop)\n"
                "pathlib.Path(%r).write_text(str(os.getpid()))\n"
                "time.sleep(60)\n"
            ) % (terminated, str(pid_file))
            runner.run([sys.executable, "-c", code], seconds=1)
        self.fail_build(timed_out)
        pid = int(pid_file.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assertEqual((self.root / "terminated").read_text(), "terminated")

    def test_contending_producer_does_not_invalidate_current_owner(self):
        (self.output / ".producer.lock").write_text("owned")
        (self.output / "receipt.json").write_text("current owner")
        with self.assertRaises(PRODUCER.BuildError):
            PRODUCER.produce(HOST_OS, HOST_ARCH, self.output)
        self.assertEqual((self.output / "receipt.json").read_text(), "current owner")

    def test_unavailable_pinned_xcode_never_emits_a_receipt(self):
        manifest = json.loads(json.dumps(MANIFEST))
        manifest["macos_build_environment"]["developer_dir"] = str(self.root / "unavailable-Xcode")
        work = self.root / "native-build"
        work.mkdir()
        with self.assertRaises(PRODUCER.BuildError):
            PRODUCER.native_build(self.output, manifest, "macos", HOST_ARCH, work)
        self.assertFalse((self.output / "receipt.json").exists())


if __name__ == "__main__":
    unittest.main()
