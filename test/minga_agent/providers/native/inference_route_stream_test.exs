defmodule MingaAgent.Providers.Native.InferenceRouteStreamTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.CodeLease
  alias MingaAgent.InferenceRouteRegistry
  alias MingaAgent.Providers.Native.InferenceRouteStream
  alias MingaAgent.Providers.Native.ReqLLMAdapter
  alias MingaAgent.Test.FixtureInferenceRoute
  alias MingaAgent.InferenceRoute.ConversationRef
  alias ReqLLM.StreamChunk

  setup do
    suffix = System.unique_integer([:positive])
    registry = :"stream_inference_routes_#{suffix}"
    start_supervised!({InferenceRouteRegistry, name: registry})
    source = {:extension, :"stream_lease_#{suffix}"}
    model_id = "lease#{suffix}"

    {:ok, _reporter} =
      InferenceRouteRegistry.register(
        registry,
        [
          source: source,
          id: "lease#{suffix}",
          module: FixtureInferenceRoute,
          display_name: "Lease"
        ],
        config: [models: [FixtureInferenceRoute.model(id: model_id)]]
      )

    {:ok, conversation} =
      ConversationRef.new(
        session_id: nil,
        owner: self(),
        epoch_id: nil,
        conversation_revision: nil,
        request_id: make_ref(),
        purpose: :summary
      )

    {:ok, llm_model} = ReqLLM.model(%{provider: :contributed, id: model_id, model: model_id})

    %{
      registry: registry,
      source: source,
      route_id: "lease#{suffix}",
      model_id: model_id,
      llm_model: llm_model,
      opts: [minga_conversation: conversation, max_tokens: 100]
    }
  end

  defp start(ctx, route_id \\ nil),
    do:
      InferenceRouteStream.start(
        ctx.registry,
        route_id || ctx.route_id,
        ctx.model_id,
        ctx.llm_model,
        [],
        ctx.opts
      )

  defp leases(source), do: CodeLease.active_leases(source: source)

  test "the route's code stays leased until the stream is consumed", ctx do
    {:ok, _script} =
      FixtureInferenceRoute.script(ctx.model_id, [{:events, [{:text, "hi"}]}])

    assert {:ok, response} =
             start(ctx)

    assert [%{module: FixtureInferenceRoute, owner: owner}] = leases(ctx.source)
    assert owner == self()

    assert [%StreamChunk{text: "hi"}] = Enum.to_list(response.stream)
    assert leases(ctx.source) == []
  end

  test "cancelling or losing the consumer releases the lease", ctx do
    {:ok, _script} =
      FixtureInferenceRoute.script(ctx.model_id, [
        {:events, [{:text, "a"}]},
        {:events, [{:text, "b"}]}
      ])

    {:ok, response} = start(ctx)
    assert [_lease] = leases(ctx.source)
    response.cancel.()
    assert leases(ctx.source) == []

    parent = self()

    {consumer, monitor} =
      spawn_monitor(fn ->
        {:ok, _response} =
          start(ctx)

        send(parent, :started)

        receive do
          :exit -> :ok
        end
      end)

    assert_receive :started
    assert [%{owner: ^consumer}] = leases(ctx.source)
    send(consumer, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^consumer, _reason}
    assert eventually_released(ctx.source)
  end

  test "a failed start holds no lease and a missing route is unavailable", ctx do
    {:ok, _script} = FixtureInferenceRoute.script(ctx.model_id, [{:error, :rate_limited}])

    assert {:error, :rate_limited} =
             start(ctx)

    assert leases(ctx.source) == []

    assert {:error, {:inference_route_unavailable, "missing"}} =
             start(ctx, "missing")
  end

  test "the route is never cancelled after its stream finishes, even with an error finish",
       ctx do
    model_id = ctx.model_id

    {:ok, _script} =
      FixtureInferenceRoute.script(ctx.model_id, [
        {:events, [{:text, "done"}, {:finish, :stop}]},
        {:events, [{:text, "partial"}, {:finish, {:error, :boom}}]}
      ])

    {:ok, response} = start(ctx)
    assert {:ok, _result} = ReqLLMAdapter.process_stream(response)

    {:ok, failing} = start(ctx)
    assert {:error, :boom, "partial"} = ReqLLMAdapter.process_stream(failing)

    refute_receive {:fixture_route_cancelled, ^model_id}, 200
  end

  test "the route is cancelled exactly once when its consumer dies mid-stream", ctx do
    model_id = ctx.model_id
    {:ok, _script} = FixtureInferenceRoute.script(ctx.model_id, [{:block_after, [{:text, "a"}]}])
    parent = self()

    consumer =
      spawn(fn ->
        {:ok, response} = start(ctx)
        send(parent, :started)
        Enum.each(response.stream, fn _chunk -> :ok end)
      end)

    assert_receive :started
    assert_receive {:fixture_route_blocked, ^model_id}
    Process.exit(consumer, :kill)

    assert_receive {:fixture_route_cancelled, ^model_id}, 1_000
    refute_receive {:fixture_route_cancelled, ^model_id}, 200
    assert eventually_released(ctx.source)
  end

  test "stopping early or cancelling cancels the route once", ctx do
    model_id = ctx.model_id

    {:ok, _script} =
      FixtureInferenceRoute.script(ctx.model_id, [{:events, [{:text, "a"}, {:text, "b"}]}])

    {:ok, response} = start(ctx)
    assert [%StreamChunk{text: "a"}] = Enum.take(response.stream, 1)
    response.cancel.()

    assert_receive {:fixture_route_cancelled, ^model_id}, 1_000
    refute_receive {:fixture_route_cancelled, ^model_id}, 200
    assert leases(ctx.source) == []
  end

  test "raising route events end the stream as a route failure", ctx do
    model_id = ctx.model_id

    {:ok, _script} =
      FixtureInferenceRoute.script(ctx.model_id, [{:raise_after, [{:text, "partial"}]}])

    {:ok, response} = start(ctx)

    assert {:error, {:inference_route_failed, _route, {:raised, "fixture events failed"}},
            "partial"} =
             ReqLLMAdapter.process_stream(response)

    assert_receive {:fixture_route_cancelled, ^model_id}, 1_000
    assert leases(ctx.source) == []
  end

  # CodeLease drops a dead owner's leases when it handles the owner's :DOWN message.
  defp eventually_released(source, attempts \\ 50)
  defp eventually_released(_source, 0), do: false

  defp eventually_released(source, attempts) do
    case leases(source) do
      [] ->
        true

      _held ->
        :sys.get_state(CodeLease)
        eventually_released(source, attempts - 1)
    end
  end
end
