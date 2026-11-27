"""Drive Minga's real LSP client in a disposable BEAM. Run with --expert to use the installed default Elixir server."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


BEAM = r'''
root = System.fetch_env!("LSP_TEST_ROOT")
File.touch!(Path.join(root, "editor-booted"))
args = System.argv()
config = case args do
  ["expert"] -> hd(Minga.Language.Elixir.definition().language_servers)
  [python, fixture, mode] ->
    %Minga.LSP.ServerConfig{name: :fixture, command: python, args: [fixture, "--server", root, mode]}
end
{:ok, supervisor} = Supervisor.start_link(
  [Minga.Events, Minga.Config.Options, Minga.Diagnostics, Minga.LSP.Supervisor], strategy: :one_for_one
)
Process.unlink(supervisor)
Minga.Events.subscribe(:lsp_status_changed)
{:ok, client} = Minga.LSP.Supervisor.ensure_client(config, root)
monitor = Process.monitor(client)
receive do
  {:minga_event, :lsp_status_changed, %{status: :ready}} -> :ok
  {:DOWN, ^monitor, :process, ^client, reason} -> raise "LSP client exited during initialization: #{inspect(reason)}"
after
  15_000 -> raise "LSP did not initialize"
end
Process.demonitor(monitor, [:flush])
Minga.Events.unsubscribe(:lsp_status_changed)
uri = "file://" <> Path.join(root, "mix.exs")
Minga.LSP.Client.did_open(client, uri, "elixir", File.read!(Path.join(root, "mix.exs")))
File.write!(Path.join(root, "editor-ready"), System.pid())
IO.gets("")
if List.last(args) == "blocked" do
  Minga.LSP.Client.request(client, "fixture/largeRequest", %{"text" => String.duplicate("x", 1_000_000)})
  :ok = Minga.LSP.Supervisor.stop_client({config.name, root})
  File.write!(Path.join(root, "client-stopped"), "")
  IO.gets("")
end
Supervisor.stop(supervisor)
'''


def run_server(root, mode):
    # Start a child in a different session, as Erlang does for a nested Port. It does not read stdin and does not exit on SIGTERM.
    child = subprocess.Popen(
        [sys.executable, "-c", "import signal; signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.pause()"],
        start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    infile, outfile = sys.stdin.buffer, sys.stdout.buffer
    (root / "fixture-pids").write_text(f"{os.getpid()} {child.pid}")
    with (root / "server-events").open("w", buffering=1) as events:
        for first_header in infile:
            length = int(first_header.split(b":", 1)[1])
            while infile.readline().strip():
                pass
            message = json.loads(infile.read(length))
            method = message.get("method")
            if method in ("initialize", "shutdown"):
                events.write(method + "\n")
                result = {"capabilities": {}} if method == "initialize" else None
                body = json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}).encode()
                outfile.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
                outfile.flush()
            elif method == "textDocument/didOpen" and mode == "blocked":
                (root / "stop-reading").touch()
                signal.pause()
            elif method == "exit":
                events.write("exit\n")
                if mode != "wedge":
                    # Leave the still-attached child to the guard, even though the top-level server exits normally.
                    return
                break
    # This fixture deliberately survives EOF so the test requires OS-level cleanup.
    signal.pause()


def process_snapshot():
    output = subprocess.check_output(["ps", "-ax", "-o", "pid=,ppid=,state=,comm="], text=True)
    return {int(pid): (int(parent), state, command) for pid, parent, state, command in
            (line.split(maxsplit=3) for line in output.splitlines())}


def descendants(snapshot, parent):
    found = set()
    pending = [parent]
    while pending:
        owner = pending.pop()
        children = {pid for pid, row in snapshot.items() if row[0] == owner}
        found.update(children)
        pending.extend(children)
    return found


def wait_for(probe, seconds, message):
    deadline = time.monotonic() + seconds
    while not (value := probe()):
        if time.monotonic() >= deadline:
            raise AssertionError(message() if callable(message) else message)
        time.sleep(0.025)
    return value


class LspProcessCleanupTest(unittest.TestCase):
    use_expert = False

    def exercise(self, mode):
        with tempfile.TemporaryDirectory(prefix="minga-lsp-cleanup-") as directory:
            root = Path(directory)
            (root / "mix.exs").write_text('defmodule Cleanup.MixProject do\n  use Mix.Project\n  def project, do: [app: :cleanup, version: "0.0.0"]\nend\n')
            args = ["expert"] if self.use_expert else [sys.executable, str(Path(__file__).resolve()), mode]
            env = dict(os.environ, MIX_ENV="test", LSP_TEST_ROOT=directory, XDG_DATA_HOME=directory)
            with (root / "editor.log").open("w+") as log:
                editor = subprocess.Popen(["mix", "run", "--no-start", "--no-compile", "--no-deps-check", "-e", BEAM, "--", *args],
                                          stdin=subprocess.PIPE, stdout=log, stderr=log, env=env)
                owned = {}
                try:
                    booted = root / "editor-booted"
                    wait_for(lambda: editor.poll() is not None or booted.exists(),
                             60, "Mix did not reach the LSP test entry point")
                    self.assertTrue(booted.exists(), "Mix exited before reaching the LSP test entry point")

                    ready = root / "editor-ready"
                    # Start the readiness deadline after boot and leave time for the BEAM's 15-second error.
                    wait_for(lambda: editor.poll() is not None or (ready.is_file() and ready.stat().st_size),
                             20, "Minga booted but its LSP client did not initialize")
                    self.assertIsNone(editor.poll(), "Minga exited while starting its LSP client")
                    self.assertEqual(int(ready.read_text()), editor.pid)

                    def ready_processes():
                        snapshot = process_snapshot()
                        children = descendants(snapshot, editor.pid)
                        if self.use_expert:
                            if sum(Path(snapshot[pid][2]).name == "beam.smp" for pid in children) < 2:
                                return None
                        else:
                            fixture_pids = {int(pid) for pid in (root / "fixture-pids").read_text().split()}
                            if len(fixture_pids) != 2 or not fixture_pids <= children:
                                return None
                            if mode == "blocked":
                                if not (root / "stop-reading").exists():
                                    return None
                                children = fixture_pids
                        return {pid: snapshot[pid][2] for pid in children}

                    owned = wait_for(ready_processes, 20 if self.use_expert else 3, "Language server and its child did not start")
                    if mode == "kill":
                        editor.kill()
                    else:
                        editor.stdin.write(b"quit\n")
                        editor.stdin.flush()
                    if mode == "blocked":
                        wait_for((root / "client-stopped").exists, 6, "LspStop did not return with a full Port")
                        self.assertIsNone(editor.poll())
                    else:
                        self.assertEqual(editor.wait(timeout=5), -signal.SIGKILL if mode == "kill" else 0)

                    def survivors():
                        snapshot = process_snapshot()
                        return {pid: snapshot[pid] for pid in owned.keys() & snapshot.keys()
                                if not snapshot[pid][1].startswith("Z") and snapshot[pid][2] == owned[pid]}

                    wait_for(lambda: not survivors(), 3, lambda: f"Language server processes still running: {survivors()}")
                    if mode == "blocked":
                        self.assertIsNone(editor.poll(), "Cleanup must not require the editor to quit")
                        editor.stdin.write(b"quit\n")
                        editor.stdin.flush()
                        self.assertEqual(editor.wait(timeout=5), 0)
                    if not self.use_expert:
                        expected = ["initialize"] if mode in ("kill", "blocked") else ["initialize", "shutdown", "exit"]
                        self.assertEqual((root / "server-events").read_text().splitlines(), expected)
                except (AssertionError, subprocess.TimeoutExpired) as failure:
                    log.seek(0)
                    stderr = root / "minga" / "minga.log"
                    server_output = stderr.read_text(errors="replace") if stderr.exists() else ""
                    self.fail(f"{failure}\nMinga output:\n{log.read()}\nLanguage server and guard stderr:\n{server_output}")
                finally:
                    if editor.poll() is None:
                        editor.kill()
                        editor.wait(timeout=5)
                    editor.stdin.close()
                    snapshot = process_snapshot()
                    for pid, command in owned.items():
                        if pid in snapshot and snapshot[pid][2] == command and not snapshot[pid][1].startswith("Z"):
                            try:
                                os.kill(pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass

    def test_sigkill_reclaims_language_server_and_its_child(self):
        self.exercise("kill")

    def test_clean_quit_sends_shutdown_then_exit_and_waits_for_server(self):
        self.exercise("quit")

    def test_clean_quit_reclaims_server_that_hangs_after_exit(self):
        if self.use_expert:
            self.skipTest("requires the unresponsive server fixture")
        self.exercise("wedge")

    def test_lsp_stop_closes_a_full_port_while_editor_keeps_running(self):
        if self.use_expert:
            self.skipTest("requires the unresponsive server fixture")
        self.exercise("blocked")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--server":
        run_server(Path(sys.argv[2]), sys.argv[3])
    else:
        if len(sys.argv) > 1 and sys.argv[1] == "--expert":
            LspProcessCleanupTest.use_expert = True
            del sys.argv[1]
        unittest.main()
