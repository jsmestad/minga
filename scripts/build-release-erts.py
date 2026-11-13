#!/usr/bin/env python3
"""Build the pinned native Burrito input; never publish or substitute host ERTS.

The receipt describes source-build qualification, not a final wrapped package.
Linux runs only inside the digest/index-pinned recipe beside this file.
Source identities are committed, never learned from checksum text during a build.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import uuid

SCRIPT = Path(__file__).resolve()
MANIFEST = SCRIPT.with_name("release_erts_sources.json")
CONTAINER = SCRIPT.with_name("release-erts.Dockerfile")
BUILD_SECONDS = 3300
MAX_SOURCE_BYTES = 256 * 1024 * 1024
MAX_MEMBERS = 150000
MAX_TREE_BYTES = 4 * 1024 * 1024 * 1024


class BuildError(Exception):
    """A failed prerequisite, build, or qualification. No successful receipt."""


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require(condition, message):
    if not condition:
        raise BuildError(message)


class Commands:
    """Own and reap a process group on every exceptional exit, with one budget."""

    def __init__(self, directory, env, seconds=BUILD_SECONDS):
        self.directory = directory
        self.env = env
        self.deadline = time.monotonic() + seconds
        self.number = 0

    def run(self, argv, cwd=None, seconds=900, extra_env=None):
        remaining = min(seconds, self.deadline - time.monotonic())
        require(remaining > 0, "source-build time budget exhausted")
        self.number += 1
        log = self.directory / ("command-%03d.log" % self.number)
        env = dict(self.env, **(extra_env or {}))
        with log.open("wb") as output:
            output.write(("command: " + json.dumps([str(a) for a in argv]) + "\n").encode())
            output.flush()
            try:
                process = subprocess.Popen([str(a) for a in argv], cwd=cwd or self.directory,
                                           env=env, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                           start_new_session=True)
            except OSError as error:
                raise BuildError("cannot start %s: %s; diagnostics: %s" % (argv[0], error, log)) from error
            try:
                status = process.wait(timeout=remaining)
                if status != 0:
                    raise self._failure("command failed (%s)" % status, log)
            except BaseException as error:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
                # A descendant can outlive its already-reaped direct parent.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                if isinstance(error, subprocess.TimeoutExpired):
                    raise self._failure("command timed out", log) from error
                raise
        if log.stat().st_size > 32 * 1024 * 1024:
            raise self._failure("command diagnostics exceed bound", log)
        return log.read_text(errors="replace").split("\n", 1)[1].strip()

    def _failure(self, description, log):
        with log.open("rb") as source:
            source.seek(0, os.SEEK_END)
            source.seek(max(0, source.tell() - 8192))
            tail = source.read(8192).decode("utf-8", errors="replace")
        return BuildError("%s; diagnostics: %s\nLast command output (at most 8192 bytes):\n%s" % (description, log, tail))


def private_environment(work):
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
           "MAKEFLAGS": "", "ERL_FLAGS": "+S 2:2 +A 2", "SOURCE_DATE_EPOCH": "0"}
    for name, child in (("HOME", "home"), ("XDG_CONFIG_HOME", "config"),
                        ("XDG_CACHE_HOME", "cache"), ("XDG_DATA_HOME", "data"),
                        ("XDG_STATE_HOME", "state"), ("TMPDIR", "tmp")):
        path = work / child
        path.mkdir()
        env[name] = str(path)
    return env


def native_target(os_name, arch):
    actual_os = {"Darwin": "macos", "Linux": "linux"}.get(platform.system())
    actual_arch = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64"}.get(platform.machine())
    require((actual_os, actual_arch) == (os_name, arch),
            "native target mismatch: requested %s/%s, host %s/%s" % (os_name, arch, actual_os, actual_arch))


def download(source, destination):
    """One bounded HTTPS acquisition; no mirror, retry, or checksum discovery."""
    require(source["url"].startswith("https://"), "source must use HTTPS")
    require(re.fullmatch(r"[0-9a-f]{64}", source["sha256"]) is not None, "invalid trusted source hash")
    try:
        with urllib.request.urlopen(source["url"], timeout=60) as response, destination.open("xb") as out:
            require(response.status == 200, "source download did not return HTTP 200")
            require(response.geturl().startswith("https://"), "source redirected outside HTTPS")
            total = 0
            deadline = time.monotonic() + 240
            while True:
                require(time.monotonic() < deadline, "source download deadline exceeded")
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                require(total <= MAX_SOURCE_BYTES, "source download exceeds bound")
                out.write(chunk)
        require(total > 0 and sha256(destination) == source["sha256"],
                "source checksum mismatch: %s" % destination.name)
    except BaseException:
        destination.unlink(missing_ok=True)
        raise


def unpack_source(archive, parent, expected_root):
    # Python's data filter rejects special files and escaping links.
    # Inspect all members first so no untrusted partial extraction precedes validation.
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        require(0 < len(members) <= MAX_MEMBERS, "source member count exceeds bound")
        total = 0
        for member in members:
            parts = Path(member.name).parts
            require(parts and parts[0] == expected_root and ".." not in parts and not Path(member.name).is_absolute(),
                    "unsafe or unexpected source archive root")
            total += member.size
            require(total <= MAX_TREE_BYTES, "source extracted size exceeds bound")
            require(member.isfile() or member.isdir() or member.issym() or member.islnk(), "special source member")
        require(hasattr(tarfile, "data_filter"), "Python with safe tar data_filter is required")
        source.extractall(parent, members=members, filter="data")
    return parent / expected_root


def regularize_tree(source, destination):
    """Materialize only internal links, bound expansion, reject directory cycles."""
    root = source.resolve(strict=True)
    count = 0
    total = 0
    pending = [(root, destination, frozenset())]
    while pending:
        path, target, ancestors = pending.pop()
        require(len(target.relative_to(destination).parts) <= 64, "release directory depth exceeds bound")
        try:
            resolved = path.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise BuildError("unresolvable release link: " + str(path)) from error
        require(resolved.is_relative_to(root), "release link escapes OTP root")
        mode = resolved.stat().st_mode
        count += 1
        require(count <= MAX_MEMBERS, "release tree expansion exceeds member bound")
        if stat.S_ISDIR(mode):
            require(resolved not in ancestors, "cyclic release directory link")
            target.mkdir(mode=stat.S_IMODE(mode))
            for child in sorted(resolved.iterdir(), reverse=True):
                pending.append((child, target / child.name, ancestors | {resolved}))
        else:
            require(stat.S_ISREG(mode), "special release file")
            total += resolved.stat().st_size
            require(total <= MAX_TREE_BYTES, "release tree exceeds byte bound")
            shutil.copyfile(resolved, target)
            target.chmod(stat.S_IMODE(mode))


def require_layout(root, manifest):
    erts = "erts-" + manifest["otp"]["erts_version"]
    for name in (erts, "releases", "lib", "misc", "usr"):
        require((root / name).is_dir(), "missing OTP directory: " + name)
    for name in ("Install", "bin/erl", erts + "/bin/erl", erts + "/bin/beam.smp", erts + "/bin/erlexec", erts + "/include/erl_nif.h",
                 "usr/include/erl_nif.h", "usr/include/erl_driver.h", "usr/lib/libei.a"):
        require((root / name).is_file(), "missing OTP input: " + name)
    for name in ("Install", "bin/erl", erts + "/bin/erl", erts + "/bin/beam.smp", erts + "/bin/erlexec"):
        require(os.access(root / name, os.X_OK), "OTP input is not executable: " + name)
    require(any((root / "lib").glob("crypto-*/priv/lib/crypto.*")), "missing crypto native library")


def native_files(root, os_name, arch):
    files = []
    expected = {"linux": {"aarch64": 183, "x86_64": 62},
                "macos": {"aarch64": 0x100000C, "x86_64": 0x1000007}}[os_name][arch]
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        with path.open("rb") as source:
            header = source.read(64)
        if header.startswith(b"\x7fELF"):
            require(os_name == "linux" and len(header) >= 20 and header[4:6] == b"\x02\x01",
                    "unexpected native ELF format: " + str(path))
            require(struct.unpack_from("<H", header, 18)[0] == expected, "wrong ELF architecture: " + str(path))
            files.append(path)
        elif header[:4] == b"\xcf\xfa\xed\xfe":
            require(os_name == "macos" and struct.unpack_from("<I", header, 4)[0] == expected,
                    "wrong Mach-O architecture: " + str(path))
            files.append(path)
        elif header[:4] in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xce\xfa\xed\xfe"):
            raise BuildError("non-thin or unsupported Mach-O: " + str(path))
    require(len(files) <= 512, "native dependency inventory exceeds bound")
    require(any(p.name == "beam.smp" for p in files) and any(p.name == "erlexec" for p in files),
            "release has no native VM/launcher")
    return files


def macos_closure(commands, root, files, minimum):
    inventory = []
    for path in files:
        loads = commands.run(["/usr/bin/otool", "-l", path], seconds=30)
        versions = re.findall(r"\bminos\s+(\d+\.\d+(?:\.\d+)?)", loads)
        if not versions:
            versions = re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+\.\d+(?:\.\d+)?)", loads)
        require(versions and all(tuple(map(int, v.split(".")[:2])) == (15, 0) for v in versions),
                "Mach-O minimum macOS is not %s: %s" % (minimum, path))
        dependencies = []
        for line in commands.run(["/usr/bin/otool", "-L", path], seconds=30).splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            require(dependency.startswith(("/usr/lib/", "/System/Library/")),
                    "unqualified external macOS dependency: " + dependency)
            require("libssl" not in dependency and "libcrypto" not in dependency,
                    "OpenSSL is not statically linked")
            dependencies.append(dependency)
        inventory.append({"file": str(path.relative_to(root)), "libraries": sorted(dependencies)})
    return inventory


def linux_closure(commands, root, files, interpreter, arch):
    inventory = []
    libc = "libc.musl-%s.so.1" % arch
    for path in files:
        program = commands.run(["readelf", "-l", path], seconds=30)
        interpreters = re.findall(r"Requesting program interpreter: ([^\]]+)\]", program)
        if path.name in ("beam.smp", "erlexec"):
            require(len(interpreters) == 1, "native VM/launcher lacks its musl interpreter")
        if interpreters:
            commands.run(["patchelf", "--set-interpreter", interpreter, path], seconds=30)
            actual = commands.run(["patchelf", "--print-interpreter", path], seconds=30)
            require(actual == interpreter, "ELF interpreter patch did not bind helper")
        dynamic = commands.run(["readelf", "-d", path], seconds=30)
        dependencies = re.findall(r"\(NEEDED\).*\[([^\]]+)\]", dynamic)
        require(all(dep == libc for dep in dependencies), "unqualified ELF dependency: %s: %s" % (path, dependencies))
        require("(RPATH)" not in dynamic and "(RUNPATH)" not in dynamic, "ELF contains build-time library search path")
        inventory.append({"file": str(path.relative_to(root)), "libraries": sorted(dependencies)})
    return inventory


def boot_check(commands, root, manifest, arch):
    erts = manifest["otp"]["erts_version"]
    bindir = root / ("erts-" + erts) / "bin"
    # OTP_VERSION contains the full maintenance release; otp_release alone is 29.
    versions = list((root / "releases").glob("*/OTP_VERSION"))
    require(len(versions) == 1, "ambiguous or missing OTP maintenance version")
    version = versions[0]
    require(version.read_text().strip() == manifest["otp"]["version"], "wrong OTP maintenance version")
    expression = ('"%s" = erlang:system_info(version), '
                  '"29" = erlang:system_info(otp_release), '
                  'true = code:root_dir() =:= os:getenv("MINGA_ERTS_EXPECTED_ROOT"), '
                  'ok = application:start(crypto), '
                  'static = maps:get(link_type, crypto:info()), '
                  '<<186,120,22,191,143,1,207,234,65,65,64,222,93,174,34,35,176,3,97,163,150,23,122,156,180,16,255,97,242,0,21,173>> = crypto:hash(sha256, <<"abc">>), '
                  'true = lists:any(fun({<<"OpenSSL">>, _, V}) -> binary:match(V, <<"OpenSSL 3.5.1 ">>) =/= nomatch; (_) -> false end, crypto:info_lib()), '
                  'io:format("MINGA_ERTS_OK~n"), halt(0).') % erts
    # Exercise OTP's relocated launcher without supplying ROOTDIR/BINDIR to conceal a stale install path.
    result = commands.run([bindir / "erl", "+S", "2:2", "+A", "2", "-boot", version.parent / "start_clean",
                           "-noshell", "-noinput", "-eval", expression],
                          seconds=60, extra_env={"MINGA_ERTS_EXPECTED_ROOT": str(root)})
    require(result == "MINGA_ERTS_OK", "runtime qualification did not complete")


def source_build(commands, work, root, manifest, os_name, arch):
    sources = {}
    for name in ("otp", "openssl") + (("musl",) if os_name == "linux" else ()):
        identity = {key: manifest[name][key] for key in ("url", "sha256")}
        archive = work / (name + ".tar.gz")
        download(identity, archive)
        sources[name] = identity
    openssl = unpack_source(work / "openssl.tar.gz", work, "openssl-" + manifest["openssl"]["version"])
    otp = unpack_source(work / "otp.tar.gz", work, "otp_src_" + manifest["otp"]["version"])
    if os_name == "linux":
        # Verify source identity as well as the pinned musl-compatible sysroot.
        unpack_source(work / "musl.tar.gz", work, "musl-" + manifest["musl"]["version"])
    sysroot = work / "sysroot"
    target = {("macos", "aarch64"): "darwin64-arm64", ("macos", "x86_64"): "darwin64-x86_64",
              ("linux", "aarch64"): "linux-aarch64", ("linux", "x86_64"): "linux-x86_64"}[os_name, arch]
    commands.run(["/usr/bin/perl" if os_name == "macos" else "perl", "Configure", target,
                  "no-tests", "no-shared", "no-asm", "--prefix=" + str(sysroot), "--libdir=lib"], cwd=openssl)
    jobs = str(min(os.cpu_count() or 2, 4))
    commands.run(["make", "-j" + jobs], cwd=openssl)
    commands.run(["make", "install_sw"], cwd=openssl)
    commands.run(["./configure", "--without-javac", "--without-jinterface", "--without-wx",
                  "--without-termcap", "--without-megaco", "--with-ssl=" + str(sysroot),
                  "--disable-dynamic-ssl-lib", "--with-ssl-rpath=no"], cwd=otp)
    commands.run(["make", "-j" + jobs], cwd=otp, seconds=1800)
    commands.run(["make", "release", "-j" + jobs, "RELEASE_ROOT=" + str(root)], cwd=otp)
    # make release stages templates; upstream Install generates both launchers, boot files and release metadata.
    # Its launchers locate a moved OTP tree.
    commands.run(["./Install", "-minimal", root], cwd=root, seconds=60)
    return sources


def qualify_interface(commands, root, manifest):
    """Compile and execute against the actual headers/static interface library."""
    source = commands.directory / "interface-probe.c"
    source.write_text('#include "ei.h"\n#include "erl_nif.h"\nint main(void) { return ei_init(); }\n')
    program = commands.directory / "interface-probe"
    include = root / ("erts-" + manifest["otp"]["erts_version"]) / "include"
    commands.run([commands.env["CC"], *shlex.split(commands.env["CFLAGS"]),
                  "-I" + str(root / "usr/include"), "-I" + str(include), source,
                  root / "usr/lib/libei.a", "-o", program], seconds=60)
    commands.run([program], seconds=30)


def native_build(output, manifest, os_name, arch, work):
    env = private_environment(work)
    commands = Commands(work, env)
    facts = {"host_arch": arch}
    if os_name == "macos":
        pinned = manifest["macos_build_environment"]
        require(Path(pinned["developer_dir"]).is_dir(), "pinned Xcode Developer directory is unavailable: " + pinned["developer_dir"])
        env["DEVELOPER_DIR"] = pinned["developer_dir"]
        xcode = commands.run(["/usr/bin/xcodebuild", "-version"], seconds=30)
        require(xcode.splitlines() == ["Xcode " + pinned["xcode_version"], "Build version " + pinned["xcode_build"]],
                "native Xcode version/build does not match committed environment")
        compiler = commands.run(["/usr/bin/xcrun", "--find", "clang"], seconds=30)
        cxx = commands.run(["/usr/bin/xcrun", "--find", "clang++"], seconds=30)
        sdk = commands.run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], seconds=30)
        identity = commands.run([compiler, "--version"], seconds=30).splitlines()[0]
        sdk_version = commands.run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"], seconds=30)
        require(identity.startswith("Apple clang version "), "unqualified macOS compiler")
        cpu = "arm64" if arch == "aarch64" else arch
        flags = "-arch %s -mmacosx-version-min=15.0 -isysroot %s" % (cpu, sdk)
        env.update(CC=compiler, CXX=cxx, CFLAGS=flags, CXXFLAGS=flags, LDFLAGS=flags,
                   MACOSX_DEPLOYMENT_TARGET=manifest["minimum_macos"], SDKROOT=sdk)
        facts.update(kind="native-macos", developer_dir=pinned["developer_dir"],
                     xcode_version=pinned["xcode_version"], xcode_build=pinned["xcode_build"],
                     clang_version=identity, sdk_version=sdk_version,
                     host_os_version=platform.mac_ver()[0])
    else:
        require(Path("/minga-erts-base-image").read_text().strip() == manifest["linux_build_image"]["image"],
                "Linux build must run in the pinned producer image")
        image_id = os.environ.get("MINGA_ERTS_BUILD_IMAGE_ID", "")
        require(re.fullmatch(r"sha256:[0-9a-f]{64}", image_id) is not None, "missing immutable built-image identity")
        compiler = commands.run(["gcc", "--version"], seconds=30).splitlines()[0]
        require("13.2.1" in compiler, "wrong Linux compiler")
        require("musl-1.2.5-r4" in Path("/minga-erts-packages.txt").read_text().splitlines(), "wrong Linux musl sysroot")
        env.update(CC="gcc", CXX="g++", CFLAGS="-O2 -fPIC", CXXFLAGS="-O2 -fPIC", LDFLAGS="-static-libgcc -static-libstdc++")
        facts.update(kind="native-alpine", cc_version=compiler,
                     image=manifest["linux_build_image"]["image"], musl_version=manifest["musl"]["version"],
                     container_os_version=Path("/etc/alpine-release").read_text().strip(), image_id=image_id,
                     container_recipe_sha256=sha256(CONTAINER),
                     packages=Path("/minga-erts-packages.txt").read_text().splitlines())
    root_name = "otp-%s-%s-%s" % (manifest["otp"]["version"], os_name, arch)
    raw = work / "release"
    sources = source_build(commands, work, raw, manifest, os_name, arch)
    root = work / root_name
    regularize_tree(raw, root)
    require_layout(root, manifest)
    qualify_interface(commands, root, manifest)
    files = native_files(root, os_name, arch)
    interpreter = None
    helper_hash = None
    helper_path = None
    if os_name == "linux":
        helper = manifest["musl"]["helpers"]["linux_" + arch]
        helper_hash = helper["sha256"]
        interpreter = "/tmp/libc-musl-%s.so" % helper_hash
        helper_path = Path(interpreter)
        require(not helper_path.exists(), "refusing to reuse existing qualification helper")
        download(helper, helper_path)
        helper_path.chmod(0o755)
    try:
        if os_name == "macos":
            inventory = macos_closure(commands, root, files, manifest["minimum_macos"])
        else:
            inventory = linux_closure(commands, root, files, interpreter, arch)
        boot_check(commands, root, manifest, arch)
    finally:
        if helper_path is not None:
            helper_path.unlink(missing_ok=True)
    checks = ["otp-version", "erts-version", "native-architecture", "crypto-result", "native-library-closure"]
    checks += ["minimum-macos"] if os_name == "macos" else ["musl-interpreter", "musl-helper"]
    archive = output / "erts.tar.gz"
    temporary = output / ".erts.tar.gz.partial"
    with tarfile.open(temporary, "w:gz", dereference=True) as tar:
        def archive_member(member):
            require(member.isfile() or member.isdir(), "non-regular release archive member")
            member.uid = member.gid = 0
            member.uname = member.gname = ""
            member.mtime = 0
            return member
        tar.add(root, arcname=root_name, filter=archive_member)
    os.replace(temporary, archive)
    receipt = {"version": 1, "kind": "local-source-build", "os": os_name, "arch": arch,
               "otp_version": manifest["otp"]["version"], "erts_version": manifest["otp"]["erts_version"],
               "openssl_version": manifest["openssl"]["version"],
               "musl_version": manifest["musl"]["version"] if os_name == "linux" else None,
               "minimum_macos": manifest["minimum_macos"] if os_name == "macos" else None,
               "archive": {"file": "erts.tar.gz", "root": root_name, "bytes": archive.stat().st_size,
                           "sha256": sha256(archive)},
               "recipe_sha256": sha256(SCRIPT), "sources": sources, "build_environment": facts,
               "abi": {"interpreter": interpreter, "musl_sha256": helper_hash,
                       "external_dependencies": inventory,
                       "minimum_macos": manifest["minimum_macos"] if os_name == "macos" else None},
               "checks": checks}
    require(len(json.dumps(receipt)) <= 512 * 1024, "receipt exceeds bounded evidence size")
    temporary_receipt = output / ".receipt.json.partial"
    with temporary_receipt.open("x") as target:
        json.dump(receipt, target, indent=2, sort_keys=True)
        target.write("\n")
        target.flush()
        os.fsync(target.fileno())
    os.replace(temporary_receipt, output / "receipt.json")


def linux_container(output, manifest, work):
    commands = Commands(work, private_environment(work))
    image = "minga-erts-" + uuid.uuid4().hex
    name = image + "-build"
    # A context containing only the container recipe cannot leak checkout data.
    context = work / "container"
    context.mkdir()
    shutil.copyfile(CONTAINER, context / "Dockerfile")
    launched = False
    try:
        commands.run(["docker", "build", "--pull=false", "--tag", image, context], seconds=600)
        identity = commands.run(["docker", "image", "inspect", "--format={{.Id}}", image], seconds=30)
        launched = True
        commands.run(["docker", "run", "--init", "--name", name, "--stop-timeout", "5",
                      "--network", "bridge", "--user", "%s:%s" % (os.getuid(), os.getgid()),
                      "--mount", "type=bind,src=%s,dst=/output" % output,
                      "--mount", "type=bind,src=%s,dst=/recipe,readonly" % SCRIPT.parent,
                      "--env", "MINGA_ERTS_BUILD_IMAGE_ID=" + identity, image,
                      "python3", "/recipe/build-release-erts.py", "--os", "linux", "--arch", platform.machine(),
                      "--output", "/output", "--linux-worker"], seconds=BUILD_SECONDS - 600)
    finally:
        # docker run's client process group is not the container's process tree.
        # Always stop/remove the owned container, including timeout/signal paths.
        cleanup = Commands(work, commands.env, seconds=45)
        cleanup.number = commands.number
        if launched:
            try:
                cleanup.run(["docker", "stop", "--time", "5", name], seconds=12)
            except BuildError:
                pass  # The subsequent force removal is mandatory, not best effort.
            try:
                cleanup.run(["docker", "rm", "--force", name], seconds=15)
            except BuildError as error:
                raise BuildError("could not reap owned container %s; diagnostics in %s" % (name, work)) from error
        try:
            cleanup.run(["docker", "image", "rm", image], seconds=15)
        except BuildError:
            pass  # An unused image is not a running subprocess or a receipt.


def produce(os_name, arch, output, worker=False):
    output = Path(output).absolute()
    output.mkdir(parents=True, exist_ok=True)
    # Serialize ownership and invalidate success BEFORE any target/build check.
    lock = output / ".producer.lock"
    try:
        descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as error:
        raise BuildError("another producer owns output (or abandoned lock): " + str(lock)) from error
    os.close(descriptor)
    try:
        for filename in ("receipt.json", "erts.tar.gz", ".receipt.json.partial", ".erts.tar.gz.partial"):
            (output / filename).unlink(missing_ok=True)
        require(os_name in ("macos", "linux") and arch in ("aarch64", "x86_64"), "unsupported native target")
        native_target(os_name, arch)
        manifest = json.loads(MANIFEST.read_text())
        require(manifest["version"] == 1, "unsupported source manifest")
        work = Path(tempfile.mkdtemp(prefix="build-", dir=output))
        if os_name == "linux" and not worker:
            # Worker owns its own output lock; outer lock remains on host only.
            worker_output = output / "container-output"
            worker_output.mkdir(exist_ok=True)
            linux_container(worker_output, manifest, work)
            for filename in ("erts.tar.gz", "receipt.json"):
                require((worker_output / filename).is_file(), "Linux worker did not produce " + filename)
                os.replace(worker_output / filename, output / filename)
        else:
            require(not worker or os_name == "linux", "Linux worker requires Linux target")
            native_build(output, manifest, os_name, arch, work)
    except BaseException:
        (output / "receipt.json").unlink(missing_ok=True)
        raise
    finally:
        lock.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--os", required=True, metavar="macos|linux")
    parser.add_argument("--arch", required=True, metavar="aarch64|x86_64")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--linux-worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    def interrupted(signum, frame):
        raise BuildError("producer interrupted by signal %s" % signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        produce(args.os, args.arch, args.output, args.linux_worker)
    except (BuildError, OSError, ValueError, tarfile.TarError) as error:
        print("ERTS source build failed: %s" % error, file=sys.stderr)
        return 1
    print(args.output / "receipt.json")
    return 0

if __name__ == "__main__":
    sys.exit(main())
