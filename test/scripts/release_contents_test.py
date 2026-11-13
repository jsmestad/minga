#!/usr/bin/env python3
"""Behavioral checks of the real packaged-resource/architecture consumer CLI."""

import json
from pathlib import Path
import platform
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/check-release-contents"


def header(target):
    os_name, arch = target.split("_", 1)
    if os_name == "linux":
        data = bytearray(64)
        data[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", data, 18, {"x86_64": 62, "aarch64": 183}[arch])
        return data
    return b"\xcf\xfa\xed\xfe" + struct.pack("<I", {"x86_64": 0x01000007, "aarch64": 0x0100000C}[arch]) + bytes(24)


def fat_header(targets, endian=">", wide=False):
    """Build a small universal fixture with real thin slice headers."""
    record_format = endian + ("IIQQII" if wide else "IIIII")
    record_size = struct.calcsize(record_format)
    magic = 0xCAFEBABF if wide else 0xCAFEBABE
    result = bytearray(struct.pack(endian + "II", magic, len(targets)))
    offset = 8 + record_size * len(targets)
    slices = []
    for target in targets:
        contents = header(target)
        cpu, subtype = struct.unpack("<II", contents[4:12])
        fields = (cpu, subtype, offset, len(contents), 2)
        if wide:
            fields += (0,)
        result.extend(struct.pack(record_format, *fields))
        slices.append(contents)
        offset += len(contents)
    return result + b"".join(slices)


class ReleaseContentsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.release = self.root / "release"
        self.priv = self.release / "lib/minga-0.1.0/priv"
        self.target = "linux_x86_64"
        self.fixture(self.target)

    def put(self, path, content=b"fixture\n", executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        if executable:
            path.chmod(0o755)
        return path

    def fixture(self, target):
        self.put(self.release / "lib/exqlite-0.27/priv/sqlite3_nif.so", header(target))
        self.put(self.release / "erts-17.1.2/bin/beam.smp", header(target), True)
        self.put(self.release / "bin/minga", b"#!/bin/sh\n", True)
        self.put(self.release / "releases/start_erl.data", b"17.1.2 0.1.0\n")
        self.put(self.release / "releases/0.1.0/start.boot")
        for name in ("minga-renderer-go", "minga-parser", "minga-hook-runner"):
            self.put(self.priv / name, header(target), True)
        for name in ("tutor.txt", "tree_sitter/api.h", "tree_sitter/parser.h", "queries/elixir/highlights.scm"):
            self.put(self.priv / name)
        for name in ("git_porcelain", "knowledge_graph", "adversarial"):
            self.put(self.priv / "extensions" / name / "lib/extension.ex")

    def run_checker(self, *args, success=True):
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.release), "--target", self.target, *map(str, args)], capture_output=True, text=True, timeout=10)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def test_accepts_all_four_actual_native_header_targets(self):
        for target in ("linux_x86_64", "linux_aarch64", "macos_x86_64", "macos_aarch64"):
            with self.subTest(target=target):
                self.fixture(target)
                self.target = target
                self.run_checker()

    def test_universal_erts_and_otp_nif_accept_both_selected_macos_cpus(self):
        for endian in (">", "<"):
            for wide in (False, True):
                universal = fat_header(("macos_x86_64", "macos_aarch64"), endian, wide)
                for target in ("macos_x86_64", "macos_aarch64"):
                    with self.subTest(endian=endian, wide=wide, target=target):
                        self.fixture(target)
                        self.target = target
                        self.put(self.release / "erts-17.1.2/bin/beam.smp", universal, True)
                        self.put(self.release / "lib/crypto-5.8/priv/lib/crypto.so", universal)
                        self.put(self.release / "lib/exqlite-0.27/priv/sqlite3_nif.so", universal)
                        self.run_checker()

    def test_universal_membership_applies_to_helpers_and_outer_binary(self):
        self.target = "macos_aarch64"
        self.fixture(self.target)
        universal = fat_header(("macos_x86_64", "macos_aarch64"))
        for name in ("minga-renderer-go", "minga-parser", "minga-hook-runner"):
            self.put(self.priv / name, universal, True)
        binary = self.put(self.root / "standalone", universal, True)
        self.run_checker("--binary", binary)

    def test_big_endian_actual_macho_slice_headers_are_verified(self):
        self.target = "macos_aarch64"
        self.fixture(self.target)
        path = self.release / "erts-17.1.2/bin/beam.smp"
        thin = header(self.target)
        big_endian = struct.pack(">8I", *struct.unpack("<8I", thin))
        self.put(path, big_endian, True)
        self.run_checker()
        for endian in (">", "<"):
            for wide in (False, True):
                universal = fat_header((self.target,), endian, wide)
                universal[-32:] = big_endian
                self.put(path, universal, True)
                self.run_checker()

    def test_macos_opposite_cpu_required_components_and_nif_fail(self):
        self.target = "macos_aarch64"
        self.fixture(self.target)
        paths = [self.release / "erts-17.1.2/bin/beam.smp",
                 self.priv / "minga-renderer-go", self.priv / "minga-parser",
                 self.priv / "minga-hook-runner",
                 self.release / "lib/crypto-5.8/priv/lib/crypto.so"]
        for path in paths:
            for contents in (header("macos_x86_64"), fat_header(("macos_x86_64",))):
                with self.subTest(path=path, universal=len(contents) > 32):
                    self.put(path, contents, True)
                    self.run_checker(success=False)
            self.put(path, header(self.target), True)

    def test_universal_membership_requires_matching_actual_slice_cpu_and_subtype(self):
        self.target = "macos_aarch64"
        self.fixture(self.target)
        for endian in (">", "<"):
            for wide in (False, True):
                for field, replacement in ((8, 0x0100000C), (12, 1)):
                    with self.subTest(endian=endian, wide=wide, field=field):
                        forged = fat_header(("macos_x86_64",), endian, wide)
                        struct.pack_into(endian + "I", forged, field, replacement)
                        self.put(self.release / "erts-17.1.2/bin/beam.smp", forged, True)
                        result = self.run_checker(success=False)
                        self.assertIn("slice CPU declaration", result.stderr)

    def test_universal_tables_and_slices_are_strictly_bounded(self):
        self.target = "macos_aarch64"
        self.fixture(self.target)
        for endian in (">", "<"):
            for wide in (False, True):
                valid = fat_header(("macos_x86_64", "macos_aarch64"), endian, wide)
                record_size = 32 if wide else 20
                offset_format = endian + ("Q" if wide else "I")
                variants = {}
                variants["truncated-header"] = valid[:4]
                variants["duplicate-architecture"] = fat_header((self.target, self.target), endian, wide)
                variants["truncated-table"] = valid[:8 + record_size + 1]
                variants["truncated-slice"] = valid[:-1]
                for name, position, value, fmt in (
                    ("empty-count", 4, 0, endian + "I"),
                    ("excess-count", 4, 0xFFFFFFFF, endian + "I"),
                    ("slice-over-table", 16, 8, offset_format),
                    ("slice-past-file", 16, len(valid) + 4, offset_format),
                    ("size-past-file", 24 if wide else 20, len(valid), offset_format),
                    ("short-slice", 24 if wide else 20, 31, offset_format),
                    ("invalid-alignment", 32 if wide else 24, 64, endian + "I"),
                    ("unsupported-cpu", 8, 7, endian + "I"),
                ):
                    malformed = valid.copy()
                    struct.pack_into(fmt, malformed, position, value)
                    variants[name] = malformed
                overlap = valid.copy()
                struct.pack_into(offset_format, overlap, 8 + record_size + 8, 8 + 2 * record_size)
                variants["overlapping-slices"] = overlap
                misaligned = valid.copy()
                struct.pack_into(endian + "I", misaligned, 32 if wide else 24, 5)
                variants["misaligned-slice"] = misaligned
                if wide:
                    reserved = valid.copy()
                    struct.pack_into(endian + "I", reserved, 36, 1)
                    variants["nonzero-reserved"] = reserved
                load_commands = valid.copy()
                struct.pack_into("<II", load_commands, 8 + 2 * record_size + 16, 1, 32)
                variants["load-commands-past-slice"] = load_commands
                # Even an unselected slice must be a valid 64-bit Mach-O.
                for name, magic in (("elf-slice", b"\x7fELF"),
                                    ("nested-fat-slice", b"\xca\xfe\xba\xbe"),
                                    ("32-bit-slice", b"\xce\xfa\xed\xfe")):
                    malformed = valid.copy()
                    start = 8 + 2 * record_size
                    malformed[start:start + 4] = magic
                    variants[name] = malformed
                for name, contents in variants.items():
                    with self.subTest(endian=endian, wide=wide, malformed=name):
                        self.put(self.release / "erts-17.1.2/bin/beam.smp", contents, True)
                        self.run_checker(success=False)

    def test_missing_required_resources_and_executables_fail(self):
        paths = [self.priv / "minga-parser", self.priv / "minga-renderer-go", self.priv / "minga-hook-runner", self.priv / "tutor.txt", self.priv / "tree_sitter/api.h", self.priv / "queries/elixir/highlights.scm", self.priv / "extensions/git_porcelain/lib/extension.ex", self.release / "releases/0.1.0/start.boot", self.release / "bin/minga"]
        for path in paths:
            with self.subTest(path=path):
                contents = path.read_bytes()
                mode = path.stat().st_mode
                path.unlink()
                self.run_checker(success=False)
                self.put(path, contents)
                path.chmod(mode)

    def test_wrong_native_component_is_not_proved_by_filename(self):
        for path in (self.release / "erts-17.1.2/bin/beam.smp", self.priv / "minga-renderer-go", self.priv / "minga-parser", self.priv / "minga-hook-runner"):
            with self.subTest(path=path):
                self.put(path, header("linux_aarch64"), True)
                self.run_checker(success=False)
                self.put(path, header(self.target), True)

    def test_wrong_os_and_non_native_executable_fail(self):
        path = self.priv / "minga-parser"
        for contents in (header("macos_x86_64"), b"#!/bin/sh\nexit 0\n", b"\x7fELF"):
            with self.subTest(contents=contents):
                self.put(path, contents, True)
                self.run_checker(success=False)

    def test_missing_sqlite_nif_fails(self):
        (self.release / "lib/exqlite-0.27/priv/sqlite3_nif.so").unlink()
        self.run_checker(success=False)

    def test_all_other_native_libraries_are_checked(self):
        path = self.put(self.release / "lib/exqlite-0.27/priv/sqlite3_nif.so", header("linux_aarch64"))
        self.run_checker(success=False)
        self.put(path, b"not a native library")
        self.run_checker(success=False)
        self.put(path, header(self.target))
        self.run_checker()

    def test_duplicate_erts_or_application_version_fails(self):
        path = self.put(self.release / "erts-17.0/bin/beam.smp", header(self.target), True)
        self.run_checker(success=False)
        path.unlink()
        path.parent.rmdir()
        path.parent.parent.rmdir()
        self.put(self.release / "lib/minga-0.0.9/priv/tutor.txt")
        self.run_checker(success=False)

    def test_leaked_scripts_and_escaping_symlinks_fail(self):
        scripts = self.release / "scripts"
        scripts.mkdir()
        self.run_checker(success=False)
        scripts.rmdir()
        (self.release / "external").symlink_to(self.root / "outside")
        self.run_checker(success=False)

    def test_wrapper_actual_header_is_required(self):
        binary = self.put(self.root / "minga_linux_x86_64", header("linux_aarch64"), True)
        self.run_checker("--binary", binary, success=False)
        self.put(binary, header(self.target), True)
        self.run_checker("--binary", binary)

    def app_fixture(self):
        self.target = "macos_aarch64"
        app = self.root / "Minga.app"
        destination = app / "Contents/Resources/release"
        destination.parent.mkdir(parents=True)
        self.release.rename(destination)
        self.release = destination
        self.priv = destination / "lib/minga-0.1.0/priv"
        self.fixture(self.target)
        self.put(destination / "bin/minga_macos", b"#!/bin/sh\n", True)
        self.put(app / "Contents/Info.plist", plistlib.dumps({"CFBundleShortVersionString": "0.1.0", "CFBundleExecutable": "Minga", "LSMinimumSystemVersion": "15.0"}))
        for name in ("Resources/default.metallib", "Resources/Assets.car", "Resources/Fonts/font.ttf"):
            self.put(app / "Contents" / name)
        for name in ("minga", "minga-tui"):
            self.put(app / "Contents/Resources/bin" / name, b"#!/bin/sh\n", True)
        for name in ("MacOS/Minga", "Resources/bin/minga-ipc"):
            self.put(app / "Contents" / name, header(self.target), True)
        return app

    def test_gui_accepts_universal_erts_and_otp_nif_for_selected_arm_cpu(self):
        app = self.app_fixture()
        universal = fat_header(("macos_x86_64", "macos_aarch64"))
        self.put(self.release / "erts-17.1.2/bin/beam.smp", universal, True)
        self.put(self.release / "lib/crypto-5.8/priv/lib/crypto.so", universal)
        self.run_checker("--app", app)

    def test_gui_resources_and_ipc_target_are_required(self):
        app = self.app_fixture()
        self.run_checker("--app", app)
        helper = app / "Contents/Resources/bin/minga-ipc"
        self.put(helper, header("macos_x86_64"), True)
        self.run_checker("--app", app, success=False)
        self.put(helper, header(self.target), True)
        (app / "Contents/Resources/default.metallib").unlink()
        self.run_checker("--app", app, success=False)

    def test_gui_version_must_match_embedded_release(self):
        app = self.app_fixture()
        self.put(app / "Contents/Info.plist", plistlib.dumps({"CFBundleShortVersionString": "0.0.9", "CFBundleExecutable": "Minga", "LSMinimumSystemVersion": "15.0"}))
        self.run_checker("--app", app, success=False)

    def test_gui_minimum_os_cannot_drop_supported_macos_15_0(self):
        app = self.app_fixture()
        info_path = app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        for minimum in ("14.0", "15.1", "16.0", "unknown"):
            with self.subTest(minimum=minimum):
                info["LSMinimumSystemVersion"] = minimum
                self.put(info_path, plistlib.dumps(info))
                self.run_checker("--app", app, success=False)


    def runtime_receipt(self):
        os_name, arch = self.target.split("_", 1)
        helper = {"x86_64": "71c35316aff45bbfd243d8eb9bfc4a58b6eb97cee09514cd2030e145b68107fb",
                  "aarch64": "6b558025200a5ed1308e2ce2675217afec71b6c5a9d561e52262ca948d59905e"}[arch]
        receipt = {"version": 1, "kind": "local-source-build", "os": os_name, "arch": arch,
                   "otp_version": "29.1.2", "erts_version": "17.1.1",
                   "minimum_macos": "15.0" if os_name == "macos" else None,
                   "musl_version": "1.2.5" if os_name == "linux" else None,
                   "abi": {"interpreter": f"/tmp/libc-musl-{helper}.so", "musl_sha256": helper}}
        path = self.root / "runtime-receipt.json"
        path.write_text(json.dumps(receipt))
        return path

    def native_fixture(self, minimum="15.0"):
        os_name = {"Darwin": "macos", "Linux": "linux"}[platform.system()]
        arch = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64"}[platform.machine()]
        self.target = f"{os_name}_{arch}"
        self.fixture(self.target)
        (self.release / "erts-17.1.2").rename(self.release / "erts-17.1.1")
        self.put(self.release / "releases/start_erl.data", b"17.1.1 0.1.0\n")
        source = self.put(self.root / "native.c", b'#include <stdio.h>\nint main(void) { puts("native ABI fixture"); return 0; }\n')
        binary = self.root / "native"
        command = ["cc", str(source), "-o", str(binary)]
        if os_name == "macos":
            command.append(f"-mmacosx-version-min={minimum}")
        compiled = subprocess.run(command, capture_output=True, text=True, timeout=20)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        for path in [self.release / "erts-17.1.1/bin/beam.smp",
                     self.release / "lib/exqlite-0.27/priv/sqlite3_nif.so",
                     *(self.priv / name for name in ("minga-renderer-go", "minga-parser", "minga-hook-runner"))]:
            shutil.copy2(binary, path)

    @unittest.skipUnless(platform.system() == "Darwin", "Native Mach-O dependency checks require macOS")
    def test_relative_native_dependency_is_relocatable(self):
        self.native_fixture()
        library_dir = self.release / "lib/exqlite-0.27/priv"
        source = self.put(self.root / "library.c", b"int provided(void) { return 42; }\n")
        library = library_dir / "libprovided.dylib"
        built = subprocess.run(["cc", "-dynamiclib", "-mmacosx-version-min=15.0", str(source),
                                "-Wl,-install_name,@loader_path/libprovided.dylib", "-o", str(library)],
                               capture_output=True, text=True, timeout=20)
        self.assertEqual(built.returncode, 0, built.stderr)
        consumer = self.put(self.root / "consumer.c", b"extern int provided(void); int consume(void) { return provided(); }\n")
        linked = subprocess.run(["cc", "-dynamiclib", "-mmacosx-version-min=15.0", str(consumer), str(library),
                                 "-o", str(library_dir / "sqlite3_nif.so")], capture_output=True, text=True, timeout=20)
        self.assertEqual(linked.returncode, 0, linked.stderr)
        self.run_checker("--runtime-receipt", self.runtime_receipt())
        library.unlink()
        self.run_checker("--runtime-receipt", self.runtime_receipt(), success=False)

    @unittest.skipUnless(platform.system() == "Darwin", "Native Mach-O deployment checks require macOS")
    def test_runtime_cannot_drop_macos_15_support(self):
        self.native_fixture(minimum="16.0")
        self.run_checker("--runtime-receipt", self.runtime_receipt(), success=False)

    @unittest.skipUnless(platform.system() == "Darwin", "Native Mach-O dependency checks require macOS")
    def test_absolute_build_path_dependency_is_not_relocatable_even_inside_package(self):
        self.native_fixture()
        library_dir = self.release / "lib/exqlite-0.27/priv"
        source = self.put(self.root / "library.c", b"int provided(void) { return 42; }\n")
        library = library_dir / "libprovided.dylib"
        built = subprocess.run(["cc", "-dynamiclib", "-mmacosx-version-min=15.0", str(source),
                                f"-Wl,-install_name,{library}", "-o", str(library)],
                               capture_output=True, text=True, timeout=20)
        self.assertEqual(built.returncode, 0, built.stderr)
        consumer = self.put(self.root / "consumer.c", b"extern int provided(void); int consume(void) { return provided(); }\n")
        linked = subprocess.run(["cc", "-dynamiclib", "-mmacosx-version-min=15.0", str(consumer), str(library),
                                 "-o", str(library_dir / "sqlite3_nif.so")], capture_output=True, text=True, timeout=20)
        self.assertEqual(linked.returncode, 0, linked.stderr)
        self.run_checker("--runtime-receipt", self.runtime_receipt(), success=False)

    @unittest.skipUnless(platform.system() == "Linux", "Native ELF dependency checks require Linux")
    def test_glibc_runtime_cannot_claim_musl_closure(self):
        self.native_fixture()
        self.run_checker("--runtime-receipt", self.runtime_receipt(), success=False)

    def test_malformed_source_receipt_is_an_explicit_failure(self):
        path = self.put(self.root / "invalid-receipt.json", b"[]\n")
        self.run_checker("--runtime-receipt", path, success=False)


if __name__ == "__main__":
    unittest.main()
