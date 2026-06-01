defmodule MingaAgent.Providers.NativeToolExecutorTest do
  # async: false because these tests register source-owned tools in the global agent tool registry.
  use ExUnit.Case, async: false

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Event
  alias MingaAgent.Hooks.Hook
  alias MingaAgent.Hooks.Result
  alias MingaAgent.Providers.Native
  alias MingaAgent.Tool.Registry, as: ToolRegistry
  alias MingaAgent.Tool.Spec
  alias ReqLLM.StreamResponse.MetadataHandle

  @source {:extension, :native_tool_executor_test}
  @receive_timeout 5_000

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "minga-native-tool-executor-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    ToolRegistry.unregister_source(@source)

    on_exit(fn ->
      ToolRegistry.unregister_source(@source)
      File.rm_rf!(dir)
    end)

    %{tmp_dir: dir}
  end

  defp start_provider(opts) do
    defaults = [
      subscriber: self(),
      model: "anthropic:claude-sonnet-4-20250514",
      project_root: opts[:tmp_dir] || System.tmp_dir!(),
      tools: nil,
      config: %AgentConfig{tool_approval: :none},
      skip_api_key_env: true
    ]

    Native.start_link(Keyword.merge(defaults, opts))
  end

  defp build_stream_response(chunks, usage \\ %{}) do
    {:ok, handle} = MetadataHandle.start_link(fn -> %{usage: usage, finish_reason: :stop} end)

    stream_response = %ReqLLM.StreamResponse{
      stream: chunks,
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: elem(ReqLLM.model("anthropic:claude-sonnet-4-20250514"), 1),
      context: ReqLLM.Context.new()
    }

    {:ok, stream_response}
  end

  defp collect_until_end(acc \\ []) do
    receive do
      {:agent_provider_event, %Event.AgentEnd{} = event} -> Enum.reverse([event | acc])
      {:agent_provider_event, event} -> collect_until_end([event | acc])
    after
      @receive_timeout -> Enum.reverse(acc)
    end
  end

  defp register_temp_tool(name, callback) do
    spec =
      Spec.new!(
        source: @source,
        name: name,
        description: "Temp registered tool",
        parameter_schema: %{"type" => "object", "properties" => %{}},
        category: :custom,
        approval_level: :auto,
        capabilities: [],
        context_requirements: [],
        build: fn _context -> callback end
      )

    assert :ok = ToolRegistry.register(spec)
    spec
  end

  test "native provider exposes registry-backed tools to the model", %{tmp_dir: dir} do
    register_temp_tool("temp_echo", fn args -> {:ok, "temp #{args["msg"]}"} end)
    test_pid = self()

    client = fn _model, _messages, opts ->
      send(test_pid, {:llm_tools, Enum.map(opts[:tools], & &1.name)})

      build_stream_response([
        ReqLLM.StreamChunk.text("done"),
        ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
      ])
    end

    {:ok, provider} = start_provider(tmp_dir: dir, llm_client: client)
    assert :ok = Native.send_prompt(provider, "hello")
    _events = collect_until_end()

    assert_receive {:llm_tools, tool_names}, @receive_timeout
    assert "read_file" in tool_names
    assert "temp_echo" in tool_names
  end

  test "removed registry-backed tool in a pending model response fails safe", %{tmp_dir: dir} do
    register_temp_tool("temp_removed", fn _args -> {:ok, "should not run"} end)
    test_pid = self()
    calls = :counters.new(1, [:atomics])

    client = fn _model, _messages, opts ->
      count = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)

      if count == 0 do
        send(test_pid, {:llm_tools, self(), Enum.map(opts[:tools], & &1.name)})

        receive do
          :continue_removed_tool -> :ok
        after
          @receive_timeout -> flunk("timed out waiting to continue removed-tool response")
        end

        build_stream_response([
          ReqLLM.StreamChunk.tool_call("temp_removed", %{}, %{id: "tc_removed", index: 0}),
          ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
        ])
      else
        build_stream_response([
          ReqLLM.StreamChunk.text("done"),
          ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
        ])
      end
    end

    {:ok, provider} = start_provider(tmp_dir: dir, llm_client: client)
    assert :ok = Native.send_prompt(provider, "use removed tool")

    assert_receive {:llm_tools, task_pid, tool_names}, @receive_timeout
    assert "temp_removed" in tool_names
    ToolRegistry.unregister_source(@source)
    send(task_pid, :continue_removed_tool)

    events = collect_until_end()

    assert Enum.any?(events, fn
             %Event.ToolEnd{name: "temp_removed", result: result, is_error: true} ->
               result =~ "not found"

             _event ->
               false
           end)
  end

  test "registry-backed shell keeps native streaming ToolUpdate events", %{tmp_dir: dir} do
    calls = :counters.new(1, [:atomics])

    client = fn _model, _messages, _opts ->
      count = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)

      chunks =
        if count == 0 do
          [
            ReqLLM.StreamChunk.tool_call("shell", %{"command" => "printf streaming-ok"}, %{
              id: "tc_shell",
              index: 0
            }),
            ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
          ]
        else
          [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
        end

      build_stream_response(chunks)
    end

    {:ok, provider} = start_provider(tmp_dir: dir, llm_client: client)
    assert :ok = Native.send_prompt(provider, "run shell")
    events = collect_until_end()

    assert Enum.any?(events, fn
             %Event.ToolUpdate{tool_call_id: "tc_shell", name: "shell", partial_result: chunk} ->
               chunk =~ "streaming-ok"

             _event ->
               false
           end)

    assert Enum.any?(events, &match?(%Event.ToolEnd{name: "shell", is_error: false}, &1))
  end

  test "native registry-backed execution runs the same pre-tool hook payload as the executor", %{
    tmp_dir: dir
  } do
    register_temp_tool("temp_hooked", fn args -> {:ok, "hooked #{args["value"]}"} end)
    test_pid = self()
    hook = %Hook{event: :pre_tool_use, tool_pattern: "temp_hooked", command: "policy"}

    hook_runner = fn ^hook, payload ->
      send(test_pid, {:hook_ran, payload.tool_name, payload.arguments})
      Result.allow(hook)
    end

    calls = :counters.new(1, [:atomics])

    client = fn _model, _messages, _opts ->
      count = :counters.get(calls, 1)
      :counters.add(calls, 1, 1)

      chunks =
        if count == 0 do
          [
            ReqLLM.StreamChunk.tool_call("temp_hooked", %{"value" => "ok"}, %{
              id: "tc_hook",
              index: 0
            }),
            ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
          ]
        else
          [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
        end

      build_stream_response(chunks)
    end

    config = %AgentConfig{tool_approval: :none, agent_hooks: [hook]}

    {:ok, provider} =
      start_provider(tmp_dir: dir, llm_client: client, config: config, hook_runner: hook_runner)

    assert :ok = Native.send_prompt(provider, "use hook")
    events = collect_until_end()

    assert_receive {:hook_ran, "temp_hooked", %{"value" => "ok"}}, @receive_timeout
    assert Enum.any?(events, &match?(%Event.ToolEnd{name: "temp_hooked", is_error: false}, &1))
  end
end
