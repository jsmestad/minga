#!/usr/bin/env python3
"""Exercise the real Debian builder; the synthetic payload does not boot ERTS."""

import io
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

from release_contents_test import header


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts/build-tui-deb"
LAUNCHER = REPO / "macos/Resources/bin/minga-tui"
TARGETS = {"amd64": "linux_x86_64", "arm64": "linux_aarch64"}


class BuildTuiDebTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="minga deb test ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.release = self.root / "minga"
        self.archive = self.root / "payload.tar.gz"
        self.output = self.root / "output packages"

    def put(self, name, content=b"fixture\n", mode=0o644):
        path = self.release / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        path.chmod(mode)

    def make_fixture(self, arch):
        native = header(TARGETS[arch])
        self.put("erts-17.1.1/bin/beam.smp", native, mode=0o755)
        self.put("lib/exqlite-0.27/priv/sqlite3_nif.so", native)
        self.put("launchers/minga", LAUNCHER.read_bytes(), mode=0o755)
        self.put("bin/minga", b"#!/bin/sh\nprintf 'fixture release received %s\\n' \"$1\"\n", mode=0o755)
        self.put("releases/start_erl.data", b"17.1.1 0.1.0\n")
        self.put("releases/0.1.0/start.boot")
        priv = "lib/minga-0.1.0/priv/"
        for name in ("minga-renderer-go", "minga-parser", "minga-hook-runner", "minga-shell-output-reader"):
            self.put(priv + name, native, mode=0o755)
        for name in ("tutor.txt", "tree_sitter/api.h", "tree_sitter/parser.h", "queries/elixir/highlights.scm"):
            self.put(priv + name)

    def pack(self, *extra):
        with tarfile.open(self.archive, "w:gz") as archive:
            archive.add(self.release, arcname="minga")
            for member in extra:
                archive.addfile(member, io.BytesIO(b""))

    def build(self, arch="amd64", version="0.1.0", failure=None):
        result = subprocess.run(
            [sys.executable, SCRIPT, self.archive, "--version", version,
             "--arch", arch, "--output", self.output],
            capture_output=True, text=True, timeout=30, umask=0o077,
        )
        if failure:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(failure, result.stderr)
            self.assertFalse(self.output.exists())
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
            artifact = self.output / f"minga_{version}_{arch}.deb"
            self.assertTrue(artifact.is_file())
            return artifact

    @unittest.skipUnless(shutil.which("dpkg-deb"), "dpkg-deb is required for package inspection")
    def test_builds_both_debian_architectures_and_runs_the_real_public_launcher(self):
        for arch in TARGETS:
            with self.subTest(arch=arch):
                self.make_fixture(arch)
                self.pack()
                artifact = self.build(arch=arch)
                want = {
                    "Package": "minga", "Version": "0.1.0", "Architecture": arch,
                    "Depends": "libc6 (>= 2.39)",
                }
                for field, value in want.items():
                    actual = subprocess.check_output(["dpkg-deb", "--field", artifact, field], text=True)
                    self.assertEqual(actual.rstrip("\n"), value)
                listing = subprocess.check_output(["dpkg-deb", "--contents", artifact], text=True)
                self.assertTrue(all(line.split()[1] == "root/root" for line in listing.splitlines()))
                installed = self.root / f"extracted-{arch}"
                subprocess.run(["dpkg-deb", "--extract", artifact, installed], check=True)
                launcher = installed / "usr/bin/minga"
                private = installed / "usr/lib/minga"
                self.assertEqual(launcher.readlink(), Path("../lib/minga/launchers/minga"))
                self.assertEqual(launcher.resolve(), private / "launchers/minga")
                self.assertEqual(launcher.stat().st_mode & 0o777, 0o755)
                self.assertEqual(launcher.read_bytes(), LAUNCHER.read_bytes())
                self.assertEqual((private / "erts-17.1.1/bin/beam.smp").read_bytes(), header(TARGETS[arch]))
                result = subprocess.check_output([launcher, "--version"], cwd=self.root, text=True)
                self.assertEqual(result, "fixture release received start\n")

    def test_rejects_wrong_version_architecture_and_damaged_release(self):
        self.make_fixture("amd64")
        self.pack()
        self.build(version="0.2.0", failure="does not match --version")
        self.build(arch="arm64", failure="Required executable does not contain linux_aarch64")
        self.build(version="../0.1.0", failure="Debian-compatible")
        (self.release / "launchers/minga").chmod(0o644)
        self.pack()
        self.build(failure="Packaged executable is not executable")

    def test_rejects_unsafe_archive_paths_and_member_types(self):
        self.make_fixture("amd64")
        outside = self.root / "outside-stage"
        link = tarfile.TarInfo("minga/symlink")
        link.type, link.linkname = tarfile.SYMTYPE, str(outside)
        hardlink = tarfile.TarInfo("minga/hardlink")
        hardlink.type, hardlink.linkname = tarfile.LNKTYPE, "minga/launchers/minga"
        fifo = tarfile.TarInfo("minga/fifo")
        fifo.type = tarfile.FIFOTYPE
        setuid = tarfile.TarInfo("minga/setuid")
        setuid.mode = 0o4755
        for member, diagnostic in (
            (tarfile.TarInfo(str(outside)), "Unsafe archive path"),
            (tarfile.TarInfo("minga/../outside-stage"), "Unsafe archive path"),
            (tarfile.TarInfo("extra-root/file"), "Unsafe archive path"),
            (tarfile.TarInfo("minga/bin/minga"), "Duplicate archive path"),
            (link, "special files"), (hardlink, "special files"),
            (fifo, "special files"), (setuid, "privileged modes"),
        ):
            with self.subTest(member=member.name):
                self.pack(member)
                self.build(failure=diagnostic)
                self.assertFalse(outside.exists())

    def test_rejects_corrupt_gzip_trailer(self):
        self.make_fixture("amd64")
        self.pack()
        archive = bytearray(self.archive.read_bytes())
        archive[-8] ^= 1  # The gzip trailer starts with the CRC32.
        self.archive.write_bytes(archive)
        self.build(failure="CRC check failed")


if __name__ == "__main__":
    unittest.main()
