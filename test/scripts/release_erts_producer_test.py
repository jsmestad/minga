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
                PRODUCER.produce(HOST_OS, HOST_ARCH, self.output)
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

    def test_linux_producer_rejects_nonbaseline_distro_before_source_acquisition(self):
        for release in ({"ID": "alpine", "VERSION_ID": "24.04"}, {"ID": "ubuntu", "VERSION_ID": "22.04"}):
            with self.subTest(release=release):
                work = Path(tempfile.mkdtemp(dir=self.root))
                with (mock.patch.object(PRODUCER.platform, "freedesktop_os_release", return_value=release),
                      mock.patch.object(PRODUCER, "source_build") as build):
                    with self.assertRaisesRegex(PRODUCER.BuildError, "requires native Ubuntu 24.04"):
                        PRODUCER.native_build(self.output, MANIFEST, "linux", "aarch64", work)
                build.assert_not_called()
                self.assertFalse((self.output / "receipt.json").exists())

    def test_linux_producer_rejects_nonbaseline_glibc_before_source_acquisition(self):
        work = Path(tempfile.mkdtemp(dir=self.root))
        release = {"ID": "ubuntu", "VERSION_ID": "24.04"}
        with (mock.patch.object(PRODUCER.platform, "freedesktop_os_release", return_value=release),
              mock.patch.object(PRODUCER.Commands, "run", return_value="glibc 2.35") as run,
              mock.patch.object(PRODUCER, "source_build") as build):
            with self.assertRaisesRegex(PRODUCER.BuildError, "wrong Linux glibc baseline"):
                PRODUCER.native_build(self.output, MANIFEST, "linux", "aarch64", work)
        run.assert_called_once_with(["getconf", "GNU_LIBC_VERSION"], seconds=30)
        build.assert_not_called()
        self.assertFalse((self.output / "receipt.json").exists())

    def test_linux_closure_uses_each_host_loader_without_rewriting_executables(self):
        baseline = MANIFEST["linux_build_environment"]
        beam = self.root / "erts/bin/beam.smp"
        for arch, interpreter in baseline["interpreters"].items():
            with self.subTest(arch=arch):
                elf = (f"[Requesting program interpreter: {interpreter}]\n"
                       " (NEEDED) Shared library: [libc.so.6]\n")
                # Ubuntu 24.04's ARM64 loader prints an unnamed map first.
                trace = ("\t (0x0000ff6bf86a0000)\n"
                         "linux-vdso.so.1 (0x7000)\n"
                         f"libc.so.6 => /lib/{arch}-linux-gnu/libc.so.6 (0x8000)\n"
                         f"{interpreter} (0x9000)\n")
                commands = mock.Mock()
                commands.run.side_effect = [elf, trace]

                def realpath(path, *, strict):
                    self.assertTrue(strict)
                    return Path("/usr/lib", arch + "-linux-gnu", path.name)

                with mock.patch.object(Path, "resolve", autospec=True, side_effect=realpath):
                    inventory = PRODUCER.linux_closure(commands, self.root, [beam], baseline, arch)
                self.assertEqual(inventory, [{"file": "erts/bin/beam.smp", "libraries": ["libc.so.6"]}])
                self.assertEqual(commands.run.call_args_list, [
                    mock.call(["readelf", "-W", "-l", "-d", beam], seconds=30),
                    mock.call([interpreter, "--inhibit-cache", "--list", beam], seconds=30),
                ])

    def test_linux_closure_rejects_unqualified_interpreters_and_direct_libraries(self):
        baseline = MANIFEST["linux_build_environment"]
        interpreter = baseline["interpreters"]["x86_64"]
        interp = f"[Requesting program interpreter: {interpreter}]\n"
        libc = " (NEEDED) Shared library: [libc.so.6]\n"
        beam = self.root / "beam.smp"
        for elf, error in (
            (libc, "glibc system loader"),
            (interp.replace(interpreter, "/tmp/custom-loader.so") + libc, "glibc system loader"),
            (interp, "lacks a glibc dependency"),
            (interp + libc + " (NEEDED) Shared library: [libcrypto.so.3]\n", "unqualified ELF dependency"),
            (interp + libc + " (NEEDED) Shared library: [libssl.so.3]\n", "unqualified ELF dependency"),
            (interp + libc + " (RUNPATH) Library runpath: [/usr/local/lib]\n", "library search path"),
            (interp + libc + " (RPATH) Library rpath: [/usr/local/lib]\n", "library search path"),
        ):
            with self.subTest(elf=elf):
                commands = mock.Mock()
                commands.run.return_value = elf
                with self.assertRaisesRegex(PRODUCER.BuildError, error):
                    PRODUCER.linux_closure(commands, self.root, [beam], baseline, "x86_64")
                commands.run.assert_called_once()

    def test_linux_closure_checks_transitive_loader_results_for_shared_objects(self):
        baseline = MANIFEST["linux_build_environment"]
        nif = self.root / "crypto.so"
        elf = " (NEEDED) Shared library: [libc.so.6]\n"
        libc = "libc.so.6 => /usr/lib/x86_64-linux-gnu/libc.so.6 (0x1000)\n"
        for trace, error in (
            ("libc.so.6 => not found\n", "resolved an unqualified library"),
            ("libc.so.6 => /opt/toolchain/libc.so.6 (0x1000)\n", "resolved an unqualified library"),
            (libc + "libcrypto.so.3 => /usr/lib/x86_64-linux-gnu/libcrypto.so.3 (0x2000)\n",
             "resolved an unqualified library"),
            ("linux-vdso.so.1 (0x3000)\n", "did not resolve all direct libraries"),
            ("\t (0x3000)\n", "did not resolve all direct libraries"),
            (libc + "\t => /opt/toolchain/libextra.so (0x2000)\n", "resolved an unqualified library"),
        ):
            with self.subTest(trace=trace):
                commands = mock.Mock()
                commands.run.side_effect = [elf, trace]
                with mock.patch.object(Path, "resolve", autospec=True, side_effect=lambda path, **_: path):
                    with self.assertRaisesRegex(PRODUCER.BuildError, error):
                        PRODUCER.linux_closure(commands, self.root, [nif], baseline, "x86_64")

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
