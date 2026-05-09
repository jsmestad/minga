defmodule MingaAgent.Hooks.CommandRunnerTest do
  # Runs real /bin/sh commands through Port, so keep it out of async test runs.
  use ExUnit.Case, async: false

  alias MingaAgent.Hooks.CommandRunner
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.PreToolUsePayload
  alias MingaAgent.Hooks.Result

  @moduletag :heavy

  test "passes JSON payload on stdin and treats non-zero exit as veto with stderr" do
    hook = %Hook{
      event: :pre_tool_use,
      tool_pattern: "shell",
      command:
        "payload=$(cat); case \"$payload\" in *'\"tool_name\":\"shell\"'*) echo blocked >&2; exit 4;; *) echo missing payload >&2; exit 5;; esac"
    }

    payload = PreToolUsePayload.new("tc_1", "shell", %{"command" => "date"})

    assert %Result{status: :veto, exit_status: 4, stderr: stderr} =
             CommandRunner.run_pre_tool_use(hook, payload)

    assert stderr =~ "blocked"
  end

  test "removes private payload directory after hook exits" do
    tmp_root = temp_path("payload-root")
    File.mkdir_p!(tmp_root)
    with_tmpdir(tmp_root)

    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: "cat >/dev/null"}
    payload = PreToolUsePayload.new("tc_1", "read_file", %{"path" => "README.md"})

    assert %Result{status: :allow} = CommandRunner.run_pre_tool_use(hook, payload)
    assert File.ls!(tmp_root) == []

    File.rmdir(tmp_root)
  end

  test "vetoes when hook payload cannot be encoded as JSON" do
    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: "cat >/dev/null"}
    payload = PreToolUsePayload.new("tc_1", "read_file", %{{:bad, :key} => "secret"})

    assert %Result{
             status: :veto,
             reason: {:failed_to_start, {:encode_failed, String.Chars}},
             stderr: stderr
           } = CommandRunner.run_pre_tool_use(hook, payload)

    assert stderr =~ "failed to prepare hook payload"
    assert stderr =~ "String.Chars"
    refute stderr =~ "secret"
  end

  test "times out long-running hooks and returns a clear veto" do
    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: "sleep 1", timeout_ms: 20}
    payload = PreToolUsePayload.new("tc_1", "read_file", %{"path" => "README.md"})

    assert %Result{status: :veto, reason: :timeout, stderr: stderr} =
             CommandRunner.run_pre_tool_use(hook, payload)

    assert stderr =~ "timed out after 20ms"
    assert stderr =~ "killed"
  end

  @tag timeout: 2_000
  test "times out by wall clock even when hook keeps writing stderr" do
    command =
      "i=0; while [ \"$i\" -lt 20 ]; do echo tick $i >&2; i=$((i + 1)); sleep 0.05; done; sleep 1"

    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: command, timeout_ms: 100}
    payload = PreToolUsePayload.new("tc_1", "read_file", %{"path" => "README.md"})
    started_ms = System.monotonic_time(:millisecond)

    assert %Result{status: :veto, reason: :timeout, stderr: stderr} =
             CommandRunner.run_pre_tool_use(hook, payload)

    elapsed_ms = System.monotonic_time(:millisecond) - started_ms

    assert stderr =~ "timed out after 100ms"
    assert stderr =~ "killed"
    assert elapsed_ms < 500
  end

  @tag timeout: 2_000
  test "timeout kills the hook shell and its child process" do
    shell_pid_path = temp_path("shell-pid")
    child_pid_path = temp_path("child-pid")

    command =
      "echo $$ > #{shell_quote(shell_pid_path)}; sleep 5 & echo $! > #{shell_quote(child_pid_path)}; wait"

    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: command, timeout_ms: 50}
    payload = PreToolUsePayload.new("tc_1", "read_file", %{"path" => "README.md"})

    assert %Result{status: :veto, reason: :timeout} =
             CommandRunner.run_pre_tool_use(hook, payload)

    shell_pid = read_pid!(shell_pid_path)
    child_pid = read_pid!(child_pid_path)

    refute_process_alive(shell_pid)
    refute_process_alive(child_pid)

    File.rm(shell_pid_path)
    File.rm(child_pid_path)
  end

  defp temp_path(label) do
    Path.join(System.tmp_dir!(), "minga-hook-#{label}-#{System.unique_integer([:positive])}")
  end

  defp with_tmpdir(tmp_root) do
    previous = System.get_env("TMPDIR")
    System.put_env("TMPDIR", tmp_root)

    on_exit(fn ->
      restore_tmpdir(previous)
      File.rm_rf(tmp_root)
    end)
  end

  defp restore_tmpdir(nil), do: System.delete_env("TMPDIR")
  defp restore_tmpdir(previous), do: System.put_env("TMPDIR", previous)

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp read_pid!(path) do
    path
    |> File.read!()
    |> String.trim()
    |> String.to_integer()
  end

  defp refute_process_alive(pid) do
    if process_exited?(pid, 10) do
      :ok
    else
      flunk("expected OS process #{pid} to exit")
    end
  end

  defp process_exited?(_pid, 0), do: false

  defp process_exited?(pid, attempts) do
    if process_alive?(pid) do
      receive do
      after
        20 -> process_exited?(pid, attempts - 1)
      end
    else
      true
    end
  end

  defp process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end
