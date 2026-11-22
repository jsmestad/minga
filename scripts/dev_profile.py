#!/usr/bin/env python3
"""Own the source launchers' runtime profile and its reset lifecycle."""

import errno
import fcntl
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CONTROL = ROOT / ".minga-dev"
PROFILE = CONTROL / "profile"
LAUNCHERS = {"minga", "minga-dev", "minga-mac"}
INHERITED = {
    "PATH", "USER", "LOGNAME", "TERM", "COLORTERM", "TERMINFO", "TERMINFO_DIRS", "LANG", "LC_ALL", "LC_CTYPE", "TZ",
    "DEVELOPER_DIR", "SDKROOT", "ASDF_DATA_DIR", "MISE_DATA_DIR", "MISE_CONFIG_DIR",
    "MIX_HOME", "MIX_ARCHIVES", "HEX_HOME", "REBAR_CACHE_DIR", "ELIXIR_MAKE_CACHE_DIR", "GOCACHE", "GOMODCACHE",
    "GOPATH", "GOROOT", "GOTOOLCHAIN", "ZIG_GLOBAL_CACHE_DIR", "ERL_FLAGS",
    "MINGA_TTY", "MINGA_SKIP_NATIVE_LAUNCH_BUILD", "MINGA_DISABLE_LAUNCH_STDIO_REDIRECT",
}


def private_directory(path):
    path.mkdir(mode=0o700, exist_ok=True)
    entry = path.lstat()
    if not stat.S_ISDIR(entry.st_mode) or entry.st_uid != os.getuid() or entry.st_mode & 0o077:
        raise ValueError(f"not a private development directory: {path}")
    return str(path)


def launch(profile, name, args, lock=None):
    home = Path.home()
    env = {key: value for key, value in os.environ.items() if key in INHERITED}
    for key, relative in {
        "ASDF_DATA_DIR": ".asdf", "MIX_HOME": ".mix", "HEX_HOME": ".hex",
        "GOPATH": "go", "MISE_DATA_DIR": ".local/share/mise", "MISE_CONFIG_DIR": ".config/mise",
    }.items():
        env.setdefault(key, str(home / relative))
    if sys.platform == "darwin":
        build_cache = home / "Library" / "Caches"
    else:
        build_cache = Path(os.environ.get("XDG_CACHE_HOME") or home / ".cache")
    env.setdefault("GOCACHE", str(build_cache / "go-build"))
    env.setdefault("ELIXIR_MAKE_CACHE_DIR", str(build_cache / "elixir_make"))
    private_directory(profile)
    for key, directory in {
        "HOME": "home", "XDG_CONFIG_HOME": "config", "XDG_DATA_HOME": "data",
        "XDG_CACHE_HOME": "cache", "XDG_STATE_HOME": "state", "TMPDIR": "tmp",
    }.items():
        env[key] = private_directory(profile / directory)
    env["MIX_ENV"] = "dev"
    env["MINGA_DEV_PROFILE"] = str(profile)
    command = [ROOT / "bin" / "lib" / name, *args]
    if lock is not None:
        os.set_inheritable(lock.fileno(), True)
        os.execve(command[0], command, env)
    with subprocess.Popen(command, env=env) as child:
        signal.signal(signal.SIGTERM, lambda signum, _: child.send_signal(signum))
        try:
            status = child.wait()
        except KeyboardInterrupt:
            status = child.wait()
    return status if status >= 0 else 128 - status


def main(args):
    if len(args) >= 2 and args[0] == "fresh" and args[1] in LAUNCHERS:
        with tempfile.TemporaryDirectory(prefix="minga-dev-") as profile:
            return launch(Path(profile), args[1], args[2:])
    if args != ["clean"] and not (len(args) >= 2 and args[0] == "launch" and args[1] in LAUNCHERS):
        raise ValueError("expected clean, launch <source launcher>, or fresh <source launcher>")
    private_directory(CONTROL)
    fd = os.open(CONTROL / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "rb") as lock:
        try:
            mode = fcntl.LOCK_EX if args == ["clean"] else fcntl.LOCK_SH
            fcntl.flock(lock, mode | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EAGAIN):
                raise
            raise ValueError("development profile is in use; quit Minga first") from error
        if args == ["clean"]:
            if PROFILE.exists() or PROFILE.is_symlink():
                private_directory(PROFILE)
                shutil.rmtree(PROFILE)
            print(f"Development profile is clean: {PROFILE}")
            return 0
        return launch(PROFILE, args[1], args[2:], lock)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError) as error:
        sys.exit(f"minga dev: {error}")
