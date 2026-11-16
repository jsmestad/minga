"""Linux-only process barriers and pidfd observation, not a runtime substitute."""

import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import time


def emit(value):
    print(json.dumps(value, sort_keys=True), flush=True)


def identity(pid):
    stat = Path(f"/proc/{pid}/stat").read_text()
    fields = stat[stat.rindex(")") + 2:].split()
    return {"pid": pid, "state": fields[0], "parent": int(fields[1]), "start": fields[19]}


def record_identity(path):
    Path(path).write_text(json.dumps(identity(os.getpid())))


def inspect_owned(path):
    expected = json.loads(Path(path).read_text())
    owned = {}
    observation = "pid absent"
    try:
        try:
            fd = os.pidfd_open(expected["pid"])
        except ProcessLookupError:
            fd = None
        if fd is not None:
            try:
                current = identity(expected["pid"])
            except FileNotFoundError:
                current = None
            if current is not None and current["start"] == expected["start"]:
                owned[expected["pid"]] = (expected, fd)
                observation = current
            else:
                os.close(fd)
                observation = "original process exited; PID absent or reused"
        pending = wait_for_exit((fd for _, fd in owned.values()), 0.0)
        survivors = [entry for entry, fd in owned.values() if fd in pending]
    finally:
        interventions, after = terminate_owned(owned)
        for _, fd in owned.values():
            os.close(fd)
    emit({"identity": expected, "observation": observation, "survivors": survivors,
          "interventions": interventions, "survivors_after_cleanup": after})


def connect(role, address):
    connection = socket.socket(socket.AF_UNIX)
    connection.connect(address)
    connection.sendall((json.dumps({"role": role, "pid": os.getpid()}) + "\n").encode())
    return connection


def worker(role, address, sentinel):
    connection = connect(role, address)
    if role == "parent":
        child = subprocess.Popen([sys.executable, __file__, "child", address, sentinel])
        try:
            connection.recv(64)
        finally:
            child.terminate()
            child.wait()
    else:
        if connection.recv(64) == b"effect\n":
            Path(sentinel).write_bytes(b"child wrote after cancellation\n")
            connection.sendall(b"effect-complete\n")


def wait_for_exit(pending, seconds):
    pending = set(pending)
    deadline = time.monotonic() + seconds
    while pending:
        ready, _, _ = select.select(list(pending), [], [], max(0, deadline - time.monotonic()))
        pending.difference_update(ready)
        if time.monotonic() >= deadline:
            break
    return pending


def terminate_owned(owned):
    interventions = []
    pending = wait_for_exit((fd for _, fd in owned.values()), 0.0)
    for entry, fd in owned.values():
        if fd in pending:
            try:
                signal.pidfd_send_signal(fd, signal.SIGKILL)
                interventions.append(f"SIGKILL owned pid {entry['pid']} via pidfd")
            except ProcessLookupError:
                pass
    pending = wait_for_exit(pending, 2.0)
    return interventions, [entry for entry, fd in owned.values() if fd in pending]


def observe(address):
    # Fail before starting a workload when kernel or Python pidfd support is missing.
    fd = os.pidfd_open(os.getpid())
    signal.pidfd_send_signal(fd, 0)
    os.close(fd)
    listener = socket.socket(socket.AF_UNIX)
    peers = {}
    owned = {}
    report = {"event": "observed", "survivors": None, "late_effect": False,
              "interventions": [], "identity_sample": "registration; survival measured by pidfd"}
    status = 0
    try:
        listener.bind(address)
        listener.listen(2)
        listener.settimeout(3)
        emit({"event": "listening"})
        for _ in range(2):
            connection, _ = listener.accept()
            connection.settimeout(3)
            registration = json.loads(connection.makefile("rb").readline())
            peer_pid, _, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            role, pid = registration["role"], registration["pid"]
            if pid != peer_pid or role not in ("parent", "child") or role in peers:
                connection.close()
                raise RuntimeError("invalid fixture process registration")
            peers[role] = (connection, pid)
            owned[pid] = (identity(pid), os.pidfd_open(pid))
        if owned[peers["child"][1]][0]["parent"] != peers["parent"][1]:
            raise RuntimeError("registered child is not owned by the verification parent")
        emit({"event": "tree_ready", "owned": [entry[0] for entry in owned.values()]})
        action = sys.stdin.readline()
        if action == "cleanup\n":
            report["event"] = "cleanup"
        elif action == "inspect\n":
            pending = wait_for_exit((fd for _, fd in owned.values()), 1.0)
            report["survivors"] = [entry for entry, fd in owned.values() if fd in pending]
            child, child_pid = peers["child"]
            if any(entry["pid"] == child_pid for entry in report["survivors"]):
                report["interventions"].append("released surviving child through fixture barrier after cancellation")
                child.sendall(b"effect\n")
                report["late_effect"] = child.recv(64) == b"effect-complete\n"
        else:
            raise RuntimeError("missing cancellation observation barrier")
    except Exception as error:
        report.update(event="failed", error=f"{type(error).__name__}: {error}")
        status = 1
    finally:
        try:
            interventions, after = terminate_owned(owned)
            report["interventions"].extend(interventions)
            report["survivors_after_cleanup"] = after
            if after:
                status = 1
        except Exception as error:
            report.update(event="failed", cleanup_error=f"{type(error).__name__}: {error}",
                          survivors_after_cleanup=None)
            status = 1
        for _, fd in owned.values():
            os.close(fd)
        for connection, _ in peers.values():
            connection.close()
        listener.close()
        Path(address).unlink(missing_ok=True)
        emit(report)
    raise SystemExit(status)


if __name__ == "__main__":
    if sys.argv[1] == "observe":
        observe(sys.argv[2])
    elif sys.argv[1] == "inspect":
        inspect_owned(sys.argv[2])
    elif sys.argv[1] == "append":
        record_identity(sys.argv[2])
        with open(sys.argv[3], "ab") as target:
            target.write(b"once\n")
    elif sys.argv[1] in ("parent", "child"):
        worker(*sys.argv[1:])
    else:
        raise SystemExit("FAIL: unknown process fixture command")
