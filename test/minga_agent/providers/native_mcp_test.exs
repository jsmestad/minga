defmodule MingaAgent.Providers.NativeMCPTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Event
  alias MingaAgent.MCP.FakeTransport
  alias MingaAgent.MCP.ServerConfig
  alias MingaAgent.Providers.Native
  alias ReqLLM.StreamResponse.MetadataHandle

  @moduletag :tmp_dir
  @receive_timeout 5_000

  defp server_config(name \\ "Local Tools") do
    %ServerConfig{name: name, command: "ignored"}
  end

  defp agent_config(servers \\ [server_config()]) do
    %AgentConfig{mcp_servers: servers, tool_approval: :none}
  end

  defp mcp_tool_def(name \\ "echo-text") do
    %{
      "name" => name,
      "description" => "MCP tool #{name}",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => []
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
      mcp_enabled?: true,
      mcp_transport: FakeTransport,
      mcp_transport_opts: [tools: [mcp_tool_def()], test_pid: self()],
      skip_api_key_env: true
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

  test "enabled MCP exposes only lightweight meta-tools to the LLM", %{tmp_dir: dir} do
    test_pid = self()

    client = fn _model, _messages, opts ->
      send(test_pid, {:llm_tools, Enum.map(opts[:tools], & &1.name)})

      [ReqLLM.StreamChunk.text("ok"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
      |> build_stream_response()
    end

    {:ok, provider} = start_provider(tmp_dir: dir, llm_client: client)
    assert :ok = Native.send_prompt(provider, "hello")
    _events = collect_until_end()

    assert_receive {:llm_tools, tool_names}, @receive_timeout
    assert "builtin_echo" in tool_names
    assert "list_mcp_tools" in tool_names
    assert "call_mcp_tool" in tool_names
    refute "mcp_local_tools__echo_text" in tool_names
    assert "todo_write" in tool_names
    refute_receive {:mcp_transport_started, "Local Tools", _transport}, 50
  end

  test "disabled MCP extension exposes no MCP tools", %{tmp_dir: dir} do
    test_pid = self()

    client = fn _model, _messages, opts ->
      send(test_pid, {:llm_tools, Enum.map(opts[:tools], & &1.name)})

      [ReqLLM.StreamChunk.text("ok"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
      |> build_stream_response()
    end

    {:ok, provider} = start_provider(tmp_dir: dir, llm_client: client, mcp_enabled?: false)
    assert :ok = Native.send_prompt(provider, "hello")
    _events = collect_until_end()

    assert_receive {:llm_tools, tool_names}, @receive_timeout
    refute "list_mcp_tools" in tool_names
    refute "call_mcp_tool" in tool_names
    refute_receive {:mcp_transport_started, "Local Tools", _transport}, 50
  end

  test "list_mcp_tools starts servers lazily and returns one-line descriptions", %{tmp_dir: dir} do
    call_count = :counters.new(1, [:atomics])

    client = fn _model, _messages, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      chunks =
        if count == 0 do
          [
            ReqLLM.StreamChunk.tool_call("list_mcp_tools", %{}, %{id: "tc_list", index: 0}),
            ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
          ]
        else
          [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
        end

      build_stream_response(chunks)
    end

    {:ok, provider} = start_provider(tmp_dir: dir, llm_client: client)
    assert :ok = Native.send_prompt(provider, "discover mcp")
    events = collect_until_end()

    assert_receive {:mcp_transport_started, "Local Tools", _transport}, @receive_timeout

    assert {:ok, %{mcp_status: [%{"name" => "Local Tools", "status" => "running"}]}} =
             Native.get_state(provider)

    assert Enum.any?(events, fn
             %Event.ToolEnd{name: "list_mcp_tools", result: result, is_error: false} ->
               result =~ "echo-text" and result =~ "MCP tool echo-text"

             _event ->
               false
           end)
  end

  test "call_mcp_tool starts the selected server lazily and round-trips", %{tmp_dir: dir} do
    call_count = :counters.new(1, [:atomics])

    client = fn _model, _messages, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      chunks =
        if count == 0 do
          [
            ReqLLM.StreamChunk.tool_call(
              "call_mcp_tool",
              %{
                "server" => "Local Tools",
                "tool" => "echo-text",
                "arguments" => %{"text" => "hi"}
              },
              %{id: "tc_call", index: 0}
            ),
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

    assert_receive {:mcp_transport_started, "Local Tools", _transport}, @receive_timeout

    assert_receive {:mcp_tool_call, "Local Tools", "echo-text", %{"text" => "hi"}},
                   @receive_timeout

    assert Enum.any?(events, &match?(%Event.ToolEnd{name: "call_mcp_tool", is_error: false}, &1))
  end

  test "one failed server does not prevent healthy server discovery", %{tmp_dir: dir} do
    call_count = :counters.new(1, [:atomics])

    client = fn _model, _messages, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      chunks =
        if count == 0 do
          [
            ReqLLM.StreamChunk.tool_call("list_mcp_tools", %{}, %{id: "tc_list", index: 0}),
            ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
          ]
        else
          [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
        end

      build_stream_response(chunks)
    end

    {:ok, provider} =
      start_provider(
        tmp_dir: dir,
        llm_client: client,
        config: agent_config([server_config("Broken"), server_config("Healthy")]),
        mcp_transport_opts: [
          tools_by_server: %{"Healthy" => [mcp_tool_def("echo-text")]},
          request_errors_by_server: %{"Broken" => %{"tools/list" => :boom}},
          test_pid: self()
        ]
      )

    assert :ok = Native.send_prompt(provider, "discover mcp")
    events = collect_until_end()

    assert Enum.any?(events, fn
             %Event.Error{message: message} -> message =~ "MCP server Broken failed to start"
             _event -> false
           end)

    assert_receive {:mcp_transport_started, "Healthy", _transport}, @receive_timeout

    assert Enum.any?(events, fn
             %Event.ToolEnd{name: "list_mcp_tools", result: result, is_error: false} ->
               result =~ "echo-text"

             _event ->
               false
           end)
  end

  test "list_mcp_tools returns a tool error when every configured server fails", %{tmp_dir: dir} do
    call_count = :counters.new(1, [:atomics])

    client = fn _model, _messages, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      chunks =
        if count == 0 do
          [
            ReqLLM.StreamChunk.tool_call("list_mcp_tools", %{}, %{id: "tc_list", index: 0}),
            ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
          ]
        else
          [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
        end

      build_stream_response(chunks)
    end

    {:ok, provider} =
      start_provider(
        tmp_dir: dir,
        llm_client: client,
        config: agent_config([server_config("Broken")]),
        mcp_transport_opts: [
          request_errors_by_server: %{"Broken" => %{"tools/list" => :boom}},
          test_pid: self()
        ]
      )

    assert :ok = Native.send_prompt(provider, "discover mcp")
    events = collect_until_end()

    assert Enum.any?(events, fn
             %Event.ToolEnd{name: "list_mcp_tools", result: result, is_error: true} ->
               result =~ "MCP servers failed to start" and result =~ "Broken"

             _event ->
               false
           end)

    assert {:ok, %{mcp_status: [%{"name" => "Broken", "status" => "errored", "error" => error}]}} =
             Native.get_state(provider)

    assert error =~ "MCP server Broken failed to start"
  end

  test "provider shutdown stops lazily started MCP transports", %{tmp_dir: dir} do
    call_count = :counters.new(1, [:atomics])

    client = fn _model, _messages, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      chunks =
        if count == 0 do
          [
            ReqLLM.StreamChunk.tool_call("list_mcp_tools", %{}, %{id: "tc_list", index: 0}),
            ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
          ]
        else
          [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
        end

      build_stream_response(chunks)
    end

    {:ok, provider} =
      start_provider(
        tmp_dir: dir,
        llm_client: client,
        config: agent_config([server_config("Alpha"), server_config("Beta")]),
        mcp_transport_opts: [
          tools_by_server: %{
            "Alpha" => [mcp_tool_def("echo-text")],
            "Beta" => [mcp_tool_def("search-code")]
          },
          test_pid: self()
        ]
      )

    assert :ok = Native.send_prompt(provider, "discover mcp")
    _events = collect_until_end()
    assert_receive {:mcp_transport_started, "Alpha", alpha_transport}, @receive_timeout
    assert_receive {:mcp_transport_started, "Beta", beta_transport}, @receive_timeout

    provider_ref = Process.monitor(provider)
    GenServer.stop(provider)

    assert_receive {:DOWN, ^provider_ref, :process, ^provider, :normal}, @receive_timeout
    assert_receive {:mcp_transport_stopped, "Alpha", ^alpha_transport}, @receive_timeout
    assert_receive {:mcp_transport_stopped, "Beta", ^beta_transport}, @receive_timeout
  end
end
