defmodule MingaAgent.ModelResolverContributedTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Config
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.InferenceRouteRegistry
  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelResolver
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Credential.RouteOwned
  alias MingaAgent.ModelSelection.Stored
  alias MingaAgent.ProviderPacks.Native
  alias MingaAgent.Test.FixtureInferenceRoute

  @source {:extension, :fixture_bridge}

  setup do
    registry = :"contributed_routes_#{System.unique_integer([:positive])}"
    start_supervised!({InferenceRouteRegistry, name: registry})

    {:ok, reporter} =
      InferenceRouteRegistry.register(registry,
        source: @source,
        id: "fixture",
        module: FixtureInferenceRoute,
        display_name: "Fixture Route"
      )

    opts = [
      backend_spec: Native.spec(),
      credential_snapshot: Snapshot.new(%{}, nil),
      config: %Config{max_tokens: 4_096},
      models: [],
      providers: [],
      inference_routes: registry
    ]

    %{registry: registry, reporter: reporter, opts: opts}
  end

  defp report(reporter, registry, availability),
    do: :ok = InferenceRouteRegistry.report_status(registry, reporter, availability)

  defp round_trip(selection),
    do: selection |> ModelSelection.encode() |> JSON.encode!() |> JSON.decode!()

  test "a route model reference builds policy from the route's declaration", %{
    registry: registry,
    reporter: reporter,
    opts: opts
  } do
    report(reporter, registry, {:ready, "me@example.com"})

    assert {:ok, selection} = ModelResolver.resolve("fixture:fixture-model", opts)
    assert selection.route.origin == {:contributed, "fixture", "fixture-model"}
    assert selection.route.request_provider == :contributed
    assert selection.route.id == "fixture/fixture-model"
    assert selection.route.display_name == "Fixture Model"
    assert selection.credential == RouteOwned.new("fixture", "me@example.com")
    assert selection.request_model.provider == :contributed

    assert selection.request_model.extra.inference_route == %{
             route_id: "fixture",
             model_id: "fixture-model"
           }

    policy = selection.policy
    assert policy.reasoning.effort == "off"
    assert policy.reasoning.options == ["off", "low", "high"]
    assert policy.limits.context == 200_000
    assert policy.limits.output == 32_000
    assert policy.limits.request_output == 4_096

    assert Map.from_struct(policy.capabilities) ==
             %{tools: true, images: true, tool_result_images: false, streaming: true}

    assert {policy.compaction, policy.usage, policy.cost_mode} ==
             {:native, :tokens, :subscription}
  end

  test "thinking level must be one the route declares", %{opts: opts} do
    assert {:ok, selection} =
             ModelResolver.resolve(
               %{"model" => "fixture:fixture-model", "thinking" => "high"},
               opts
             )

    assert selection.policy.reasoning.effort == "high"

    assert {:error, {:incompatible_selection, message}} =
             ModelResolver.resolve(
               %{"model" => "fixture:fixture-model", "thinking" => "max"},
               opts
             )

    assert message =~ "Available: off, low, high"
  end

  test "an unavailable route cannot become the selected model and reports its own remedy",
       %{registry: registry, reporter: reporter, opts: opts} do
    report(reporter, registry, {:unavailable, :not_signed_in, FixtureInferenceRoute.remedy()})

    assert {:error, {:route_unavailable, message}} =
             ModelResolver.resolve("fixture:fixture-model", opts)

    assert message == FixtureInferenceRoute.remedy()
  end

  test "an unknown model on a registered route is not found", %{opts: opts} do
    assert {:error, {:model_not_found, "fixture:missing"}} =
             ModelResolver.resolve("fixture:missing", opts)
  end

  test "contributed routes require the native backend", %{opts: opts} do
    other = %{Native.spec() | id: "other"}

    assert {:error, {:route_unavailable, message}} =
             ModelResolver.resolve(
               "fixture:fixture-model",
               Keyword.put(opts, :backend_spec, other)
             )

    assert message =~ "Native agent backend"
  end

  test "selection identity changes with the route's account", %{
    registry: registry,
    reporter: reporter,
    opts: opts
  } do
    report(reporter, registry, {:ready, "first@example.com"})
    {:ok, first} = ModelResolver.resolve("fixture:fixture-model", opts)
    report(reporter, registry, {:ready, "second@example.com"})
    {:ok, second} = ModelResolver.resolve("fixture:fixture-model", opts)

    assert first.route == second.route
    refute ModelSelection.id(first) == ModelSelection.id(second)
    assert ModelSelection.credential_id(first.credential) == "fixture:first@example.com"
  end

  test "a saved contributed selection round-trips its route credential and policy modes",
       %{registry: registry, reporter: reporter, opts: opts} do
    report(reporter, registry, {:ready, "me@example.com"})
    {:ok, selection} = ModelResolver.resolve("fixture:fixture-model", opts)
    saved = round_trip(selection)

    assert saved["credential"] == %{
             "kind" => "route_owned",
             "route_id" => "fixture",
             "account_ref" => "me@example.com"
           }

    assert {:ok, %Stored{} = stored} = ModelSelection.decode(saved)
    assert stored.credential == selection.credential
    assert stored.route == selection.route
    assert stored.policy == selection.policy
    assert ModelSelection.id(stored) == ModelSelection.id(selection)

    assert {:ok, restored} = ModelResolver.restore(saved, opts)
    assert ModelSelection.id(restored) == ModelSelection.id(selection)
  end

  test "a credential cannot be paired with another route", %{
    registry: registry,
    reporter: reporter,
    opts: opts
  } do
    report(reporter, registry, {:ready, "me@example.com"})
    {:ok, selection} = ModelResolver.resolve("fixture:fixture-model", opts)
    saved = round_trip(selection)
    forged = put_in(saved, ["credential", "route_id"], "other")

    assert {:error, :invalid_credential} = ModelSelection.decode(forged)
  end

  test "restoring a saved selection never falls back when its route changed",
       %{registry: registry, reporter: reporter, opts: opts} do
    report(reporter, registry, {:ready, "me@example.com"})
    {:ok, selection} = ModelResolver.resolve("fixture:fixture-model", opts)
    saved = round_trip(selection)

    report(reporter, registry, {:unavailable, :not_signed_in, FixtureInferenceRoute.remedy()})

    assert {:error, {:route_unavailable, remedy}} = ModelResolver.restore(saved, opts)
    assert remedy == FixtureInferenceRoute.remedy()

    report(reporter, registry, {:ready, "someone-else@example.com"})

    assert {:error, {:selection_correction_required, message}} =
             ModelResolver.restore(saved, opts)

    assert message =~ "different account"

    :ok = InferenceRouteRegistry.unregister_source(registry, @source)

    assert {:error, {:route_unavailable, missing}} = ModelResolver.restore(saved, opts)
    assert missing =~ "no extension provides it"

    assert {:error, {:route_unavailable, ^missing}} = ModelResolver.restore(selection, opts)
  end

  test "restoring rejects a saved selection whose model declaration changed",
       %{registry: registry, reporter: reporter, opts: opts} do
    report(reporter, registry, {:ready, "me@example.com"})
    {:ok, selection} = ModelResolver.resolve("fixture:fixture-model", opts)
    saved = round_trip(selection)

    smaller = FixtureInferenceRoute.model(context_window: 100_000)

    {:ok, reporter} =
      InferenceRouteRegistry.register(
        registry,
        [
          source: @source,
          id: "fixture",
          module: FixtureInferenceRoute,
          display_name: "Fixture Route"
        ],
        config: [models: [smaller]]
      )

    report(reporter, registry, {:ready, "me@example.com"})

    assert {:error, {:selection_correction_required, message}} =
             ModelResolver.restore(saved, opts)

    assert message =~ "model declaration changed"
  end

  test "candidates list every route model with its status, but defaults skip unready routes",
       %{registry: registry, reporter: reporter, opts: opts} do
    {:ok, offline} =
      InferenceRouteRegistry.register(registry,
        source: @source,
        id: "offline",
        module: FixtureInferenceRoute,
        display_name: "Offline Route"
      )

    report(reporter, registry, {:ready, "me@example.com"})

    :ok =
      InferenceRouteRegistry.report_status(
        registry,
        offline,
        {:unavailable, :not_signed_in, FixtureInferenceRoute.remedy()}
      )

    candidates = ModelResolver.candidates(opts)

    routes =
      Map.new(candidates, fn %ModelCandidate{selection: selection, inference_route: route} ->
        {selection.route.model_provider, route}
      end)

    assert %{display_name: "Fixture Route", status: %{availability: {:ready, _}}} =
             routes["fixture"]

    assert %{display_name: "Offline Route", status: %{availability: {:unavailable, _, _}}} =
             routes["offline"]

    assert {:ok, default} = ModelResolver.resolve(nil, opts)
    assert default.route.model_provider == "fixture"

    [ready] = Enum.filter(candidates, &(&1.selection.route.model_provider == "fixture"))
    assert {:ok, by_id} = ModelResolver.resolve(ModelSelection.id(ready.selection), opts)
    assert ModelSelection.id(by_id) == ModelSelection.id(ready.selection)
  end

  test "an unchecked route can be configured by reference before it reports an account",
       %{opts: opts} do
    assert {:ok, selection} = ModelResolver.resolve("fixture:fixture-model", opts)
    assert selection.credential == RouteOwned.new("fixture", nil)
    assert {:ok, _restored} = ModelResolver.restore(round_trip(selection), opts)
    assert {:error, :no_available_model} = ModelResolver.resolve(nil, opts)
  end
end
