defmodule MingaAgent.Providers.NativeHooksTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Event
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.Result
  alias MingaAgent.Providers.Native
  alias ReqLLM.StreamResponse.MetadataHandle

  @moduletag :tmp_dir

  test "PreToolUse veto prevents native provider tool execution and emits stderr", %{tmp_dir: dir} do
    test_pid = self()
    call_count = :counters.new(1, [:atomics])

    client = fn _model, _messages, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      chunks =
        if count == 0 do
          [
            ReqLLM.StreamChunk.tool_call("shell", %{"command" => "date"}, %{
              id: "tc_hook",
              index: 0
            }),
            ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
          ]
        else
          [
            ReqLLM.StreamChunk.text("handled hook veto"),
            ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
          ]
        end

      build_stream_response(chunks)
    end

    tool =
      ReqLLM.Tool.new!(
        name: "shell",
        description: "fake shell",
        parameter_schema: %{},
        callback: fn _args ->
          send(test_pid, :tool_callback_ran)
          {:ok, "should not run"}
        end
      )

    hook = %Hook{event: :pre_tool_use, tool_pattern: "shell", command: "policy"}
    config = %AgentConfig{tool_approval: :none, agent_hooks: [hook]}

    hook_runner = fn ^hook, payload ->
      send(test_pid, {:hook_payload, payload.tool_call_id, payload.tool_name, payload.arguments})
      Result.veto(hook, "blocked by policy", {:exit, 7})
    end

    {:ok, pid} =
      Native.start_link(
        subscriber: self(),
        model: "anthropic:claude-sonnet-4-20250514",
        project_root: dir,
        tools: [tool],
        llm_client: client,
        config: config,
        hook_runner: hook_runner
      )

    assert :ok = Native.send_prompt(pid, "run shell")

    assert_receive {:hook_payload, "tc_hook", "shell", %{"command" => "date"}}, 2_000

    events = collect_run_events()
    refute_received :tool_callback_ran

    assert %Event.Error{message: error_message} = Enum.find(events, &match?(%Event.Error{}, &1))
    assert error_message =~ "blocked by policy"

    assert %Event.ToolEnd{is_error: true, result: result} =
             Enum.find(events, &match?(%Event.ToolEnd{}, &1))

    assert result =~ "blocked by policy"
  end

  defp build_stream_response(chunks) do
    {:ok, handle} = MetadataHandle.start_link(fn -> %{usage: %{}, finish_reason: :stop} end)

    stream_response = %ReqLLM.StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: elem(ReqLLM.model("anthropic:claude-sonnet-4-20250514"), 1),
      context: ReqLLM.Context.new()
    }

    {:ok, stream_response}
  end

  # Waits for a full agent run up to the terminal AgentEnd, using an overall
  # deadline instead of an inter-event silence gap so a slow event gap under CI
  # load can never silently truncate the run. See the identical helper in
  # native_test.exs for the full rationale.
  @full_run_deadline_ms 10_000

  defp collect_run_events(deadline_ms \\ @full_run_deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    collect_run_events_acc([], deadline, deadline_ms)
  end

  defp collect_run_events_acc(acc, deadline, deadline_ms) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:agent_provider_event, %Event.AgentEnd{} = event} ->
        Enum.reverse([event | acc])

      {:agent_provider_event, event} ->
        collect_run_events_acc([event | acc], deadline, deadline_ms)
    after
      timeout ->
        flunk("""
        collect_run_events/1 timed out after #{deadline_ms}ms without an AgentEnd.
        Collected #{length(acc)} event(s): #{inspect(Enum.reverse(acc))}
        """)
    end
  end
end
