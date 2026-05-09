defmodule MingaAgent.Hooks.DispatcherTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Hooks.Dispatcher
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.PreToolUsePayload
  alias MingaAgent.Hooks.Result

  test "matching PreToolUse hook runs with stable payload fields before callback boundary" do
    test_pid = self()
    hook = hook("read_file")
    payload = PreToolUsePayload.new("tc_1", "read_file", %{"path" => "README.md"})

    runner = fn received_hook, received_payload ->
      send(test_pid, {:hook_ran, received_hook, received_payload})
      Result.allow(received_hook)
    end

    assert :ok = Dispatcher.pre_tool_use([hook], payload, runner: runner)

    assert_receive {:hook_ran, ^hook, %PreToolUsePayload{} = received_payload}
    assert received_payload.event == "PreToolUse"
    assert received_payload.tool_call_id == "tc_1"
    assert received_payload.tool_name == "read_file"
    assert received_payload.arguments == %{"path" => "README.md"}
  end

  test "non-matching hooks do not run" do
    test_pid = self()
    hook = hook("write_file")
    payload = PreToolUsePayload.new("tc_1", "read_file", %{})

    runner = fn received_hook, _payload ->
      send(test_pid, {:unexpected_hook, received_hook})
      Result.allow(received_hook)
    end

    assert :ok = Dispatcher.pre_tool_use([hook], payload, runner: runner)
    refute_receive {:unexpected_hook, _}, 20
  end

  test "glob patterns match tool names" do
    test_pid = self()
    hook = hook("*_file")
    payload = PreToolUsePayload.new("tc_1", "read_file", %{})

    runner = fn received_hook, _payload ->
      send(test_pid, :hook_ran)
      Result.allow(received_hook)
    end

    assert :ok = Dispatcher.pre_tool_use([hook], payload, runner: runner)
    assert_receive :hook_ran
  end

  test "first veto short-circuits later hooks" do
    test_pid = self()
    first = hook("*")
    second = hook("*")
    payload = PreToolUsePayload.new("tc_1", "shell", %{"command" => "rm -rf /tmp/nope"})

    runner = fn
      ^first, _payload ->
        send(test_pid, :first_hook)
        Result.veto(first, "blocked by policy", {:exit, 2})

      ^second, _payload ->
        send(test_pid, :second_hook)
        Result.allow(second)
    end

    assert {:error, %Result{status: :veto, stderr: "blocked by policy"}} =
             Dispatcher.pre_tool_use([first, second], payload, runner: runner)

    assert_receive :first_hook
    refute_receive :second_hook, 20
  end

  test "broadcasts typed hook lifecycle events" do
    Minga.Events.subscribe(:agent_hook)

    hook = hook("read_file")
    payload = PreToolUsePayload.new("tc_typed_event", "read_file", %{"path" => "README.md"})

    runner = fn received_hook, _payload -> Result.allow(received_hook) end

    assert :ok = Dispatcher.pre_tool_use([hook], payload, runner: runner)

    assert_receive {:minga_event, :agent_hook,
                    %Minga.Events.AgentHookEvent{
                      event: "PreToolUse",
                      phase: :started,
                      tool_call_id: "tc_typed_event",
                      tool_name: "read_file",
                      tool_pattern: "read_file"
                    }}

    assert_receive {:minga_event, :agent_hook,
                    %Minga.Events.AgentHookEvent{
                      event: "PreToolUse",
                      phase: :allowed,
                      tool_call_id: "tc_typed_event",
                      tool_name: "read_file",
                      tool_pattern: "read_file"
                    }}
  end

  test "normalization defaults timeout to 30 seconds" do
    assert {:ok, %Hook{timeout_ms: 30_000}} =
             Hook.normalize(%{event: "PreToolUse", tool: "shell", command: "echo checking >&2"})
  end

  test "normalization rejects malformed keyword-list declarations" do
    assert {:error, "agent hook must be a map or keyword list"} = Hook.normalize(["bad"])
  end

  defp hook(pattern) do
    %Hook{event: :pre_tool_use, tool_pattern: pattern, command: "echo checking >&2"}
  end
end
