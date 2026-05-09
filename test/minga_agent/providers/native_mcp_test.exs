defmodule MingaAgent.Providers.NativeMCPTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Event
  alias MingaAgent.MCP.FakeTransport
  alias MingaAgent.MCP.ServerConfig
  alias MingaAgent.Providers.Native
  alias ReqLLM.StreamResponse.MetadataHandle

  @moduletag :tmp_dir

  defp server_config do
    %ServerConfig{name: "Local Tools", command: "ignored"}
  end

  defp agent_config do
    %AgentConfig{mcp_server: server_config(), tool_approval: :none}
  end

  defp mcp_tool_def do
    %{
      "name" => "echo-text",
      "description" => "Echo text through MCP",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      }
    }
  end

  defp builtin_tool do
    ReqLLM.Tool.new!(
      name: "builtin_echo",
      description: "Builtin echo",
      parameter_schema: %{"type" => "object", "properties" => %{}},
      callback: fn _args -> {:ok, "builtin ok"} end
    )
  end

  defp start_provider(opts) do
    defaults = [
      subscriber: self(),
      model: "anthropic:claude-sonnet-4-20250514",
      project_root: opts[:tmp_dir] || System.tmp_dir!(),
      tools: [builtin_tool()],
      config: agent_config(),
      mcp_transport: FakeTransport,
      mcp_transport_opts: [tools: [mcp_tool_def()], test_pid: self()]
    ]

    Native.start_link(Keyword.merge(defaults, opts))
  end

  defp build_stream_response(chunks, usage \\ %{}) do
    {:ok, handle} =
      MetadataHandle.start_link(fn ->
        %{usage: usage, finish_reason: :stop}
      end)

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
      1_000 -> Enum.reverse(acc)
    end
  end

  test "passes MCP tools and builtins to the LLM", %{tmp_dir: dir} do
    test_pid = self()

    client = fn _model, _messages, opts ->
      send(test_pid, {:llm_tools, Enum.map(opts[:tools], & &1.name)})

      [ReqLLM.StreamChunk.text("ok"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
      |> build_stream_response()
    end

    {:ok, provider} = start_provider(tmp_dir: dir, llm_client: client)
    assert :ok = Native.send_prompt(provider, "hello")
    _events = collect_until_end()

    assert_receive {:llm_tools, tool_names}
    assert "builtin_echo" in tool_names
    assert "mcp_local_tools__echo_text" in tool_names
    assert "todo_write" in tool_names
  end

  test "MCP tool call round-trips to the server", %{tmp_dir: dir} do
    call_count = :counters.new(1, [:atomics])

    client = fn _model, _messages, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      chunks =
        if count == 0 do
          [
            ReqLLM.StreamChunk.tool_call("mcp_local_tools__echo_text", %{"text" => "hi"}, %{
              id: "tc_1",
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
    assert :ok = Native.send_prompt(provider, "use mcp")
    events = collect_until_end()

    assert_receive {:mcp_tool_call, "echo-text", %{"text" => "hi"}}

    assert Enum.any?(
             events,
             &match?(%Event.ToolEnd{name: "mcp_local_tools__echo_text", is_error: false}, &1)
           )
  end

  test "MCP failure reports an error and leaves builtins available", %{tmp_dir: dir} do
    test_pid = self()
    call_count = :counters.new(1, [:atomics])

    client = fn _model, _messages, opts ->
      send(test_pid, {:llm_tools_after_crash, Enum.map(opts[:tools], & &1.name)})
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      chunks =
        if count == 0 do
          [
            ReqLLM.StreamChunk.tool_call("builtin_echo", %{}, %{id: "tc_builtin", index: 0}),
            ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
          ]
        else
          [ReqLLM.StreamChunk.text("ok"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
        end

      build_stream_response(chunks)
    end

    {:ok, provider} = start_provider(tmp_dir: dir, llm_client: client)
    assert_receive {:mcp_transport_started, transport}
    FakeTransport.crash(transport)

    assert_receive {:agent_provider_event, %Event.Error{message: message}}
    assert message =~ "MCP server Local Tools stopped"

    :sys.get_state(provider)
    assert :ok = Native.send_prompt(provider, "still works")
    events = collect_until_end()

    assert_receive {:llm_tools_after_crash, tool_names}
    assert "builtin_echo" in tool_names
    refute "mcp_local_tools__echo_text" in tool_names
    assert Enum.any?(events, &match?(%Event.ToolEnd{name: "builtin_echo", is_error: false}, &1))
  end
end
