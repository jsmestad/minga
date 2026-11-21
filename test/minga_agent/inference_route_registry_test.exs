defmodule MingaAgent.InferenceRouteRegistryTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.InvocationContext
  alias Minga.Extension.ModelRoutes
  alias MingaAgent.InferenceRoute.{PlanWindow, Reporter, Status, StatusChangedEvent}
  alias MingaAgent.InferenceRouteRegistry
  alias MingaAgent.InferenceRouteRegistry.Entry
  alias MingaAgent.Test.FixtureInferenceRoute

  setup do
    name = :"inference_route_registry_#{System.unique_integer([:positive])}"
    start_supervised!({InferenceRouteRegistry, name: name})
    %{registry: name}
  end

  defp spec(source, id \\ "fixture"),
    do: [source: source, id: id, module: FixtureInferenceRoute, display_name: "Fixture Route"]

  test "registers a route with its models and an unknown status", %{registry: registry} do
    assert {:ok, _reporter} = InferenceRouteRegistry.register(registry, spec({:extension, :one}))

    assert {:ok, %Entry{spec: spec, models: [model], status: status}} =
             InferenceRouteRegistry.lookup(registry, "fixture")

    assert spec.source == {:extension, :one}
    assert model.id == "fixture-model"
    assert status == Status.unknown()
    assert [%Entry{}] = InferenceRouteRegistry.list(registry)
  end

  test "a second source cannot take a route id and the first route keeps working",
       %{registry: registry} do
    {:ok, _reporter} = InferenceRouteRegistry.register(registry, spec({:extension, :one}))

    assert {:error, {:duplicate_route_id, "fixture", {:extension, :one}, {:extension, :two}}} =
             InferenceRouteRegistry.register(registry, spec({:extension, :two}))

    assert {:ok, %Entry{spec: %{source: {:extension, :one}}}} =
             InferenceRouteRegistry.lookup(registry, "fixture")
  end

  test "the owning source can replace its route, which retires the old reporter",
       %{registry: registry} do
    {:ok, old} = InferenceRouteRegistry.register(registry, spec({:extension, :one}))
    :ok = InferenceRouteRegistry.report_status(registry, old, {:ready, "a"})
    replacement = FixtureInferenceRoute.model(id: "other-model")

    assert {:ok, new} =
             InferenceRouteRegistry.register(registry, spec({:extension, :one}),
               config: [models: [replacement]]
             )

    assert {:ok, %Entry{models: [%{id: "other-model"}], status: status}} =
             InferenceRouteRegistry.lookup(registry, "fixture")

    assert status == Status.unknown()

    assert {:error, :stale_reporter} =
             InferenceRouteRegistry.report_status(registry, old, {:ready, "a"})

    assert :ok = InferenceRouteRegistry.report_status(registry, new, {:ready, "b"})
  end

  test "rejects invalid specs, modules that miss callbacks, and invalid model lists",
       %{registry: registry} do
    assert {:error, {:invalid_spec, :reserved_id}} =
             InferenceRouteRegistry.register(registry, spec({:extension, :one}, "anthropic"))

    assert {:error, {:invalid_route_module, Enum}} =
             InferenceRouteRegistry.register(
               registry,
               Keyword.put(spec({:extension, :one}), :module, Enum)
             )

    model = FixtureInferenceRoute.model()

    for {models, reason} <- [
          {[], {:expected_non_empty_list, []}},
          {[model, model], :duplicate_model_id},
          {[%{id: "map"}], {:invalid_model_field, :struct}}
        ] do
      assert {:error, {:invalid_models, ^reason}} =
               InferenceRouteRegistry.register(registry, spec({:extension, :one}),
                 config: [models: models]
               )
    end

    assert InferenceRouteRegistry.list(registry) == []
  end

  test "a reporter works from any process and is rejected once its route is removed",
       %{registry: registry} do
    {:ok, reporter} = InferenceRouteRegistry.register(registry, spec({:extension, :one}))
    remedy = "Not signed in. Run: login"
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:reported,
         InferenceRouteRegistry.report_status(
           registry,
           reporter,
           {:unavailable, :not_signed_in, remedy}
         )}
      )
    end)

    assert_receive {:reported, :ok}

    assert {:ok, %Entry{status: %Status{availability: {:unavailable, :not_signed_in, ^remedy}}}} =
             InferenceRouteRegistry.lookup(registry, "fixture")

    assert {:error, :invalid_status} =
             InferenceRouteRegistry.report_status(registry, reporter, :ready)

    forged = %{reporter | token: make_ref()}

    assert {:error, :stale_reporter} =
             InferenceRouteRegistry.report_status(registry, forged, {:ready, "x"})

    :ok = InferenceRouteRegistry.unregister_source(registry, {:extension, :one})

    assert {:error, :unknown_route} =
             InferenceRouteRegistry.report_status(registry, reporter, {:ready, "x"})
  end

  test "refresh records ready, unavailable, failing, and slow routes without blocking",
       %{registry: registry} do
    for id <- ~w(ready offline raises hangs invalid badcred) do
      {:ok, _reporter} = InferenceRouteRegistry.register(registry, spec({:extension, :one}, id))
    end

    modes = %{"raises" => "raise", "hangs" => "hang", "invalid" => "invalid"}

    credential_fn = fn
      "badcred" ->
        {:error, "Fix routes.badcred.env in credentials.json."}

      route_id ->
        {:ok, %{env: %{"FIXTURE_AVAILABILITY" => Map.get(modes, route_id, "ready")}}}
    end

    entries =
      InferenceRouteRegistry.refresh_availability(registry,
        timeout: 200,
        route_credential_fn: credential_fn
      )

    statuses = Map.new(entries, &{&1.spec.id, &1.status.availability})

    assert statuses["ready"] == {:ready, "fixture@example.com"}
    assert statuses["offline"] == {:unavailable, :not_signed_in, FixtureInferenceRoute.remedy()}

    assert statuses["badcred"] ==
             {:unavailable, :invalid_route_credential,
              "Fix routes.badcred.env in credentials.json."}

    for id <- ~w(raises hangs invalid) do
      assert {:unavailable, :availability_check_failed, remedy} = statuses[id]
      assert remedy =~ "Could not check Fixture Route"
    end
  end

  test "refresh results do not overwrite a route that was replaced meanwhile",
       %{registry: registry} do
    {:ok, _reporter} = InferenceRouteRegistry.register(registry, spec({:extension, :one}))
    [entry] = InferenceRouteRegistry.list(registry)
    :ok = InferenceRouteRegistry.unregister_source(registry, {:extension, :one})

    assert :ok =
             GenServer.call(
               registry,
               {:refreshed, "fixture", entry.registration, entry.availability_version,
                Status.unknown(), {:error, :kept}}
             )

    assert InferenceRouteRegistry.list(registry) == []
  end

  test "source cleanup removes only that source's routes", %{registry: registry} do
    {:ok, _reporter} =
      InferenceRouteRegistry.register(registry, spec({:extension, :one}, "first"))

    {:ok, _reporter} =
      InferenceRouteRegistry.register(registry, spec({:extension, :two}, "second"))

    callbacks = %{
      inference_routes: &InferenceRouteRegistry.unregister_source(registry, &1)
    }

    assert :ok =
             ContributionCleanup.finalize_source({:extension, :one}, :inference_routes,
               callbacks: callbacks
             )

    assert [%Entry{spec: %{id: "second"}}] = InferenceRouteRegistry.list(registry)
  end

  test "the application registry participates in source cleanup" do
    assert Map.has_key?(ContributionCleanup.merge_callbacks(%{}), :inference_routes)
  end

  test "route errors are classified by the route, with a safe fallback", %{registry: registry} do
    {:ok, _reporter} = InferenceRouteRegistry.register(registry, spec({:extension, :one}))

    assert {:rate_limited, "Fixture route is rate limited."} =
             InferenceRouteRegistry.classify_error(registry, "fixture", :rate_limited)

    assert {:provider_error, "The fixture route failed."} =
             InferenceRouteRegistry.classify_error(registry, "fixture", :anything)

    assert {:unreachable, message} =
             InferenceRouteRegistry.classify_error(registry, "missing", :anything)

    assert message =~ "no extension provides it"
  end

  describe "plan usage, status events, and model refresh" do
    setup do
      events = :"route_events_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :duplicate, name: events}, id: events)
      name = :"route_registry_events_#{System.unique_integer([:positive])}"
      start_supervised!({InferenceRouteRegistry, name: name, events: events}, id: name)
      :ok = Minga.Events.subscribe(:inference_route_status_changed, registry: events)
      %{registry: name}
    end

    defp window(attrs) do
      Keyword.merge(
        [kind: "five_hour", utilization: 0.82, resets_at: nil, status: :warning],
        attrs
      )
    end

    test "usage is reported from any process, kept apart from availability, and published",
         %{registry: registry} do
      {:ok, reporter} = InferenceRouteRegistry.register(registry, spec({:extension, :one}))
      parent = self()

      spawn(fn ->
        send(
          parent,
          {:reported, InferenceRouteRegistry.report_usage(registry, reporter, [window([])])}
        )
      end)

      assert_receive {:reported, :ok}

      assert_receive {:minga_event, :inference_route_status_changed,
                      %StatusChangedEvent{
                        route_id: "fixture",
                        status: %Status{plan_usage: [usage]}
                      }}

      assert %PlanWindow{kind: "five_hour", utilization: 0.82, status: :warning} = usage

      :ok = InferenceRouteRegistry.report_status(registry, reporter, {:ready, "me"})

      assert {:ok, %Entry{status: %Status{availability: {:ready, "me"}, plan_usage: [^usage]}}} =
               InferenceRouteRegistry.lookup(registry, "fixture")

      InferenceRouteRegistry.refresh_availability(registry)

      assert {:ok, %Entry{status: %Status{plan_usage: [^usage]}}} =
               InferenceRouteRegistry.lookup(registry, "fixture")
    end

    test "no usage data, an unchanged report, and invalid windows publish nothing",
         %{registry: registry} do
      {:ok, reporter} = InferenceRouteRegistry.register(registry, spec({:extension, :one}))

      assert :ok = InferenceRouteRegistry.report_usage(registry, reporter, [])
      refute_receive {:minga_event, :inference_route_status_changed, _event}, 50

      assert {:ok, %Entry{status: %Status{plan_usage: nil}}} =
               InferenceRouteRegistry.lookup(registry, "fixture")

      for {field, value} <- [
            utilization: 1.2,
            utilization: -0.1,
            status: :blocked,
            kind: "",
            resets_at: "soon"
          ] do
        assert {:error, {:invalid_plan_window, ^field}} =
                 InferenceRouteRegistry.report_usage(registry, reporter, [
                   window([{field, value}])
                 ])
      end

      :ok = InferenceRouteRegistry.report_usage(registry, reporter, [window([])])
      assert_receive {:minga_event, :inference_route_status_changed, _event}
      :ok = InferenceRouteRegistry.report_usage(registry, reporter, [window([])])
      refute_receive {:minga_event, :inference_route_status_changed, _event}, 50

      :ok = InferenceRouteRegistry.unregister_source(registry, {:extension, :one})

      assert {:error, :unknown_route} =
               InferenceRouteRegistry.report_usage(registry, reporter, [window([])])
    end

    test "refreshing a route lists its models again in the check worker", %{registry: registry} do
      {:ok, models} = Agent.start_link(fn -> [FixtureInferenceRoute.model(id: "old")] end)

      {:ok, _reporter} =
        InferenceRouteRegistry.register(registry, spec({:extension, :one}),
          config: [models_agent: models]
        )

      Agent.update(models, fn _old -> [FixtureInferenceRoute.model(id: "new")] end)
      InferenceRouteRegistry.refresh_availability(registry)

      assert {:ok, %Entry{models: [%{id: "new"}]}} =
               InferenceRouteRegistry.lookup(registry, "fixture")

      Agent.update(models, fn _new -> [] end)
      InferenceRouteRegistry.refresh_availability(registry)

      assert {:ok, %Entry{models: [%{id: "new"}]}} =
               InferenceRouteRegistry.lookup(registry, "fixture")
    end

    test "a slow model listing keeps the previous models and never changes availability",
         %{registry: registry} do
      {:ok, models} = Agent.start_link(fn -> [FixtureInferenceRoute.model(id: "kept")] end)

      {:ok, _reporter} =
        InferenceRouteRegistry.register(registry, spec({:extension, :one}),
          config: [models_agent: models]
        )

      Agent.update(models, fn _models -> :block end)
      InferenceRouteRegistry.refresh_availability(registry, timeout: 1_000, models_timeout: 100)

      assert {:ok,
              %Entry{
                models: [%{id: "kept"}],
                status: %Status{availability: {:ready, "fixture@example.com"}}
              }} = InferenceRouteRegistry.lookup(registry, "fixture")
    end

    test "a refresh started before a re-register is discarded, even for the same spec",
         %{registry: registry} do
      {:ok, _reporter} = InferenceRouteRegistry.register(registry, spec({:extension, :one}))
      {:ok, old} = InferenceRouteRegistry.lookup(registry, "fixture")

      {:ok, _reporter} =
        InferenceRouteRegistry.register(registry, spec({:extension, :one}),
          config: [models: [FixtureInferenceRoute.model(id: "fresh")]]
        )

      {:ok, unavailable} = Status.new({:unavailable, :stale, "Stale check."})

      :ok =
        GenServer.call(
          registry,
          {:refreshed, "fixture", old.registration, old.availability_version, unavailable,
           {:ok, [FixtureInferenceRoute.model(id: "stale")]}}
        )

      assert {:ok, %Entry{models: [%{id: "fresh"}], status: %Status{availability: :unknown}}} =
               InferenceRouteRegistry.lookup(registry, "fixture")
    end

    test "a refresh that finishes after a newer report keeps the newer availability",
         %{registry: registry} do
      {:ok, reporter} = InferenceRouteRegistry.register(registry, spec({:extension, :one}))
      {:ok, before_report} = InferenceRouteRegistry.lookup(registry, "fixture")

      :ok = InferenceRouteRegistry.report_status(registry, reporter, {:ready, "newer"})
      {:ok, unavailable} = Status.new({:unavailable, :stale, "Stale check."})

      :ok =
        GenServer.call(
          registry,
          {:refreshed, "fixture", before_report.registration, before_report.availability_version,
           unavailable, {:ok, [FixtureInferenceRoute.model(id: "listed")]}}
        )

      assert {:ok,
              %Entry{models: [%{id: "listed"}], status: %Status{availability: {:ready, "newer"}}}} =
               InferenceRouteRegistry.lookup(registry, "fixture")
    end

    test "a refresh can be limited to one route", %{registry: registry} do
      for id <- ~w(first second) do
        {:ok, _reporter} = InferenceRouteRegistry.register(registry, spec({:extension, :one}, id))
      end

      InferenceRouteRegistry.refresh_availability(registry, route_ids: ["second"])

      statuses =
        Map.new(InferenceRouteRegistry.list(registry), &{&1.spec.id, &1.status.availability})

      assert statuses == %{"first" => :unknown, "second" => {:ready, "fixture@example.com"}}
    end
  end

  describe "Minga.Extension.ModelRoutes" do
    test "registers under the calling extension's invocation source and returns a reporter",
         %{registry: registry} do
      attrs = [id: "fixture", module: FixtureInferenceRoute, display_name: "Fixture Route"]

      assert {:error, :no_extension_context} = ModelRoutes.register(attrs, registry: registry)

      assert {:ok, %Reporter{} = reporter} =
               InvocationContext.with_source({:extension, :bridge}, fn ->
                 ModelRoutes.register(Keyword.put(attrs, :source, {:extension, :spoofed}),
                   registry: registry
                 )
               end)

      assert {:ok, %Entry{spec: %{source: {:extension, :bridge}}}} =
               InferenceRouteRegistry.lookup(registry, "fixture")

      assert :ok = ModelRoutes.report_status(reporter, {:ready, "me"}, registry: registry)

      assert :ok =
               ModelRoutes.report_usage(
                 reporter,
                 [%{kind: "seven_day", utilization: 0.4, resets_at: nil, status: :allowed}],
                 registry: registry
               )

      setup = [
        id: "with_setup",
        module: FixtureInferenceRoute,
        display_name: "Setup Route",
        setup_action: [label: "Use Setup Route", description: "Sign in with its CLI."]
      ]

      assert {:ok, _setup_reporter} =
               InvocationContext.with_source({:extension, :bridge}, fn ->
                 ModelRoutes.register(setup, registry: registry)
               end)

      assert {:ok, %Entry{spec: %{setup_action: %{label: "Use Setup Route"}}}} =
               InferenceRouteRegistry.lookup(registry, "with_setup")

      assert {:ok, %Entry{status: %Status{availability: {:ready, "me"}}}} =
               InferenceRouteRegistry.lookup(registry, "fixture")
    end
  end
end
