defmodule MingaAgent.SessionProviderErrorTest do
  use Minga.Test.SessionCase, async: true

  # Completion includes durable checkpoints and shared filesystem waits, not a five-second event SLA.
  @durable_workflow_timeout 30_000
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target

  describe "MCP crash handling" do
    @tag :tmp_dir
    test "adds a system message and can still run a builtin tool", %{tmp_dir: dir} do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])
      oauth_path = Path.join(dir, "credentials/oauth.json")

      assert :ok =
               MingaAgent.OAuth.write_oauth_file(
                 %{
                   access: "fixture-access",
                   refresh: "fixture-refresh",
                   account_id: "fixture-account",
                   expires: System.system_time(:millisecond) + 3_600_000
                 },
                 oauth_path
               )

      credential_opts = [
        config_dir: Path.join(dir, "credentials"),
        env: %{},
        oauth_path: oauth_path
      ]

      resolver_opts =
        MingaAgent.Test.ModelSelectionFixture.resolver_opts(model_id: "gpt-6.1-sol")
        |> Keyword.delete(:credential_snapshot)

      # Keep recovery and builtin effect admission on this case's own durability queue.
      event_log =
        start_supervised!(
          {MingaAgent.EventLog,
           name: nil,
           db_dir: Path.join(dir, "events"),
           retention_sweep?: false,
           health_check: :none}
        )

      suffix = System.unique_integer([:positive])

      artifact_opts = [
        name: nil,
        root: Path.join(dir, "artifacts"),
        quota: Module.concat(__MODULE__, "RecoveryArtifactQuota#{suffix}"),
        registry: Module.concat(__MODULE__, "RecoveryArtifactRegistry#{suffix}"),
        store_supervisor: Module.concat(__MODULE__, "RecoveryArtifactStores#{suffix}")
      ]

      start_supervised!({MingaAgent.ArtifactSupervisor, artifact_opts})
      {:ok, artifact_runtime} = MingaAgent.ArtifactSupervisor.runtime(artifact_opts)

      llm_client = fn _model, _messages, opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        send(test_pid, {:session_mcp_tools, count, Enum.map(opts[:tools], & &1.name)})

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

        # Only successful enumeration signals exhaustion; cancellation must not satisfy the wait.
        stream =
          Stream.transform(
            chunks,
            fn -> count end,
            fn chunk, call -> {[chunk], call} end,
            fn call ->
              send(test_pid, {:mcp_response_stream_exhausted, call})
              {[], call}
            end,
            fn _call -> :ok end
          )

        mcp_session_stream(stream)
      end

      session =
        start_test_session(
          persist?: true,
          session_store_dir: Path.join(dir, "sessions"),
          event_log_server: event_log,
          artifact_runtime: artifact_runtime,
          provider: Native,
          credentials_snapshot_fn: fn -> MingaAgent.Credentials.snapshot(credential_opts) end,
          provider_opts: [
            model: "openai:gpt-6.1-sol",
            project_root: dir,
            tools: [mcp_session_builtin_tool()],
            config: %MingaAgent.Config{
              mcp_servers: [%ServerConfig{name: "Local Tools", command: "ignored"}]
            },
            model_resolver_opts: resolver_opts,
            credential_opts: credential_opts,
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

      assert_receive {:agent_event, ^session,
                      {:approval_pending,
                       %Public{target: %Target{} = target, name: "list_mcp_tools"}}},
                     @event_timeout

      assert :ok = Session.respond_to_approval(session, target, :approve)
      assert_receive {:mcp_transport_started, "Local Tools", transport}, @event_timeout
      await_durable_mcp_turn(session, "list_mcp_tools", 1, "MCP discovery")

      FakeTransport.crash(transport)

      assert_receive {:agent_event, ^session, {:error, message}}, @event_timeout
      assert message =~ "MCP server Local Tools stopped"
      assert Enum.any?(Session.messages(session), &match?({:system, _text, :error}, &1))
      assert_receive {:agent_event, ^session, {:status_changed, :error}}, @event_timeout

      assert :ok = Session.send_prompt(session, "continue")
      await_durable_mcp_turn(session, "builtin_echo", 3, "builtin recovery")
      assert_receive {:session_mcp_tools, 2, tool_names}, @event_timeout
      assert "builtin_echo" in tool_names
      assert "list_mcp_tools" in tool_names
      assert "call_mcp_tool" in tool_names
      refute "mcp_local_tools__echo_text" in tool_names

      assert Enum.any?(Session.messages(session), fn
               {:tool_call,
                %{name: "builtin_echo", status: :complete, is_error: false, result: "builtin ok"}} ->
                 true

               _ ->
                 false
             end)
    end
  end

  describe "failed turn error messages" do
    @tag :tmp_dir
    test "a provider stream failure adds one error message", %{tmp_dir: dir} do
      session = start_failing_native_session(dir, fn _count -> {:error, :stream_failed} end)

      assert :ok = Session.send_prompt(session, "fail")
      message = await_failed_turn(session)

      assert error_messages(session) == [message]
    end

    @tag :tmp_dir
    test "a provider stream failure after a tool-call group adds one error message",
         %{tmp_dir: dir} do
      File.write!(Path.join(dir, "test.txt"), "file contents")

      session =
        start_failing_native_session(dir, fn
          0 ->
            build_stream_response([
              ReqLLM.StreamChunk.tool_call("read_file", %{"path" => "test.txt"}, %{
                id: "tc_read",
                index: 0
              }),
              ReqLLM.StreamChunk.meta(%{finish_reason: :tool_use})
            ])

          _after_tool ->
            {:error, :stream_failed}
        end)

      assert :ok = Session.set_tool_trust(session, "read_file", :turn)
      assert :ok = Session.send_prompt(session, "read then fail")
      message = await_failed_turn(session)

      messages = Session.messages(session)

      assert Enum.any?(messages, fn
               {:system, "Interrupted tool-call group reconciled without replay" <> _, _level} ->
                 true

               _other ->
                 false
             end)

      assert error_messages(session) == [message]
    end
  end

  describe "subscription usage limits" do
    # The 429 ChatGPT Pro returned on 2026-11-23 when its weekly limit was reached, as ReqLLM reports it.
    @usage_limit_error ReqLLM.Error.API.Request.exception(
                         reason: "The usage limit has been reached",
                         status: 429,
                         response_body: %{
                           "eligible_promo" => nil,
                           "limit_window_minutes" => 10_080,
                           "message" => "The usage limit has been reached",
                           "plan_type" => "pro",
                           "resets_at" => 1_795_626_066,
                           "resets_in_seconds" => 172_541,
                           "type" => "usage_limit_reached"
                         },
                         provider_code: "usage_limit_reached",
                         retryable: true
                       )

    @tag :tmp_dir
    test "a usage limit names its plan and reset, is not retried or followed by queued input, and marks the route until a request succeeds",
         %{tmp_dir: dir} do
      test_pid = self()

      # The ChatGPT account lists the model, so /model can show its route.
      inventory = fn conn ->
        Req.Test.json(conn, %{"models" => [%{"slug" => "gpt-6.1-sol", "visibility" => "list"}]})
      end

      session =
        start_failing_native_session(
          dir,
          fn
            0 ->
              send(test_pid, {:usage_limit_request, 0, self()})

              receive do
                :respond -> {:error, @usage_limit_error}
              end

            count ->
              send(test_pid, {:usage_limit_request, count, self()})

              build_stream_response([
                ReqLLM.StreamChunk.text("back again"),
                ReqLLM.StreamChunk.meta(%{finish_reason: :stop})
              ])
          end,
          plug: inventory
        )

      assert :ok = Session.send_prompt(session, "hello")
      assert_receive {:usage_limit_request, 0, request}, @durable_workflow_timeout
      assert {:queued, :follow_up} = Session.queue_follow_up(session, "after the limit")
      send(request, :respond)

      message = await_failed_turn(session)

      assert message =~
               ~r/\AYour ChatGPT Pro usage limit is reached\. It resets \w{3}, Nov 2[56] at \d{1,2}:\d{2} (AM|PM)\. Choose another model with \/model to continue now\.\z/

      assert_received {:agent_event, ^session, {:model_limit_reached, ^message}}
      assert error_messages(session) == [message]

      # Neither an in-turn retry nor the queued follow-up reaches the provider.
      refute_receive {:usage_limit_request, _count, _request}, 300
      assert {[], ["after the limit"]} = Session.get_queued_messages(session)

      # /model lists the route as limit-reached until the reset passes or a request succeeds.
      assert {:ok, candidates, _notice, _validity} = Session.discover_available_models(session)
      assert [limited] = remote_candidates(candidates)

      assert %MingaAgent.UsageLimit{
               service: "ChatGPT",
               plan: "pro",
               window_minutes: 10_080,
               resets_at: ~U[2026-11-25 17:01:06Z]
             } = limited.usage_limit

      # A later request that succeeds on the route lifts the limit.
      assert :ok = Session.send_prompt(session, "try again")
      assert_receive {:usage_limit_request, 1, _request}, @durable_workflow_timeout
      assert_receive {:agent_event, ^session, {:status_changed, :idle}}, @durable_workflow_timeout
      assert {:ok, candidates, _notice, _validity} = Session.discover_available_models(session)
      assert [lifted] = remote_candidates(candidates)
      assert lifted.usage_limit == nil
    end

    test "a usage limit keeps the provider's sentence and text-only reports name no reset" do
      limit = %MingaAgent.UsageLimit{service: "ChatGPT", plan: "pro"}

      sentence =
        "Your ChatGPT Pro usage limit is reached. Choose another model with /model to continue now."

      cases = [
        {Event.Error.usage_limit(limit, sentence, "openai_codex"), sentence},
        {%Event.Error{
           kind: :unknown,
           provider: "custom",
           message: "429 Too Many Requests: {\"type\":\"usage_limit_reached\"}"
         },
         "Your plan's usage limit is reached. Choose another model with /model to continue now."},
        {%Event.Error{kind: :unknown, provider: "custom", message: "429 Too Many Requests"},
         "The model provider is rate limiting requests. Wait a moment, then try again."}
      ]

      for {event, expected} <- cases do
        session = start_subscribed_session()
        send_provider_event(session, event)
        assert error_messages(session) == [expected]
      end
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
        {%Event.Error{
           kind: :context_transition_required,
           provider: "test",
           message: "private provider payload api_key=not-for-display"
         }, Event.Error.context_transition_message()},
        {%Event.Error{kind: :rate_limited, provider: "anthropic", message: "rate limited"},
         "The model provider is rate limiting requests. Wait a moment, then try again."},
        {%Event.Error{kind: :unreachable, provider: "anthropic", message: "nxdomain"},
         "Couldn't reach the model provider. Check your network connection, then try again."},
        {%Event.Error{
           kind: :provider_error,
           provider: "apple",
           message:
             "Apple context limit is 4096 tokens; input uses 4110 with 512 reserved for output"
         }, "Apple context limit is 4096 tokens; input uses 4110 with 512 reserved for output"},
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

    test "provider errors preserve running tools until matching completion" do
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
        message: "hook rejected"
      })

      assert Session.status(session) == :error
      assert Session.editor_snapshot(session).active_tool_name == "shell"

      send_provider_event(session, %Event.ToolEnd{
        tool_call_id: "tc-running",
        name: "shell",
        outcome: :error,
        result: "blocked by hook",
        is_error: true
      })

      assert_receive {:agent_event, ^session,
                      {:tool_ended,
                       %Event.ToolEnd{name: "shell", result: "blocked by hook", outcome: :error}}}

      assert {:tool_call, %{status: :error, result: "blocked by hook", is_error: true}} =
               Enum.find(Session.messages(session), &match?({:tool_call, _}, &1))

      assert Session.editor_snapshot(session).active_tool_name == nil
    end

    test "provider errors reject approval requests that arrive after failure" do
      session =
        start_subscribed_session(
          Minga.Test.SessionContinuationProvider,
          test_pid: self()
        )

      assert :ok = Session.send_prompt(session, "start a turn")
      assert_receive {:continuation_request, _request}, @event_timeout

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

  @spec await_durable_mcp_turn(GenServer.server(), String.t(), non_neg_integer(), String.t()) ::
          :ok
  defp await_durable_mcp_turn(session, tool_name, response_call, phase) do
    receive do
      {:agent_event, ^session,
       {:tool_ended, %Event.ToolEnd{name: ^tool_name, outcome: :complete}}} ->
        :ok

      {:agent_event, ^session,
       {:tool_ended, %Event.ToolEnd{name: ^tool_name, result: result, outcome: status}}} ->
        flunk("#{phase} tool ended with #{inspect(status)}: #{inspect(result)}")

      {:agent_event, ^session, {:approval_pending, approval}} ->
        flunk("#{phase} unexpectedly needs approval: #{inspect(approval)}")

      {:agent_event, ^session, {:error, message}} ->
        flunk("#{phase} failed before its tool completed: #{message}")

      {:agent_event, ^session, {:status_changed, :error}} ->
        flunk("#{phase} entered error before its tool completed")
    after
      @durable_workflow_timeout ->
        flunk(
          "#{phase} tool did not complete; mailbox: " <>
            inspect(Process.info(self(), :messages), limit: :infinity)
        )
    end

    # Final-response completion starts after the public tool/persistence completion event.
    receive do
      {:mcp_response_stream_exhausted, ^response_call} ->
        :ok

      {:agent_event, ^session, {:approval_pending, approval}} ->
        flunk("#{phase} unexpectedly needs approval: #{inspect(approval)}")

      {:agent_event, ^session, {:error, message}} ->
        flunk("#{phase} failed before its response stream was exhausted: #{message}")

      {:agent_event, ^session, {:status_changed, :error}} ->
        flunk("#{phase} entered error before its response stream was exhausted")
    after
      @durable_workflow_timeout ->
        flunk(
          "#{phase} response stream was not exhausted; mailbox: " <>
            inspect(Process.info(self(), :messages), limit: :infinity)
        )
    end

    receive do
      {:agent_event, ^session, {:resumable_boundary, _revision}} ->
        :ok

      {:agent_event, ^session, {:approval_pending, approval}} ->
        flunk("#{phase} unexpectedly needs approval: #{inspect(approval)}")

      {:agent_event, ^session, {:error, message}} ->
        flunk("#{phase} failed before durable completion: #{message}")

      {:agent_event, ^session, {:status_changed, :error}} ->
        flunk("#{phase} entered error before durable completion")
    after
      @durable_workflow_timeout ->
        flunk(
          "#{phase} did not publish a durable boundary; mailbox: " <>
            inspect(Process.info(self(), :messages), limit: :infinity)
        )
    end

    receive do
      {:agent_event, ^session, {:status_changed, :idle}} ->
        :ok

      {:agent_event, ^session, {:approval_pending, approval}} ->
        flunk("#{phase} unexpectedly needs approval: #{inspect(approval)}")

      {:agent_event, ^session, {:error, message}} ->
        flunk("#{phase} failed after its durable boundary: #{message}")

      {:agent_event, ^session, {:status_changed, :error}} ->
        flunk("#{phase} entered error after its durable boundary")
    after
      @durable_workflow_timeout ->
        flunk(
          "#{phase} did not become idle after its durable boundary; mailbox: " <>
            inspect(Process.info(self(), :messages), limit: :infinity)
        )
    end
  end

  @spec start_failing_native_session(Path.t(), (non_neg_integer() -> term()), keyword()) :: pid()
  defp start_failing_native_session(dir, respond, extra_credential_opts \\ []) do
    call_count = :counters.new(1, [:atomics])
    oauth_path = Path.join(dir, "credentials/oauth.json")

    assert :ok =
             MingaAgent.OAuth.write_oauth_file(
               %{
                 access: "fixture-access",
                 refresh: "fixture-refresh",
                 account_id: "fixture-account",
                 expires: System.system_time(:millisecond) + 3_600_000
               },
               oauth_path
             )

    credential_opts =
      [
        config_dir: Path.join(dir, "credentials"),
        env: %{},
        oauth_path: oauth_path
      ] ++ extra_credential_opts

    resolver_opts =
      MingaAgent.Test.ModelSelectionFixture.resolver_opts(model_id: "gpt-6.1-sol")
      |> Keyword.delete(:credential_snapshot)

    # Keep tool-effect admission on this case's own durability queue.
    event_log =
      start_supervised!(
        {MingaAgent.EventLog,
         name: nil, db_dir: Path.join(dir, "events"), retention_sweep?: false, health_check: :none}
      )

    suffix = System.unique_integer([:positive])

    artifact_opts = [
      name: nil,
      root: Path.join(dir, "artifacts"),
      quota: Module.concat(__MODULE__, "FailedTurnArtifactQuota#{suffix}"),
      registry: Module.concat(__MODULE__, "FailedTurnArtifactRegistry#{suffix}"),
      store_supervisor: Module.concat(__MODULE__, "FailedTurnArtifactStores#{suffix}")
    ]

    start_supervised!({MingaAgent.ArtifactSupervisor, artifact_opts})
    {:ok, artifact_runtime} = MingaAgent.ArtifactSupervisor.runtime(artifact_opts)

    llm_client = fn _model, _messages, _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)
      respond.(count)
    end

    session =
      start_test_session(
        provider: Native,
        persist?: true,
        session_store_dir: Path.join(dir, "sessions"),
        event_log_server: event_log,
        artifact_runtime: artifact_runtime,
        credentials_snapshot_fn: fn -> MingaAgent.Credentials.snapshot(credential_opts) end,
        provider_opts: [
          model: "openai:gpt-6.1-sol",
          model_resolver_opts: resolver_opts,
          credential_opts: credential_opts,
          project_root: dir,
          llm_client: llm_client,
          tools: MingaAgent.Tools.all(project_root: dir),
          config: agent_config([])
        ]
      )

    assert :ok = Session.subscribe(session)
    session
  end

  @spec await_failed_turn(pid()) :: String.t()
  defp await_failed_turn(session) do
    assert_receive {:agent_event, ^session, {:error, message}}, @durable_workflow_timeout

    # The error event and the turn's completion each announce the error status. Wait for both so the
    # transcript includes everything completion writes.
    assert_receive {:agent_event, ^session, {:status_changed, :error}}, @durable_workflow_timeout
    assert_receive {:agent_event, ^session, {:status_changed, :error}}, @durable_workflow_timeout

    # The reply follows every broadcast completion sent, so a second failure report would already be here.
    assert Session.status(session) == :error
    refute_received {:agent_event, ^session, {:error, _duplicate}}
    message
  end

  @spec error_messages(pid()) :: [String.t()]
  defp error_messages(session) do
    for {:system, text, :error} <- Session.messages(session), do: text
  end

  # A Mac with the Apple Intelligence helper built also discovers the local on-device
  # route; these assertions are about the stubbed remote route only.
  defp remote_candidates(candidates),
    do: Enum.reject(candidates, &(&1.selection.route.request_provider == :apple))
end
