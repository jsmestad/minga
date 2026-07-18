defmodule MingaAgent.SessionProviderErrorTest do
  use Minga.Test.SessionCase, async: true

  describe "MCP crash handling" do
    @tag :tmp_dir
    test "adds a system message and can still run a builtin tool", %{tmp_dir: dir} do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      llm_client = fn _model, _messages, opts ->
        send(test_pid, {:session_mcp_tools, Enum.map(opts[:tools], & &1.name)})
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        chunks =
          case count do
            0 ->
              [
                ReqLLM.StreamChunk.tool_call("list_mcp_tools", %{}, %{id: "tc_list", index: 0}),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            1 ->
              [
                ReqLLM.StreamChunk.text("listed"),
                ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
              ]

            2 ->
              [
                ReqLLM.StreamChunk.tool_call("builtin_echo", %{}, %{id: "tc_builtin", index: 0}),
                ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
              ]

            _done ->
              [
                ReqLLM.StreamChunk.text("still works"),
                ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
              ]
          end

        mcp_session_stream(chunks)
      end

      session =
        start_test_session(
          provider: Native,
          provider_opts: [
            model: "anthropic:claude-sonnet-4-20250514",
            project_root: dir,
            tools: [mcp_session_builtin_tool()],
            config: %MingaAgent.Config{
              mcp_servers: [%ServerConfig{name: "Local Tools", command: "ignored"}],
              tool_approval: :none
            },
            mcp_enabled?: true,
            mcp_transport: FakeTransport,
            mcp_transport_opts: [
              tools: [%{"name" => "echo-text", "inputSchema" => %{"type" => "object"}}],
              test_pid: self()
            ],
            llm_client: llm_client
          ]
        )

      Session.subscribe(session)
      _provider = Session.get_provider(session)

      assert :ok = Session.send_prompt(session, "discover mcp")
      assert_receive {:mcp_transport_started, "Local Tools", transport}, @event_timeout
      await_turn_complete()

      FakeTransport.crash(transport)

      assert_receive {:agent_event, ^session, {:error, message}}, @event_timeout
      assert message =~ "MCP server Local Tools stopped"
      assert Enum.any?(Session.messages(session), &match?({:system, _text, :error}, &1))

      assert :ok = Session.send_prompt(session, "continue")
      await_turn_complete()
      assert_receive {:session_mcp_tools, tool_names}, @event_timeout
      assert "builtin_echo" in tool_names
      assert "list_mcp_tools" in tool_names
      assert "call_mcp_tool" in tool_names
      refute "mcp_local_tools__echo_text" in tool_names

      assert Enum.any?(Session.messages(session), fn
               {:tool_call, %{name: "builtin_echo", status: :complete, is_error: false}} -> true
               _ -> false
             end)
    end
  end

  describe "provider error presentation" do
    test "openai codex auth failures suggest /login instead of /auth openai_codex" do
      session = start_subscribed_session()

      send_provider_event(
        session,
        %Event.Error{
          kind: :auth_failed,
          provider: "openai_codex",
          message: "missing oauth"
        }
      )

      assert Enum.any?(Session.messages(session), fn
               {:system, text, :error} ->
                 text =~ "/login" and not String.contains?(text, "/auth openai_codex")

               _ ->
                 false
             end)
    end

    test "structured provider errors render friendly transcript copy" do
      cases = [
        {%Event.Error{kind: :rate_limited, provider: "anthropic", message: "rate limited"},
         "The model provider is rate limiting requests. Wait a moment, then try again."},
        {%Event.Error{kind: :unreachable, provider: "anthropic", message: "nxdomain"},
         "Couldn't reach the model provider. Check your network connection, then try again."},
        {%Event.Error{kind: :provider_error, provider: "anthropic", message: "boom"},
         "The model provider returned an unexpected error. Open Messages for details, or pick another configured model with /model."}
      ]

      for {event, expected} <- cases do
        session = start_subscribed_session()
        send_provider_event(session, event)

        assert Enum.any?(Session.messages(session), fn
                 {:system, text, :error} -> text == expected
                 _ -> false
               end)
      end
    end

    test "provider errors abort running tool transcript entries" do
      session = start_subscribed_session()
      assert :ok = Session.continue(session)
      send_provider_event(session, %Event.AgentStart{})

      send_provider_event(session, %Event.ToolStart{
        tool_call_id: "tc-running",
        name: "shell",
        args: %{"command" => "sleep 10"}
      })

      send_provider_event(session, %Event.Error{
        kind: :provider_error,
        provider: "test",
        message: "crashed"
      })

      assert {:tool_call, %{status: :error, result: "aborted", is_error: true}} =
               Enum.find(Session.messages(session), &match?({:tool_call, _}, &1))
    end

    test "provider errors reject approval requests that arrive after failure" do
      session = start_subscribed_session()

      send_provider_event(session, %Event.Error{
        kind: :provider_error,
        provider: "test",
        message: "crashed"
      })

      send_provider_event(session, %Event.ToolApproval{
        tool_call_id: "tc-late",
        name: "shell",
        args: %{"command" => "pwd"},
        reply_to: self()
      })

      assert_receive {:tool_approval_response, "tc-late", :reject}
    end

    test "repeated structured provider errors append one transcript row" do
      session = start_subscribed_session()
      event = %Event.Error{kind: :rate_limited, provider: "anthropic", message: "rate limited"}

      send_provider_event(session, event)
      send_provider_event(session, event)

      expected = "The model provider is rate limiting requests. Wait a moment, then try again."

      assert Enum.count(Session.messages(session), fn
               {:system, text, :error} -> text == expected
               _ -> false
             end) == 1
    end
  end
end
