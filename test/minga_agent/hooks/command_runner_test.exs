defmodule MingaAgent.Hooks.CommandRunnerTest do
  # Runs real /bin/sh commands through Port, so keep it out of async test runs.
  use ExUnit.Case, async: false

  alias MingaAgent.Hooks.CommandRunner
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.PreToolUsePayload
  alias MingaAgent.Hooks.Result

  @moduletag :heavy

  test "allows when hook exits zero and receives JSON payload on stdin" do
    hook = %Hook{
      event: :pre_tool_use,
      tool_pattern: "shell",
      command:
        "payload=$(cat); case \"$payload\" in *'\"tool_name\":\"shell\"'*) exit 0;; *) echo missing payload >&2; exit 9;; esac"
    }

    payload = PreToolUsePayload.new("tc_1", "shell", %{"command" => "date"})

    assert %Result{status: :allow, stderr: "", exit_status: nil, reason: nil} =
             CommandRunner.run_pre_tool_use(hook, payload)
  end

  test "treats non-zero exit as veto with stderr" do
    hook = %Hook{
      event: :pre_tool_use,
      tool_pattern: "shell",
      command: "echo blocked >&2; exit 4"
    }

    payload = PreToolUsePayload.new("tc_1", "shell", %{"command" => "date"})

    assert %Result{status: :veto, exit_status: 4, reason: {:exit, 4}, stderr: stderr} =
             CommandRunner.run_pre_tool_use(hook, payload)

    assert stderr =~ "blocked"
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

  test "child stdout is discarded and cannot corrupt helper result" do
    command =
      "i=0; while [ \"$i\" -lt 20000 ]; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n'; i=$((i + 1)); done; exit 0"

    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: command, timeout_ms: 2_000}
    payload = PreToolUsePayload.new("tc_1", "shell", %{})

    assert %Result{status: :allow} = CommandRunner.run_pre_tool_use(hook, payload)
  end

  @tag timeout: 2_000
  test "times out by wall clock even when hook keeps writing stderr" do
    hook = %Hook{
      event: :pre_tool_use,
      tool_pattern: "*",
      command: "i=0; while :; do echo tick-$i >&2; i=$((i + 1)); done",
      timeout_ms: 100
    }

    payload = PreToolUsePayload.new("tc_1", "read_file", %{"path" => "README.md"})
    started_ms = System.monotonic_time(:millisecond)

    assert %Result{status: :veto, reason: :timeout, stderr: stderr} =
             CommandRunner.run_pre_tool_use(hook, payload)

    elapsed_ms = System.monotonic_time(:millisecond) - started_ms

    assert stderr =~ "tick-"
    assert stderr =~ "timed out after 100ms"
    assert stderr =~ "killed"
    assert elapsed_ms < 500
  end

  @tag timeout: 2_000
  test "timeout kills the hook shell and its child process group" do
    shell_pid_path = temp_path("shell-pid")
    child_pid_path = temp_path("child-pid")
    grandchild_pid_path = temp_path("grandchild-pid")

    command =
      "echo $$ > #{shell_quote(shell_pid_path)}; " <>
        "((while :; do :; done) & echo $! > #{shell_quote(grandchild_pid_path)}; wait) & " <>
        "echo $! > #{shell_quote(child_pid_path)}; " <>
        "while [ ! -s #{shell_quote(grandchild_pid_path)} ]; do :; done; wait"

    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: command, timeout_ms: 100}
    payload = PreToolUsePayload.new("tc_1", "read_file", %{"path" => "README.md"})

    assert %Result{status: :veto, reason: :timeout} =
             CommandRunner.run_pre_tool_use(hook, payload)

    shell_pid = read_pid!(shell_pid_path)
    child_pid = read_pid!(child_pid_path)
    grandchild_pid = read_pid!(grandchild_pid_path)

    refute_process_alive(shell_pid)
    refute_process_alive(child_pid)
    refute_process_alive(grandchild_pid)

    File.rm(shell_pid_path)
    File.rm(child_pid_path)
    File.rm(grandchild_pid_path)
  end

  test "stderr is bounded and marked truncated" do
    command =
      "i=0; while [ \"$i\" -lt 50000 ]; do printf '0123456789abcdef0123456789abcdef\\n' >&2; i=$((i + 1)); done; exit 7"

    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: command, timeout_ms: 2_000}
    payload = PreToolUsePayload.new("tc_1", "shell", %{})

    assert %Result{status: :veto, exit_status: 7, stderr: stderr} =
             CommandRunner.run_pre_tool_use(hook, payload)

    assert byte_size(stderr) < 70_000
    assert stderr =~ "truncated"
  end

  test "vetoes clearly when helper executable cannot be started" do
    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: "exit 0"}
    payload = PreToolUsePayload.new("tc_1", "shell", %{})
    missing = temp_path("missing-helper")

    assert %Result{status: :veto, reason: {:failed_to_start, _reason}, stderr: stderr} =
             CommandRunner.run_pre_tool_use(hook, payload, helper_path: missing)

    assert stderr =~ "failed to start hook runner"
  end

  test "vetoes clearly when helper returns malformed JSON" do
    helper = fake_helper("malformed-helper", "#!/bin/sh\nprintf 'not json'\n")
    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: "exit 0"}
    payload = PreToolUsePayload.new("tc_secret", "shell", %{"secret" => "do-not-leak"})

    assert %Result{
             status: :veto,
             reason: {:failed_to_start, :malformed_helper_result},
             stderr: stderr
           } =
             CommandRunner.run_pre_tool_use(hook, payload, helper_path: helper)

    assert stderr =~ "malformed hook runner result"
    refute stderr =~ "do-not-leak"

    File.rm(helper)
  end

  @tag timeout: 2_000
  test "guard timeout is absolute even if a broken helper keeps writing stdout" do
    helper =
      fake_helper("noisy-helper", "#!/bin/sh\nexec 2>/dev/null\nwhile :; do printf x; done\n")

    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: "exit 0", timeout_ms: 10}
    payload = PreToolUsePayload.new("tc_1", "shell", %{})
    started_ms = System.monotonic_time(:millisecond)

    assert %Result{status: :veto, reason: {:failed_to_start, :helper_timeout}, stderr: stderr} =
             CommandRunner.run_pre_tool_use(hook, payload, helper_path: helper)

    elapsed_ms = System.monotonic_time(:millisecond) - started_ms

    assert stderr =~ "hook runner timed out after 1010ms"
    assert elapsed_ms < 1_500

    File.rm(helper)
  end

  defp temp_path(label) do
    Path.join(System.tmp_dir!(), "minga-hook-#{label}-#{System.unique_integer([:positive])}")
  end

  defp fake_helper(label, content) do
    path = temp_path(label)
    File.write!(path, content)
    File.chmod!(path, 0o755)
    path
  end

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
