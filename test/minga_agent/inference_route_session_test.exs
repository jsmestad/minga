defmodule MingaAgent.InferenceRouteSessionTest do
  @moduledoc "Drives real Session and Native turns through the fixture contributed route."
  use Minga.Test.SessionCase, async: true

  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.InferenceRoute.{ConversationRef, Credential, Message, Request, ToolCall, Usage}
  alias MingaAgent.InferenceRouteRegistry
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Credential.RouteOwned
  alias MingaAgent.Test.FixtureInferenceRoute

  @moduletag :tmp_dir
  @source {:extension, :fixture_session_bridge}

  setup %{tmp_dir: dir} do
    suffix = System.unique_integer([:positive])
    registry = :"session_inference_routes_#{suffix}"
    start_supervised!({InferenceRouteRegistry, name: registry})

    route_id = "fixture#{suffix}"
    model_id = "model#{suffix}"
    second_model_id = "second#{suffix}"

    models = [
      FixtureInferenceRoute.model(id: model_id, display_name: "Fixture Model"),
      FixtureInferenceRoute.model(id: second_model_id, display_name: "Second Fixture Model")
    ]

    {:ok, reporter} =
      InferenceRouteRegistry.register(
        registry,
        [source: @source, id: route_id, module: FixtureInferenceRoute, display_name: "Fixture"],
        config: [models: models]
      )

    %{
      dir: dir,
      registry: registry,
      reporter: reporter,
      route_id: route_id,
      model_id: model_id,
      second_model_id: second_model_id
    }
  end

  defp start_route_session(ctx) do
    echo =
      ReqLLM.Tool.new!(
        name: "fixture_echo",
        description: "Echoes a fixed value",
        parameter_schema: %{"type" => "object", "properties" => %{}},
        callback: fn _args -> {:ok, "echoed"} end
      )

    session =
      start_test_session(
        provider: Native,
        credentials_snapshot_fn: fn -> Snapshot.new(%{}, nil) end,
        provider_opts: [
          model: "#{ctx.route_id}:#{ctx.model_id}",
          project_root: ctx.dir,
          tools: [echo],
          mcp_enabled?: false,
          model_resolver_opts: [inference_routes: ctx.registry, models: [], providers: []],
          credential_opts: [credentials_reader: fn _path -> {:ok, %{}} end, env: %{}]
        ]
      )

    Session.subscribe(session)
    session
  end

  defp text(value), do: {:events, [{:text, value}, {:finish, :stop}]}

  defp assert_request(model_id) do
    assert_receive {:fixture_route_request, ^model_id, %Request{} = request}, @event_timeout
    request
  end

  test "a contributed model streams a reply with core-owned turn identity", ctx do
    {:ok, _script} =
      FixtureInferenceRoute.script(ctx.model_id, [
        {:events,
         [
           {:thinking, "Considering"},
           {:text, "Hello from the route"},
           {:usage, %Usage{input_tokens: 12, output_tokens: 4}},
           {:finish, :stop}
         ]}
      ])

    session = start_route_session(ctx)
    assert :ok = Session.send_prompt(session, "hi")

    request = assert_request(ctx.model_id)
    assert_receive {:agent_event, ^session, {:thinking_delta, "Considering"}}, @event_timeout
    assert_receive {:agent_event, ^session, {:text_delta, "Hello from the route"}}, @event_timeout
    await_turn_complete()

    assert %ConversationRef{purpose: :turn} = conversation = request.conversation
    assert conversation.owner == session
    assert conversation.session_id == Session.session_id(session)
    assert is_binary(conversation.epoch_id)
    assert is_integer(conversation.conversation_revision)
    assert request.credential == Credential.new(%{})
    assert is_binary(request.system)
    assert [%Message{role: :user, content: [{:text, "hi"}]}] = request.messages
    assert [%{name: "fixture_echo", input_schema: %{"type" => "object"}}] = request.tools
    assert request.options.reasoning == "off"
    assert is_integer(request.options.max_output_tokens)

    # A subscription route reports tokens but no dollar cost.
    assert %MingaAgent.TurnUsage{input: 12, output: 4, cost: cost} = Session.usage(session)
    assert cost == 0.0
  end

  test "a route tool call runs through Minga and the follow-up carries the result", ctx do
    {:ok, _script} =
      FixtureInferenceRoute.script(ctx.model_id, [
        {:events,
         [
           {:tool_call, %ToolCall{id: "tc_route", name: "fixture_echo", arguments: %{}}},
           {:finish, :tool_calls}
         ]},
        text("tool finished")
      ])

    session = start_route_session(ctx)
    assert :ok = Session.send_prompt(session, "use the tool")

    first_request = assert_request(ctx.model_id)
    second_request = assert_request(ctx.model_id)
    assert_receive {:agent_event, ^session, {:text_delta, "tool finished"}}, @event_timeout

    assert %Message{role: :assistant, content: assistant} =
             Enum.find(second_request.messages, &(&1.role == :assistant))

    assert {:tool_call, %ToolCall{id: "tc_route", name: "fixture_echo", arguments: %{}}} in assistant

    assert [%Message{content: [{:tool_result, "tc_route", result_parts, false}]}] =
             Enum.filter(second_request.messages, &(&1.role == :tool))

    assert Enum.any?(result_parts, &match?({:text, text} when is_binary(text), &1))
    assert Enum.any?(result_parts, fn {:text, text} -> text =~ "echoed" end)

    first = first_request.conversation
    second = second_request.conversation
    assert second.session_id == first.session_id
    assert second.epoch_id == first.epoch_id
    assert second.request_id == first.request_id
    assert second.conversation_revision >= first.conversation_revision
  end

  test "compaction asks the route for an isolated summary", ctx do
    {:ok, _script} =
      FixtureInferenceRoute.script(ctx.model_id, [
        text("ready"),
        text("Summary of the earlier conversation")
      ])

    session = start_route_session(ctx)
    assert :ok = Session.send_prompt(session, "warm up")
    turn_request = assert_request(ctx.model_id)
    await_turn_complete()

    history =
      for index <- 1..8 do
        role = if rem(index, 2) == 1, do: :user, else: :assistant

        %ReqLLM.Message{
          role: role,
          content: [ReqLLM.Message.ContentPart.text("message #{index}")]
        }
      end

    provider = Session.get_provider(session)
    assert {:ok, _compacted, _info} = GenServer.call(provider, {:compact, history}, 10_000)

    summary_request = assert_request(ctx.model_id)
    assert %ConversationRef{purpose: :summary} = summary = summary_request.conversation
    assert summary.owner == session
    assert summary.conversation_revision == nil
    assert is_reference(summary.request_id)
    assert summary.epoch_id in [nil, turn_request.conversation.epoch_id]
    assert summary_request.tools == []
  end

  test "a plan limit names when it resets and offers a model switch", ctx do
    resets_at = DateTime.add(DateTime.utc_now(), 3_600)

    :ok =
      InferenceRouteRegistry.report_usage(ctx.registry, ctx.reporter, [
        %{kind: "five_hour", utilization: 1.0, resets_at: resets_at, status: :rejected}
      ])

    {:ok, _script} = FixtureInferenceRoute.script(ctx.model_id, [{:error, :rate_limited}])

    session = start_route_session(ctx)
    assert :ok = Session.send_prompt(session, "hi")

    assert_receive {:agent_event, ^session, {:error, message}}, @event_timeout

    assert message =~
             ~r/\AFixture plan limit reached\. Resets at \d{1,2}:\d{2} (AM|PM)\. Switch model to continue\.\z/

    assert_receive {:agent_event, ^session, {:model_limit_reached, ^message}}, @event_timeout
  end

  test "a route failure is classified by the route", ctx do
    {:ok, _script} = FixtureInferenceRoute.script(ctx.model_id, [{:error, :rate_limited}])

    session = start_route_session(ctx)
    assert :ok = Session.send_prompt(session, "hi")

    assert_receive {:agent_event, ^session, {:error, message}}, @event_timeout
    assert message == "Fixture route is rate limited."
  end

  test "an invalid route event fails the turn with a clear message instead of crashing", ctx do
    {:ok, _script} =
      FixtureInferenceRoute.script(ctx.model_id, [{:events, [{:text, "ok"}, {:bogus, 1}]}])

    session = start_route_session(ctx)
    assert :ok = Session.send_prompt(session, "hi")

    assert_receive {:agent_event, ^session, {:error, message}}, @event_timeout
    assert message =~ "sent an invalid response"
    assert is_binary(Session.session_id(session))
  end

  test "stopping a turn keeps the partial reply and cancels the route", ctx do
    model_id = ctx.model_id

    {:ok, _script} =
      FixtureInferenceRoute.script(ctx.model_id, [
        {:block_after, [{:text, "Partial answer before stop"}]}
      ])

    session = start_route_session(ctx)
    assert :ok = Session.send_prompt(session, "start then stop")
    _request = assert_request(ctx.model_id)

    assert_receive {:agent_event, ^session, {:text_delta, "Partial answer before stop"}},
                   @event_timeout

    assert_receive {:fixture_route_blocked, ^model_id}, @event_timeout
    assert :ok = Session.abort(session)

    assert_receive {:fixture_route_cancelled, ^model_id}, @event_timeout
    refute_receive {:fixture_route_cancelled, ^model_id}, 200

    assert Enum.any?(Session.messages(session), fn
             {:assistant, text} when is_binary(text) -> text =~ "Partial answer before stop"
             _other -> false
           end)
  end

  test "a route removed while idle fails the next send without falling back", ctx do
    {:ok, _script} = FixtureInferenceRoute.script(ctx.model_id, [text("first")])

    session = start_route_session(ctx)
    assert :ok = Session.send_prompt(session, "first")
    _first_request = assert_request(ctx.model_id)
    assert_receive {:agent_event, ^session, {:text_delta, "first"}}, @event_timeout
    await_turn_complete()

    :ok = InferenceRouteRegistry.unregister_source(ctx.registry, @source)

    assert :ok = Session.send_prompt(session, "second")
    assert_receive {:agent_event, ^session, {:error, message}}, @event_timeout
    assert message =~ "no extension provides it"
    refute_received {:fixture_route_request, _model, _request}
    assert is_binary(Session.session_id(session))
  end

  test "a ready contributed model can be selected and pins the reported account", ctx do
    session = start_route_session(ctx)

    :ok =
      InferenceRouteRegistry.report_status(ctx.registry, ctx.reporter, {:ready, "me@example.com"})

    assert :ok = Session.set_model(session, "#{ctx.route_id}:#{ctx.second_model_id}")

    assert %ModelSelection{
             route: %{request_provider: :contributed, model_id: second_model_id},
             credential: %RouteOwned{account_ref: "me@example.com"}
           } = Session.model_selection(session)

    assert second_model_id == ctx.second_model_id
  end
end
