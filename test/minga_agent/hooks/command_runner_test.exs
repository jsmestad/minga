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

  test "times out long-running hooks and returns a clear veto" do
    hook = %Hook{event: :pre_tool_use, tool_pattern: "*", command: "sleep 1", timeout_ms: 20}
    payload = PreToolUsePayload.new("tc_1", "read_file", %{"path" => "README.md"})

    assert %Result{status: :veto, reason: :timeout, stderr: stderr} =
             CommandRunner.run_pre_tool_use(hook, payload)

    assert stderr =~ "timed out after 20ms"
    assert stderr =~ "killed"
  end
end
