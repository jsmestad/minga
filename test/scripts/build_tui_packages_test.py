#!/usr/bin/env python3
"""Exercise the real Debian and RPM builder; the synthetic payload does not boot ERTS."""

import io
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

from release_contents_test import header


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts/build-tui-packages"
LAUNCHER = REPO / "macos/Resources/bin/minga-tui"
# Release architecture -> (Debian architecture, RPM architecture, checker target).
TARGETS = {"x86_64": ("amd64", "x86_64", "linux_x86_64"), "aarch64": ("arm64", "aarch64", "linux_aarch64")}
TOOLS = shutil.which("dpkg-deb") and shutil.which("rpmbuild") and shutil.which("rpm")


class BuildTuiPackagesTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="minga package test ")
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

    def make_fixture(self, arch, version="0.1.0"):
        native = header(TARGETS[arch][2])
        self.put("erts-17.1.1/bin/beam.smp", native, mode=0o755)
        self.put("lib/exqlite-0.27/priv/sqlite3_nif.so", native)
        self.put("launchers/minga", LAUNCHER.read_bytes(), mode=0o755)
        self.put("bin/minga", b"#!/bin/sh\nprintf 'fixture release received %s\\n' \"$1\"\n", mode=0o755)
        self.put("releases/start_erl.data", f"17.1.1 {version}\n".encode())
        self.put(f"releases/{version}/start.boot")
        priv = f"lib/minga-{version}/priv/"
        for name in ("minga-renderer-go", "minga-parser", "minga-hook-runner", "minga-shell-output-reader", "minga-clone-tree", "minga-lsp-guard"):
            self.put(priv + name, native, mode=0o755)
        for name in ("tutor.txt", "tree_sitter/api.h", "tree_sitter/parser.h", "queries/elixir/highlights.scm"):
            self.put(priv + name)

    def pack(self, *extra):
        with tarfile.open(self.archive, "w:gz") as archive:
            archive.add(self.release, arcname="minga")
            for member in extra:
                archive.addfile(member, io.BytesIO(b""))

    def build(self, arch="x86_64", version="0.1.0", failure=None, output=None):
        output = output or self.output
        result = subprocess.run(
            [sys.executable, SCRIPT, self.archive, "--version", version,
             "--arch", arch, "--output", output],
            capture_output=True, text=True, timeout=120, umask=0o077,
        )
        if failure:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(failure, result.stderr)
            self.assertFalse(output.exists())
            return None
        self.assertEqual(result.returncode, 0, result.stderr)
        deb_arch, rpm_arch, _ = TARGETS[arch]
        artifacts = (output / f"minga_{version}_{deb_arch}.deb", output / f"minga-{version}.{rpm_arch}.rpm")
        self.assertEqual(result.stdout.splitlines(), [str(path) for path in artifacts])
        self.assertEqual(sorted(output.iterdir()), sorted(artifacts))
        return artifacts

    def assert_installed_tree(self, root, arch):
        launcher = root / "usr/bin/minga"
        private = root / "usr/lib/minga"
        self.assertEqual(launcher.readlink(), Path("../lib/minga/launchers/minga"))
        self.assertEqual(launcher.resolve(), private / "launchers/minga")
        self.assertEqual(launcher.stat().st_mode & 0o777, 0o755)
        self.assertEqual(launcher.read_bytes(), LAUNCHER.read_bytes())
        self.assertEqual((private / "erts-17.1.1/bin/beam.smp").read_bytes(), header(TARGETS[arch][2]))
        result = subprocess.check_output([launcher, "--version"], cwd=self.root, text=True)
        self.assertEqual(result, "fixture release received start\n")
        self.assertEqual((root / "usr/share/applications/minga.desktop").read_bytes(),
                         (REPO / "packaging/linux/minga.desktop").read_bytes())
        self.assertEqual((root / "usr/share/icons/hicolor/512x512/apps/minga.png").read_bytes(),
                         (REPO / "packaging/linux/minga.png").read_bytes())

    def rpm_query(self, artifact, query):
        return subprocess.check_output(["rpm", "-qp", "--nosignature", "--queryformat", query, artifact],
                                       text=True, stderr=subprocess.DEVNULL)

    @unittest.skipUnless(TOOLS, "dpkg-deb, rpmbuild and rpm are required for package inspection")
    def test_builds_both_architectures_and_runs_the_real_public_launcher(self):
        for arch, (deb_arch, rpm_arch, _) in TARGETS.items():
            with self.subTest(arch=arch):
                self.make_fixture(arch)
                self.pack()
                deb, rpm = self.build(arch=arch, output=self.root / f"packages-{arch}")
                want = {
                    "Package": "minga", "Version": "0.1.0", "Architecture": deb_arch,
                    "Depends": "libc6 (>= 2.39)",
                }
                for field, value in want.items():
                    actual = subprocess.check_output(["dpkg-deb", "--field", deb, field], text=True)
                    self.assertEqual(actual.rstrip("\n"), value)
                listing = subprocess.check_output(["dpkg-deb", "--contents", deb], text=True)
                self.assertTrue(all(line.split()[1] == "root/root" for line in listing.splitlines()))
                extracted = self.root / f"deb-{arch}"
                subprocess.run(["dpkg-deb", "--extract", deb, extracted], check=True)
                self.assert_installed_tree(extracted, arch)
                self.assertEqual((extracted / "usr/share/doc/minga/copyright").read_bytes(),
                                 (REPO / "LICENSE").read_bytes())

                self.assertEqual(self.rpm_query(rpm, "%{NAME} %{VERSION} %{RELEASE} %{ARCH}"),
                                 f"minga 0.1.0 1 {rpm_arch}")
                # rpmbuild always adds rpmlib() feature requirements; scanning is off, so nothing else.
                requires = self.rpm_query(rpm, "[%{REQUIRENAME} %{REQUIREVERSION}\n]").splitlines()
                self.assertEqual([line for line in requires if not line.startswith("rpmlib(")], ["glibc 2.39"])
                owners = set(self.rpm_query(rpm, "[%{FILEUSERNAME}:%{FILEGROUPNAME}\n]").split())
                self.assertEqual(owners, {"root:root"})
                extracted = self.root / f"rpm-{arch}"
                extracted.mkdir()
                payload = subprocess.run(["rpm2cpio", rpm], check=True, capture_output=True).stdout
                subprocess.run(["cpio", "-idm", "--quiet"], input=payload, cwd=extracted, check=True)
                self.assert_installed_tree(extracted, arch)
                self.assertEqual((extracted / "usr/share/licenses/minga/LICENSE").read_bytes(),
                                 (REPO / "LICENSE").read_bytes())

    @unittest.skipUnless(TOOLS, "dpkg-deb, rpmbuild and rpm are required for package inspection")
    def test_rolling_versions_sort_before_the_stable_release(self):
        self.make_fixture("x86_64", version="0.1.0-dev.7")
        self.pack()
        deb, rpm = self.build(version="0.1.0-dev.7")
        version = subprocess.check_output(["dpkg-deb", "--field", deb, "Version"], text=True).strip()
        self.assertEqual(version, "0.1.0~dev.7")
        self.assertEqual(self.rpm_query(rpm, "%{VERSION}-%{RELEASE}"), "0.1.0~dev.7-1")
        for older, newer in (("0.1.0~dev.7", "0.1.0~dev.12"), ("0.1.0~dev.12", "0.1.0")):
            with self.subTest(older=older, newer=newer):
                subprocess.run(["dpkg", "--compare-versions", older, "lt", newer], check=True)
                comparison = subprocess.check_output(
                    ["rpm", "--eval", f'%{{lua: print(rpm.vercmp("{older}-1", "{newer}-1"))}}'], text=True)
                self.assertEqual(comparison.strip(), "-1")

    @unittest.skipUnless(TOOLS, "dpkg-deb, rpmbuild and rpm are required for package inspection")
    def test_rebuilding_the_same_archive_reproduces_identical_packages(self):
        self.make_fixture("x86_64")
        self.pack()
        first = self.build(output=self.root / "first")
        # Start the rebuild in a later clock second, so any leaked build time changes the bytes.
        finished = int(time.time())
        while int(time.time()) == finished:
            time.sleep(0.05)
        second = self.build(output=self.root / "second")
        for one, two in zip(first, second):
            with self.subTest(package=one.name):
                self.assertEqual(one.read_bytes(), two.read_bytes())

    @unittest.skipUnless(shutil.which("desktop-file-validate"), "desktop-file-validate is required")
    def test_desktop_entry_is_valid_and_opens_minga_in_a_terminal(self):
        entry = REPO / "packaging/linux/minga.desktop"
        subprocess.run(["desktop-file-validate", entry], check=True)
        fields = dict(line.split("=", 1) for line in entry.read_text().splitlines() if "=" in line)
        self.assertEqual((fields["Exec"], fields["Icon"], fields["Terminal"]), ("minga %f", "minga", "true"))
        # Freedesktop MIME types for source code, scripts, JSON and Markdown are subclasses of text/plain.
        self.assertEqual(fields["MimeType"], "text/plain;")

    def test_rejects_wrong_version_architecture_and_damaged_release(self):
        self.make_fixture("x86_64")
        self.pack()
        self.build(version="0.2.0", failure="does not match --version")
        self.build(arch="aarch64", failure="Required executable does not contain linux_aarch64")
        self.build(version="../0.1.0", failure="Version must be X.Y.Z")
        self.build(version="0.1.0-rc.1", failure="Version must be X.Y.Z")
        (self.release / "launchers/minga").chmod(0o644)
        self.pack()
        self.build(failure="Packaged executable is not executable")

    def test_rejects_unsafe_archive_paths_and_member_types(self):
        self.make_fixture("x86_64")
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
        self.make_fixture("x86_64")
        self.pack()
        archive = bytearray(self.archive.read_bytes())
        archive[-8] ^= 1  # The gzip trailer starts with the CRC32.
        self.archive.write_bytes(archive)
        self.build(failure="CRC check failed")


if __name__ == "__main__":
    unittest.main()
