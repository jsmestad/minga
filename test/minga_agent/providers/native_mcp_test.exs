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

  defp drain_llm_tools_messages do
    receive do
      {:llm_tools_before_call_failure, _tool_names} -> drain_llm_tools_messages()
      {:llm_tools_after_call_failure, _tool_names} -> drain_llm_tools_messages()
    after
      0 -> :ok
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

    assert_receive {:llm_tools, tool_names}, @receive_timeout
    assert "builtin_echo" in tool_names
    assert "mcp_local_tools__echo_text" in tool_names
    assert "todo_write" in tool_names
  end

  test "passes tools from two healthy MCP servers to the LLM", %{tmp_dir: dir} do
    test_pid = self()

    client = fn _model, _messages, opts ->
      send(test_pid, {:llm_tools_two_servers, Enum.map(opts[:tools], & &1.name)})

      [ReqLLM.StreamChunk.text("ok"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
      |> build_stream_response()
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

    assert :ok = Native.send_prompt(provider, "hello")
    _events = collect_until_end()

    assert_receive {:llm_tools_two_servers, tool_names}, @receive_timeout
    assert "builtin_echo" in tool_names
    assert "mcp_alpha__echo_text" in tool_names
    assert "mcp_beta__search_code" in tool_names
    assert "todo_write" in tool_names
  end

  test "renames MCP tools that collide with built-in tool names before LLM calls", %{tmp_dir: dir} do
    test_pid = self()

    conflicting_builtin =
      ReqLLM.Tool.new!(
        name: "mcp_local_tools__echo_text",
        description: "Existing tool with MCP-shaped name",
        parameter_schema: %{"type" => "object", "properties" => %{}},
        callback: fn _args -> {:ok, "builtin wins"} end
      )

    client = fn _model, _messages, opts ->
      send(test_pid, {:llm_tools_with_reserved_collision, Enum.map(opts[:tools], & &1.name)})

      [ReqLLM.StreamChunk.text("ok"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
      |> build_stream_response()
    end

    {:ok, provider} =
      start_provider(
        tmp_dir: dir,
        llm_client: client,
        tools: [conflicting_builtin]
      )

    assert :ok = Native.send_prompt(provider, "hello")
    _events = collect_until_end()

    assert_receive {:llm_tools_with_reserved_collision, tool_names}, @receive_timeout
    assert "mcp_local_tools__echo_text" in tool_names
    assert "mcp_local_tools__echo_text_2" in tool_names
    assert length(tool_names) == length(Enum.uniq(tool_names))
  end

  test "invalid MCP config reports an error and keeps builtins available", %{tmp_dir: dir} do
    test_pid = self()

    client = fn _model, _messages, opts ->
      send(test_pid, {:llm_tools_with_invalid_mcp, Enum.map(opts[:tools], & &1.name)})

      [ReqLLM.StreamChunk.text("ok"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
      |> build_stream_response()
    end

    {:ok, provider} =
      start_provider(
        tmp_dir: dir,
        llm_client: client,
        config: %AgentConfig{mcp_servers: [%{name: "Local Tools"}], tool_approval: :none}
      )

    assert_receive {:agent_provider_event, %Event.Error{message: message}}, @receive_timeout
    assert message =~ "MCP config error"
    assert message =~ "command is required"

    assert :ok = Native.send_prompt(provider, "hello")
    _events = collect_until_end()

    assert_receive {:llm_tools_with_invalid_mcp, tool_names}, @receive_timeout
    assert "builtin_echo" in tool_names
    refute "mcp_local_tools__echo_text" in tool_names
    assert "todo_write" in tool_names
  end

  test "one failed MCP server leaves a healthy server and builtins available", %{tmp_dir: dir} do
    test_pid = self()

    client = fn _model, _messages, opts ->
      send(test_pid, {:llm_tools_with_failed_server, Enum.map(opts[:tools], & &1.name)})

      [ReqLLM.StreamChunk.text("ok"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
      |> build_stream_response()
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

    assert_receive {:agent_provider_event, %Event.Error{message: message}}, @receive_timeout
    assert message =~ "MCP server Broken failed to start"

    assert :ok = Native.send_prompt(provider, "hello")
    _events = collect_until_end()

    assert_receive {:llm_tools_with_failed_server, tool_names}, @receive_timeout
    assert "builtin_echo" in tool_names
    assert "mcp_healthy__echo_text" in tool_names
    refute "mcp_broken__echo_text" in tool_names
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

    assert_receive {:mcp_tool_call, "echo-text", %{"text" => "hi"}}, @receive_timeout

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
    assert_receive {:mcp_transport_started, "Local Tools", transport}, @receive_timeout
    FakeTransport.crash(transport)

    assert_receive {:agent_provider_event, %Event.Error{message: message}}, @receive_timeout
    assert message =~ "MCP server Local Tools stopped"

    :sys.get_state(provider)
    assert :ok = Native.send_prompt(provider, "still works")
    events = collect_until_end()

    assert_receive {:llm_tools_after_crash, tool_names}, @receive_timeout
    assert "builtin_echo" in tool_names
    refute "mcp_local_tools__echo_text" in tool_names
    assert Enum.any?(events, &match?(%Event.ToolEnd{name: "builtin_echo", is_error: false}, &1))
  end

  test "provider shutdown stops all MCP transports", %{tmp_dir: dir} do
    {:ok, provider} =
      start_provider(
        tmp_dir: dir,
        config: agent_config([server_config("Alpha"), server_config("Beta")]),
        mcp_transport_opts: [
          tools_by_server: %{
            "Alpha" => [mcp_tool_def("echo-text")],
            "Beta" => [mcp_tool_def("search-code")]
          },
          test_pid: self()
        ]
      )

    assert_receive {:mcp_transport_started, "Alpha", alpha_transport}, @receive_timeout
    assert_receive {:mcp_transport_started, "Beta", beta_transport}, @receive_timeout

    provider_ref = Process.monitor(provider)
    GenServer.stop(provider)

    assert_receive {:DOWN, ^provider_ref, :process, ^provider, :normal}, @receive_timeout
    assert_receive {:mcp_transport_stopped, "Alpha", ^alpha_transport}, @receive_timeout
    assert_receive {:mcp_transport_stopped, "Beta", ^beta_transport}, @receive_timeout
  end

  test "MCP tool failure during a call reports an error and keeps provider usable", %{
    tmp_dir: dir
  } do
    test_pid = self()
    call_count = :counters.new(1, [:atomics])

    client = fn _model, _messages, opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      label =
        if count == 0, do: :llm_tools_before_call_failure, else: :llm_tools_after_call_failure

      send(test_pid, {label, Enum.map(opts[:tools], & &1.name)})

      chunks =
        case count do
          0 ->
            [
              ReqLLM.StreamChunk.tool_call("mcp_local_tools__echo_text", %{"text" => "hi"}, %{
                id: "tc_mcp",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]

          1 ->
            [
              ReqLLM.StreamChunk.tool_call("builtin_echo", %{}, %{id: "tc_builtin", index: 0}),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ]

          _done ->
            [ReqLLM.StreamChunk.text("done"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
        end

      build_stream_response(chunks)
    end

    {:ok, provider} =
      start_provider(
        tmp_dir: dir,
        llm_client: client,
        mcp_transport_opts: [
          tools: [mcp_tool_def()],
          request_errors: %{"echo-text" => :closed},
          test_pid: self()
        ]
      )

    assert :ok = Native.send_prompt(provider, "use failing mcp")
    events = collect_until_end()

    assert Enum.any?(
             events,
             &match?(%Event.ToolEnd{name: "mcp_local_tools__echo_text", is_error: true}, &1)
           )

    assert Enum.any?(events, fn
             %Event.Error{message: message} -> message =~ "MCP server Local Tools stopped"
             _event -> false
           end)

    :sys.get_state(provider)
    drain_llm_tools_messages()
    assert :ok = Native.send_prompt(provider, "still works")
    events = collect_until_end()

    assert_receive {:llm_tools_after_call_failure, tool_names}, @receive_timeout
    assert "builtin_echo" in tool_names
    refute "mcp_local_tools__echo_text" in tool_names
    assert Enum.any?(events, &match?(%Event.AgentEnd{}, &1))
  end

  test "mid-session crash removes only the crashed server tools", %{tmp_dir: dir} do
    test_pid = self()
    call_count = :counters.new(1, [:atomics])

    client = fn _model, _messages, opts ->
      send(test_pid, {:llm_tools_after_one_server_crash, Enum.map(opts[:tools], & &1.name)})
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      chunks =
        if count == 0 do
          [
            ReqLLM.StreamChunk.tool_call("mcp_beta__search_code", %{"text" => "hi"}, %{
              id: "tc_beta",
              index: 0
            }),
            ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
          ]
        else
          [ReqLLM.StreamChunk.text("ok"), ReqLLM.StreamChunk.meta(%{finish_reason: :stop})]
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

    assert_receive {:mcp_transport_started, "Alpha", alpha_transport}, @receive_timeout
    FakeTransport.crash(alpha_transport)

    assert_receive {:agent_provider_event, %Event.Error{message: message}}, @receive_timeout
    assert message =~ "MCP server Alpha stopped"

    :sys.get_state(provider)
    assert :ok = Native.send_prompt(provider, "still works")
    events = collect_until_end()

    assert_receive {:llm_tools_after_one_server_crash, tool_names}, @receive_timeout
    assert "builtin_echo" in tool_names
    refute "mcp_alpha__echo_text" in tool_names
    assert "mcp_beta__search_code" in tool_names
    assert_receive {:mcp_tool_call, "Beta", "search-code", %{"text" => "hi"}}, @receive_timeout

    assert Enum.any?(
             events,
             &match?(%Event.ToolEnd{name: "mcp_beta__search_code", is_error: false}, &1)
           )
  end
end
