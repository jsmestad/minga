defmodule MingaAgent.Hooks.DispatcherTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Hooks.Dispatcher
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.PostToolUsePayload
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

  # ── PostToolUse ──────────────────────────────────────────────────────────────

  test "PostToolUse hooks run after tool execution" do
    test_pid = self()
    hook = post_hook("read_file")
    payload = PostToolUsePayload.new("tc_post_1", "read_file", %{}, "result", false)

    runner = fn received_hook, _payload_map ->
      send(test_pid, :post_hook_ran)
      Result.allow(received_hook)
    end

    assert :ok =
             Dispatcher.post_tool_use([hook], PostToolUsePayload.to_map(payload), runner: runner)

    assert_receive :post_hook_ran
  end

  test "PostToolUse veto is ignored (notification-only)" do
    hook = post_hook("*")
    payload = PostToolUsePayload.new("tc_post_2", "shell", %{}, "result", false)

    runner = fn received_hook, _payload_map ->
      Result.veto(received_hook, "tried to block", {:exit, 1})
    end

    assert :ok =
             Dispatcher.post_tool_use([hook], PostToolUsePayload.to_map(payload), runner: runner)
  end

  test "PostToolUse non-matching hooks do not run" do
    test_pid = self()
    hook = post_hook("write_file")
    payload = PostToolUsePayload.new("tc_post_3", "read_file", %{}, "result", false)

    runner = fn received_hook, _payload_map ->
      send(test_pid, :unexpected)
      Result.allow(received_hook)
    end

    Dispatcher.post_tool_use([hook], PostToolUsePayload.to_map(payload), runner: runner)
    refute_receive :unexpected, 20
  end

  test "PostToolUse broadcasts lifecycle events" do
    Minga.Events.subscribe(:agent_hook)

    hook = post_hook("shell")
    payload = PostToolUsePayload.new("tc_post_event", "shell", %{"cmd" => "ls"}, "ok", false)

    runner = fn received_hook, _payload_map -> Result.allow(received_hook) end

    Dispatcher.post_tool_use([hook], PostToolUsePayload.to_map(payload), runner: runner)

    assert_receive {:minga_event, :agent_hook,
                    %Minga.Events.AgentHookEvent{
                      event: "PostToolUse",
                      phase: :started,
                      tool_name: "shell",
                      tool_call_id: "tc_post_event"
                    }}

    assert_receive {:minga_event, :agent_hook,
                    %Minga.Events.AgentHookEvent{
                      event: "PostToolUse",
                      phase: :allowed,
                      tool_name: "shell",
                      tool_call_id: "tc_post_event"
                    }}
  end

  test "PostToolUse normalization accepts PostToolUse event name variants" do
    assert {:ok, %Hook{event: :post_tool_use}} =
             Hook.normalize(%{event: "PostToolUse", tool: "shell", command: "echo ok"})

    assert {:ok, %Hook{event: :post_tool_use}} =
             Hook.normalize(%{event: :post_tool_use, tool: "*", command: "echo ok"})
  end

  # ── generic dispatch ───────────────────────────────────────────────────────

  test "dispatch/4 with veto_capable: false ignores veto and continues" do
    test_pid = self()
    hook1 = %Hook{event: :post_tool_use, tool_pattern: "*", command: "echo first"}
    hook2 = %Hook{event: :post_tool_use, tool_pattern: "*", command: "echo second"}

    runner = fn hook, _map ->
      case hook.command do
        "echo first" ->
          send(test_pid, :first)
          Result.veto(hook, "nope", {:exit, 1})

        "echo second" ->
          send(test_pid, :second)
          Result.allow(hook)
      end
    end

    payload_map = %{"tool_name" => "shell", "tool_call_id" => "tc_gen"}

    assert :ok =
             Dispatcher.dispatch(:post_tool_use, [hook1, hook2], payload_map,
               runner: runner,
               veto_capable: false
             )

    assert_receive :first
    assert_receive :second
  end

  # ── SessionStart / SessionEnd ────────────────────────────────────────────────

  test "SessionStart hooks run and are notification-only" do
    test_pid = self()
    hook = session_hook(:session_start)

    runner = fn received_hook, _payload_map ->
      send(test_pid, :session_start_ran)
      Result.allow(received_hook)
    end

    payload = %{"event" => "SessionStart", "session_id" => "s1"}
    assert :ok = Dispatcher.session_start([hook], payload, runner: runner)
    assert_receive :session_start_ran
  end

  test "SessionEnd hooks run and are notification-only" do
    test_pid = self()
    hook = session_hook(:session_end)

    runner = fn received_hook, _payload_map ->
      send(test_pid, :session_end_ran)
      Result.allow(received_hook)
    end

    payload = %{"event" => "SessionEnd", "session_id" => "s2", "reason" => "normal"}
    assert :ok = Dispatcher.session_end([hook], payload, runner: runner)
    assert_receive :session_end_ran
  end

  test "SessionStart veto is ignored" do
    hook = session_hook(:session_start)

    runner = fn received_hook, _payload_map ->
      Result.veto(received_hook, "blocked", {:exit, 1})
    end

    payload = %{"event" => "SessionStart", "session_id" => "s3"}
    assert :ok = Dispatcher.session_start([hook], payload, runner: runner)
  end

  # ── Stop ────────────────────────────────────────────────────────────────────

  test "Stop hooks run and are notification-only" do
    test_pid = self()
    hook = session_hook(:stop)

    runner = fn received_hook, _payload_map ->
      send(test_pid, :stop_ran)
      Result.allow(received_hook)
    end

    payload = %{"event" => "Stop", "session_id" => "s_stop", "reason" => "end_turn"}
    assert :ok = Dispatcher.stop([hook], payload, runner: runner)
    assert_receive :stop_ran
  end

  test "Stop veto is ignored" do
    hook = session_hook(:stop)

    runner = fn received_hook, _payload_map ->
      Result.veto(received_hook, "blocked", {:exit, 1})
    end

    payload = %{"event" => "Stop", "session_id" => "s_stop2"}
    assert :ok = Dispatcher.stop([hook], payload, runner: runner)
  end

  # ── Normalization ──────────────────────────────────────────────────────────

  test "Session hooks do not require tool_pattern" do
    assert {:ok, %Hook{event: :session_start, tool_pattern: nil}} =
             Hook.normalize(%{event: "SessionStart", command: "echo start"})

    assert {:ok, %Hook{event: :session_end, tool_pattern: nil}} =
             Hook.normalize(%{event: "SessionEnd", command: "echo end"})
  end

  defp hook(pattern) do
    %Hook{event: :pre_tool_use, tool_pattern: pattern, command: "echo checking >&2"}
  end

  defp post_hook(pattern) do
    %Hook{event: :post_tool_use, tool_pattern: pattern, command: "echo post >&2"}
  end

  defp session_hook(event) do
    %Hook{event: event, tool_pattern: nil, command: "echo hook >&2"}
  end
end
