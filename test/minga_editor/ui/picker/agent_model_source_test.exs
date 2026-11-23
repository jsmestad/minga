defmodule MingaEditor.UI.Picker.AgentModelSourceTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Credentials.Secret
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.InferenceRoute.Status
  alias MingaAgent.InferenceRoute.StatusChangedEvent
  alias MingaAgent.InferenceRouteRegistry
  alias MingaAgent.ModelResolver
  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Credential.ApiKey
  alias MingaAgent.ModelSelection.Credential.OAuth
  alias MingaAgent.Providers.Native
  alias MingaAgent.Session
  alias MingaAgent.Test.FixtureInferenceRoute
  alias MingaAgent.Test.ModelPickerSession
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.RuntimeState
  alias MingaAgent.Session.{ConnectionSnapshot, ConnectionTarget}
  alias MingaEditor.Agent.ConnectionSetup
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.{Policy, Request}
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Agent.SlashCommand
  alias MingaEditor.Agent.UIState
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Picker, as: PickerState
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.AgentConnectionSource
  alias MingaEditor.UI.Picker.AgentModelSource
  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item.Status, as: ItemStatus
  alias MingaEditor.UI.Theme
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  defmodule RejectingSession do
    use GenServer

    @spec start_link({[ModelCandidate.t()], String.t()}) :: GenServer.on_start()
    def start_link(fixture), do: GenServer.start_link(__MODULE__, fixture)

    @impl GenServer
    def init(message), do: {:ok, message}

    @impl GenServer
    def handle_call(:begin_model_discovery, _from, fixture), do: {:reply, :local, fixture}

    def handle_call(:inference_route_context, _from, fixture),
      do: {:reply, {:error, :unsupported}, fixture}

    def handle_call(:get_available_models, _from, {candidates, _message} = fixture),
      do: {:reply, {:ok, candidates}, fixture}

    def handle_call(
          {:set_model_for_target, %ConnectionTarget{session: session}, _selection},
          _from,
          {_candidates, message} = fixture
        )
        when session == self(), do: {:reply, {:error, message}, fixture}
  end

  test "the chooser status names a specific startup resolution failure and keeps the plain no-model label" do
    session = start_supervised!({RejectingSession, {[], "unused"}})
    missing = {:model_not_found, "openai:no-such-model"}

    unresolved = %{
      connection(session)
      | credential_readiness: :unconfigured,
        provider_phase: :stopped,
        problem: {:resolution, missing}
    }

    assert {:ok, _items, %{status: status}} = AgentModelSource.async_fetch(context(unresolved, 1))
    assert status == ModelResolver.message(missing)
    assert status =~ "openai:no-such-model"

    no_model = %{unresolved | problem: {:resolution, :no_available_model}}

    assert {:ok, _items,
            %{status: "Choose a model or connect a provider. Your draft will not be sent."}} =
             AgentModelSource.async_fetch(context(no_model, 1))
  end

  test "an API route row shows a ready chip and leads with its route, price, and context" do
    selection =
      ModelSelectionFixture.selection(
        model_provider: "openai",
        model_id: "gpt-4",
        display_name: "GPT-4",
        base_url: "https://api.openai.com/v1",
        transport: "http",
        reasoning: %{effort: "low", options: ["off", "low", "high"]},
        limits: %{context: 128_000, input: nil, output: 8_192, request_output: 2_048},
        capabilities: %{tools: true, images: false, streaming: :unknown},
        cost: %{input: 2.5, output: 10}
      )

    candidate = %ModelCandidate{selection: selection, favorite: true, current: true}
    session = start_supervised!({ModelPickerSession, [candidate]})

    assert [item] = model_items(context(connection(session), 1))
    assert item.id == ModelSelection.id(selection)
    assert item.active
    assert item.annotation == "★ favorite"
    assert item.status == ItemStatus.new(:ready, "Ready")

    # The route is the row's group, so the description starts with the price. Only a capability the
    # model lacks is named; supported and unknown ones are not.
    assert item.group == "openai API"
    assert item.description == "$2.5/10 per MTok · 128k ctx · thinking low · no images"
    assert item.search_text =~ "openai API"

    # The exact endpoint and credential stay searchable without filling the row.
    assert item.search_text =~ "https://api.openai.com/v1/chat/completions"
    assert item.search_text =~ "openai:env"
  end

  test "/model discovers Apple off the editor path and only activates it while ready" do
    readiness = :atomics.new(1, [])
    :atomics.put(readiness, 1, 1)
    owner = self()

    session =
      start_supervised!(
        {Session,
         provider: Native,
         persist?: false,
         hooks_enabled?: false,
         credentials_snapshot_fn: fn -> Snapshot.new(%{}, nil) end,
         provider_opts: [
           mcp_enabled?: false,
           model_resolver_opts: [
             models: [],
             apple_availability_fn: fn ->
               status = :atomics.get(readiness, 1)
               send(owner, {:apple_probe, self()})

               case status do
                 1 ->
                   {:ok, 4_096}

                 0 ->
                   {:error, :disabled}

                 2 ->
                   receive do
                     {:finish_apple_probe, result} -> result
                   end
               end
             end
           ]
         ]}
      )

    %{connection: connection} = Session.editor_snapshot(session)
    assert ConnectionSnapshot.status(connection) == :unconfigured
    refute_received {:apple_probe, _}

    task_supervisor = start_supervised!({Task.Supervisor, []})
    scheduler = start_supervised!({EffectScheduler, task_supervisor: task_supervisor})
    :ok = EffectScheduler.attach(scheduler, self())
    {state, workspace_id} = editor_state(connection, "unknown", scheduler)
    assert {:ok, opened} = SlashCommand.execute(state, "/model")
    assert_receive {:apple_probe, worker}, 1_000
    assert worker != self() and worker != session

    assert_receive {:effect_result, ^scheduler,
                    %Outcome{value: {:completed, {:ok, items, candidates, meta}}} = fetched},
                   1_000

    assert [apple] = Enum.filter(items, &model_choice?/1)
    assert apple.label == "Apple Intelligence (On Device)"
    assert apple.status == ItemStatus.new(:ready, "Ready")

    assert apple.group == "On device"
    assert apple.description == "4k ctx · no thinking controls · compact file tools, no images"

    assert [completion] = SlashCommand.completion_candidates(state, "model apple")
    assert completion.insert == "model #{apple.id}"
    assert completion.description =~ "On device"
    assert completion.description =~ "No credentials"
    refute_received {:apple_probe, _}

    assert {:noreply, opened} =
             MingaEditor.handle_info({:effect_result, scheduler, fetched}, opened)

    :atomics.put(readiness, 1, 2)
    opened = AgentModelSource.on_select(apple, opened)

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{id: reject_id, resource: {:agent_connection, ^session}},
                      value: :running
                    }},
                   1_000

    assert_receive {:apple_probe, rejection_worker}, 1_000
    assert rejection_worker not in [owner, session]
    assert [^completion] = SlashCommand.completion_candidates(opened, "model apple")
    refute_received {:apple_probe, _}

    :atomics.put(readiness, 1, 0)
    send(rejection_worker, {:finish_apple_probe, {:error, :disabled}})

    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %Request{id: ^reject_id}, value: {:failed, message}} =
                      rejected},
                   1_000

    assert message =~ "Enable it in System Settings"
    assert Session.model_selection(session) == nil
    assert SlashCommand.completion_candidates(opened, "model apple") == []
    refute_received {:apple_probe, _}

    assert {:noreply, opened} =
             MingaEditor.handle_info({:effect_result, scheduler, rejected}, opened)

    ctx = context(connection, workspace_id)
    assert {:ok, unavailable, %{status: unavailable_message}} = AgentModelSource.async_fetch(ctx)
    assert_received {:apple_probe, ^owner}
    assert unavailable_message =~ "Enable it in System Settings"
    refute Enum.any?(unavailable, &model_choice?/1)

    assert {:ok, superseded, _candidates, %{}} =
             AgentModelSource.for_publication({:ok, items, candidates, meta}, session)

    refute Enum.any?(superseded, &model_choice?/1)

    :atomics.put(readiness, 1, 1)
    assert [apple] = model_items(ctx)
    assert_received {:apple_probe, ^owner}
    opened = AgentModelSource.on_select(apple, opened)

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{id: apply_id, resource: {:agent_connection, ^session}},
                      value: :running
                    }},
                   1_000

    assert_receive {:apple_probe, activation_worker}, 1_000
    assert activation_worker not in [owner, session]

    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %Request{id: ^apply_id}, value: {:completed, :applied}} =
                      applied},
                   1_000

    refute_received {:apple_probe, _}

    assert {:noreply, _opened} =
             MingaEditor.handle_info({:effect_result, scheduler, applied}, opened)

    assert %ModelSelection{credential: :none, route: %{request_provider: :apple}} =
             Session.model_selection(session)

    assert Session.status(session) == :idle
  end

  describe "connection actions" do
    # An API-key route with a stored key and a signed-in ChatGPT route.
    defp connected_candidates do
      api =
        ModelSelectionFixture.selection(
          model_id: "gpt-4o",
          display_name: "GPT-4o",
          credential: ApiKey.new("openai", :file)
        )

      codex =
        ModelSelectionFixture.selection(
          request_provider: :openai_codex,
          model_id: "gpt-5",
          display_name: "GPT-5"
        )

      for selection <- [api, codex],
          do: %ModelCandidate{selection: selection, favorite: false, current: false}
    end

    test "with a usable model, /model lists the models and one row for connection actions" do
      session = start_supervised!({ModelPickerSession, connected_candidates()})
      ctx = context(connection(session), 1)
      items = AgentModelSource.candidates(ctx)

      assert Enum.map(items, & &1.label) == ["GPT-4o", "GPT-5", "Connect another provider…"]
      assert connect_row(items).status == nil
      # Each route is a section; the connection row sits in its own trailing section.
      assert Enum.map(items, & &1.group) == ["openai API", "ChatGPT", "Connections"]
      refute Enum.at(items, 1).description =~ "ChatGPT"

      child = items |> connect_row() |> child_items(ctx)
      labels = Enum.map(child, & &1.label)

      # Connected providers offer account actions instead of a first sign-in.
      refute "Sign in with ChatGPT" in labels
      refute "Connect openai with API key" in labels

      for label <- [
            "Sign in to ChatGPT again",
            "Sign in to ChatGPT again manually",
            "Sign out of ChatGPT",
            "Replace openai API key",
            "Remove openai API key",
            "Connect anthropic with API key",
            "Retry current connection"
          ] do
        assert label in labels, "missing #{label} in #{inspect(labels)}"
      end

      intents = Map.new(child, &{&1.label, &1.meta.intent})
      assert intents["Sign in to ChatGPT again"] == {:connect, :oauth_browser}
      assert intents["Sign out of ChatGPT"] == {:sign_out, "openai_codex"}
      assert intents["Replace openai API key"] == {:connect, {:api_key, "openai"}}
      assert intents["Remove openai API key"] == {:sign_out, "openai"}

      groups = Map.new(child, &{&1.label, &1.group})
      assert groups["Sign out of ChatGPT"] == "ChatGPT"
      assert groups["Remove openai API key"] == "API keys"
      assert groups["Connect anthropic with API key"] == "API keys"
      assert groups["Retry current connection"] == "Connection"

      assert child |> Enum.map(& &1.group) |> Enum.dedup() == [
               "ChatGPT",
               "API keys",
               "Connection"
             ]

      signed_in = Enum.find(child, &(&1.label == "Sign in to ChatGPT again"))
      assert signed_in.status == ItemStatus.new(:ready, "Signed in")
    end

    test "with no listed model, the connection actions stay in /model as first-run setup" do
      session = start_supervised!({ModelPickerSession, []})

      labels =
        context(connection(session), 1) |> AgentModelSource.candidates() |> Enum.map(& &1.label)

      assert Enum.take(labels, 2) == ["Sign in with ChatGPT", "Sign in with ChatGPT manually"]
      assert "Connect openai with API key" in labels
      assert Enum.take(labels, -1) == ["Retry current connection"]
      refute "Connect another provider…" in labels
    end

    test "a setup in progress stays in /model beside the models" do
      session = start_supervised!({ModelPickerSession, connected_candidates()})
      connecting = %{connection(session) | operation: {:connecting, make_ref()}}
      labels = context(connecting, 1) |> AgentModelSource.candidates() |> Enum.map(& &1.label)

      assert labels == ["GPT-4o", "GPT-5", "Cancel connection setup", "Connect another provider…"]

      groups = context(connecting, 1) |> AgentModelSource.candidates() |> Enum.map(& &1.group)
      assert groups == ["openai API", "ChatGPT", "Setup in progress", "Connections"]
    end

    test "Escape in the connection picker returns to /model with its query and selection" do
      session = start_supervised!({ModelPickerSession, connected_candidates()})
      task_supervisor = start_supervised!({Task.Supervisor, []})
      scheduler = start_supervised!({EffectScheduler, task_supervisor: task_supervisor})
      :ok = EffectScheduler.attach(scheduler, self())
      {state, _workspace_id} = editor_state(connection(session), "GPT-4o", scheduler)

      assert {:ok, state} = SlashCommand.execute(state, "/model")
      assert {:ok, state} = land_fetch(state, scheduler)
      connect_id = {:connection, :connect_another_provider}

      state =
        PickerUI.update_picker(state, fn ps ->
          picker = Picker.filter(ps.picker, "connect")
          PickerState.update_picker(ps, Picker.select_id(picker, connect_id))
        end)

      state = PickerUI.handle_key(state, 13, 0)
      assert %{source: AgentConnectionSource, load_status: :loading} = picker_ui(state)
      assert picker_ui(state).picker.query == ""
      assert {:ok, state} = land_fetch(state, scheduler)
      assert Enum.any?(picker_ui(state).picker.items, &(&1.label == "Sign out of ChatGPT"))

      state = PickerUI.handle_key(state, 27, 0)
      model_picker = picker_ui(state)

      assert model_picker.source == AgentModelSource
      assert model_picker.load_status == :ready
      assert model_picker.picker.query == "connect"
      assert Picker.selected_id(model_picker.picker) == connect_id

      # The rows come back as they were; returning does not discover models again.
      assert Enum.map(model_picker.picker.items, & &1.label) ==
               ["GPT-4o", "GPT-5", "Connect another provider…"]

      refute_receive {:effect_result, ^scheduler, _outcome}, 50
    end

    test "a route status change while the connection picker is open lists /model again on Escape" do
      session = start_supervised!({ModelPickerSession, connected_candidates()})
      task_supervisor = start_supervised!({Task.Supervisor, []})
      scheduler = start_supervised!({EffectScheduler, task_supervisor: task_supervisor})
      :ok = EffectScheduler.attach(scheduler, self())
      {state, _workspace_id} = editor_state(connection(session), "GPT-4o", scheduler)

      assert {:ok, state} = SlashCommand.execute(state, "/model")
      assert {:ok, state} = land_fetch(state, scheduler)
      connect_id = {:connection, :connect_another_provider}

      state =
        PickerUI.update_picker(state, fn ps ->
          picker = Picker.filter(ps.picker, "connect")
          PickerState.update_picker(ps, Picker.select_id(picker, connect_id))
        end)

      state = PickerUI.handle_key(state, 13, 0)
      assert {:ok, state} = land_fetch(state, scheduler)

      # The event arrives while the child is open; the child itself is not listed again.
      state = AgentModelSource.route_status_changed(state)
      assert picker_ui(state).source == AgentConnectionSource
      assert picker_ui(state).load_status == :ready
      refute_receive {:effect_result, ^scheduler, _outcome}, 50

      state = PickerUI.handle_key(state, 27, 0)
      assert %{source: AgentModelSource, load_status: :loading} = picker_ui(state)
      assert %{catalog: :listed, route_status: :current} = picker_ui(state).context

      assert {:ok, state} = land_fetch(state, scheduler)
      model_picker = picker_ui(state)
      assert model_picker.load_status == :ready
      assert model_picker.picker.query == "connect"
      assert Picker.selected_id(model_picker.picker) == connect_id
    end
  end

  describe "contributed model routes" do
    setup do
      registry = :"picker_inference_routes_#{System.unique_integer([:positive])}"
      start_supervised!({InferenceRouteRegistry, name: registry})

      for {id, name} <- [{"fixture", "Fixture Route"}, {"offline", "Offline Route"}] do
        {:ok, _reporter} =
          InferenceRouteRegistry.register(registry,
            source: {:extension, :fixture_bridge},
            id: id,
            module: FixtureInferenceRoute,
            display_name: name
          )
      end

      %{registry: registry}
    end

    test "rows show route readiness as a chip and the remedy, thinking, and capabilities as detail",
         %{
           registry: registry
         } do
      InferenceRouteRegistry.refresh_availability(registry)

      candidates =
        ModelResolver.candidates(
          backend_spec: MingaAgent.ProviderPacks.Native.spec(),
          credential_snapshot: Snapshot.new(%{}, nil),
          models: [],
          inference_routes: registry
        )

      session = start_supervised!({ModelPickerSession, candidates})
      items = model_items(context(connection(session), 1))
      ready = Enum.find(items, &(&1.group == "Fixture Route"))
      offline = Enum.find(items, &(&1.group == "Offline Route"))

      assert ready.label == "Fixture Model"
      assert ready.status == ItemStatus.new(:checking, "Checking…")

      assert ready.description ==
               "fixture@example.com · checking plan usage · 200k ctx · thinking off · tools, images, streaming"

      assert offline.status == ItemStatus.new(:error, "Unavailable")

      assert offline.description =~
               ~r/^#{Regex.escape(FixtureInferenceRoute.remedy())} · 200k ctx/

      refute offline.description =~ "Unavailable"
      assert Enum.all?([ready, offline], &(request_provider(&1) == :contributed))
    end

    test "routes that are not ready keep the connection actions in /model", %{registry: registry} do
      candidates =
        ModelResolver.candidates(
          backend_spec: MingaAgent.ProviderPacks.Native.spec(),
          credential_snapshot: Snapshot.new(%{}, nil),
          models: [],
          inference_routes: registry
        )

      session = start_supervised!({ModelPickerSession, candidates})
      items = AgentModelSource.candidates(context(connection(session), 1))

      # Neither route was checked, so no listed model can be used yet.
      assert Enum.any?(items, &model_choice?/1)
      assert "Sign in with ChatGPT" in Enum.map(items, & &1.label)
      refute "Connect another provider…" in Enum.map(items, & &1.label)
    end

    test "contributed rows are runtime-gated discovery that a superseded fetch drops", %{
      registry: registry
    } do
      candidates =
        ModelResolver.candidates(
          backend_spec: MingaAgent.ProviderPacks.Native.spec(),
          credential_snapshot: Snapshot.new(%{}, nil),
          models: [],
          inference_routes: registry
        )

      session = start_supervised!({ModelPickerSession, candidates})
      items = model_items(context(connection(session), 1))
      assert items != []
      validity = :atomics.new(1, [])

      assert {:ok, [], [], %{}} =
               AgentModelSource.for_publication(
                 {:ok, items, [], %{model_discovery: {session, validity}}},
                 session
               )
    end

    test "selecting an unavailable route keeps the active model and shows the route's remedy",
         %{registry: registry} do
      session =
        start_supervised!(
          {Session,
           provider: Native,
           persist?: false,
           hooks_enabled?: false,
           credentials_snapshot_fn: fn -> Snapshot.new(%{}, nil) end,
           provider_opts: [
             mcp_enabled?: false,
             model_resolver_opts: [
               models: [],
               inference_routes: registry,
               apple_availability_fn: fn -> {:error, :unsupported} end
             ]
           ]}
        )

      %{connection: connection} = Session.editor_snapshot(session)
      task_supervisor = start_supervised!({Task.Supervisor, []})
      scheduler = start_supervised!({EffectScheduler, task_supervisor: task_supervisor})
      :ok = EffectScheduler.attach(scheduler, self())
      {state, workspace_id} = editor_state(connection, "Prior Model", scheduler)

      items = model_items(context(connection, workspace_id))
      offline = Enum.find(items, &(&1.group == "Offline Route"))
      assert offline.status == ItemStatus.new(:error, "Unavailable")
      assert offline.description =~ FixtureInferenceRoute.remedy()

      state = AgentModelSource.on_select(offline, state)

      assert_receive {:effect_result, ^scheduler, %Outcome{value: {:failed, message}} = outcome},
                     1_000

      assert message == FixtureInferenceRoute.remedy()
      assert Session.model_selection(session) == nil

      assert {:noreply, state} =
               MingaEditor.handle_info({:effect_result, scheduler, outcome}, state)

      assert state.workspace.agent_ui.panel.model_name == "Prior Model"
      assert state.shell_runtime.state.notice.message == FixtureInferenceRoute.remedy()
    end
  end

  describe "subscription route setup and plan usage" do
    setup do
      suffix = System.unique_integer([:positive])
      events = :"picker_route_events_#{suffix}"
      start_supervised!({Registry, keys: :duplicate, name: events}, id: events)
      registry = :"picker_setup_routes_#{suffix}"
      start_supervised!({InferenceRouteRegistry, name: registry, events: events})

      routes = [
        {"setup#{suffix}", "Setup Fixture"},
        {"offline#{suffix}", "Offline Setup"}
      ]

      reporters =
        Map.new(routes, fn {id, name} ->
          {:ok, reporter} =
            InferenceRouteRegistry.register(registry,
              source: {:extension, :fixture_bridge},
              id: id,
              module: FixtureInferenceRoute,
              display_name: name,
              setup_action: [
                label: "Use #{name}",
                description: "Sign in with the fixture CLI. Minga never sees your login."
              ]
            )

          {id, reporter}
        end)

      observer = FixtureInferenceRoute.observer_env(self())

      routes_file = %{
        "routes" => %{"setup#{suffix}" => %{"env" => %{"FIXTURE_OBSERVER" => observer}}}
      }

      session =
        start_supervised!(
          {Session,
           provider: Native,
           persist?: false,
           hooks_enabled?: false,
           credentials_snapshot_fn: fn -> Snapshot.new(%{}, nil) end,
           provider_opts: [
             mcp_enabled?: false,
             credential_opts: [credentials_reader: fn _path -> {:ok, routes_file} end, env: %{}],
             model_resolver_opts: [
               models: [],
               inference_routes: registry,
               apple_availability_fn: fn -> {:error, :unsupported} end
             ]
           ]}
        )

      %{
        events: events,
        registry: registry,
        reporters: reporters,
        session: session,
        setup_id: "setup#{suffix}",
        offline_id: "offline#{suffix}"
      }
    end

    defp setup_rows(items), do: Enum.filter(items, &match?({:route_setup, _id}, &1.id))

    test "setup rows show each route's readiness and never ask for a secret", ctx do
      %{connection: connection} = Session.editor_snapshot(ctx.session)
      ctx_1 = context(connection, 1)
      items = AgentModelSource.candidates(ctx_1)

      # Discovery found a ready route, so its model is usable and the setup rows move behind
      # "Connect another provider…".
      assert setup_rows(items) == []
      assert connect_row(items)
      rows = items |> connect_row() |> child_items(ctx_1) |> setup_rows()

      ready = Enum.find(rows, &(&1.label == "Use Setup Fixture"))
      offline = Enum.find(rows, &(&1.label == "Use Offline Setup"))

      # Readiness is the chip; the setup text and the account or remedy stay readable as detail.
      assert ready.status == ItemStatus.new(:ready, "Ready")

      assert ready.description ==
               "Sign in with the fixture CLI. Minga never sees your login. · fixture@example.com"

      assert offline.status == ItemStatus.new(:error, "Unavailable")
      assert offline.description =~ FixtureInferenceRoute.remedy()
      assert ready.meta.intent == {:check_route, ctx.setup_id, "Setup Fixture"}

      assert Enum.all?(rows, &match?({:check_route, _id, _name}, &1.meta.intent))
    end

    test "selecting a setup row checks the route on the effect worker and reports the result",
         ctx do
      %{connection: connection} = Session.editor_snapshot(ctx.session)
      task_supervisor = start_supervised!({Task.Supervisor, []})
      scheduler = start_supervised!({EffectScheduler, task_supervisor: task_supervisor})
      :ok = EffectScheduler.attach(scheduler, self())
      {state, workspace_id} = editor_state(connection, "Prior Model", scheduler)

      picker_context = context(connection, workspace_id)
      items = AgentModelSource.candidates(picker_context)

      [row | _rest] =
        items
        |> connect_row()
        |> child_items(picker_context)
        |> setup_rows()
        |> Enum.filter(&(&1.label == "Use Setup Fixture"))

      assert_receive {:fixture_availability_checked, _id, _discovery_caller}

      state = AgentConnectionSource.on_select(row, state)
      assert state.shell_runtime.state.notice.message == "Checking Setup Fixture…"

      setup_id = ctx.setup_id
      assert_receive {:fixture_availability_checked, ^setup_id, caller}, 1_000
      assert caller not in [self(), ctx.session]

      assert_receive {:effect_result, ^scheduler,
                      %Outcome{value: {:completed, {:notice, message}}} = outcome},
                     1_000

      assert message == "Setup Fixture is ready: fixture@example.com."

      assert {:noreply, state} =
               MingaEditor.handle_info({:effect_result, scheduler, outcome}, state)

      assert state.shell_runtime.state.notice.message == message
      assert state.workspace.agent_ui.panel.model_name == "Prior Model"
    end

    test "a plan limit adds a notification whose action opens the model picker", ctx do
      %{connection: connection} = Session.editor_snapshot(ctx.session)
      {state, _workspace_id} = editor_state(connection, "Prior Model", nil)
      message = "Setup Fixture plan limit reached. Resets at 3:40 PM. Switch model to continue."

      state =
        MingaEditor.Agent.Events.dispatch(state, ctx.session, {:model_limit_reached, message})

      assert [notification] =
               Enum.filter(state.feedback.notifications.items, &(&1.id == "agent:model_limit"))

      assert notification.body == message

      assert [%{id: "choose_model", label: "Choose another model", dispatch: action}] =
               notification.actions

      assert action == {:command, :agent_pick_model}

      # The action runs the same command the GUI dispatches; the draft must survive it.
      ui =
        state.workspace.agent_ui
        |> MingaEditor.Agent.PromptBuffer.ensure()
        |> MingaEditor.Agent.PromptBuffer.insert_char("keep my draft")

      state = MingaEditor.Shell.Traditional.Workflow.install_agent_ui(state, ui)

      assert MingaEditor.Agent.PromptBuffer.prompt_text(state.workspace.agent_ui) ==
               "keep my draft"

      opened = MingaEditor.Commands.execute(state, :agent_pick_model)

      assert MingaEditor.Agent.PromptBuffer.prompt_text(opened.workspace.agent_ui) ==
               "keep my draft"

      assert {:picker, %{picker_ui: %{source: AgentModelSource}}} =
               opened.shell_runtime.state.modal

      assert {:ok, %Minga.Command{}} =
               Minga.Command.Registry.lookup(Minga.Command.Registry, :agent_pick_model)
    end

    test "an unchecked route says so in its chip and keeps its plan reset as detail", ctx do
      rows = route_items(ctx.registry)
      assert rows["Setup Fixture"].status == ItemStatus.new(:neutral, "Not checked")
      refute rows["Setup Fixture"].description =~ "limit"

      resets_at = DateTime.add(DateTime.utc_now(), 3_600)

      :ok =
        InferenceRouteRegistry.report_usage(ctx.registry, ctx.reporters[ctx.setup_id], [
          %{kind: "five_hour", utilization: 0.82, resets_at: resets_at, status: :warning},
          %{kind: "seven_day", utilization: 0.31, resets_at: nil, status: :allowed}
        ])

      row = route_items(ctx.registry)["Setup Fixture"]
      assert row.status == ItemStatus.new(:neutral, "Not checked")
      # A reset after midnight local time carries a weekday ("Sun 12:32 AM").
      assert row.description =~
               ~r/^5h limit resets (\w{3} )?\d{1,2}:\d{2} (AM|PM) · /

      refute row.description =~ "7d"
      refute row.description =~ "%"
    end

    test "model row chips show readiness and the busiest plan window by tone", ctx do
      reporter = ctx.reporters[ctx.setup_id]

      {:ok, _reporter} =
        InferenceRouteRegistry.register(
          ctx.registry,
          [
            source: {:extension, :fixture_bridge},
            id: "metered#{ctx.setup_id}",
            module: FixtureInferenceRoute,
            display_name: "Metered Fixture"
          ],
          config: [models: [FixtureInferenceRoute.model(id: "metered-model", cost: :metered)]]
        )

      InferenceRouteRegistry.refresh_availability(ctx.registry)
      :ok = InferenceRouteRegistry.report_status(ctx.registry, reporter, {:ready, "Claude Max"})
      resets_at = DateTime.add(DateTime.utc_now(), 3_600)

      window = fn utilization, status ->
        %{kind: "five_hour", utilization: utilization, resets_at: resets_at, status: status}
      end

      rows = route_items(ctx.registry)
      assert rows["Setup Fixture"].status == ItemStatus.new(:checking, "Checking…")

      assert rows["Setup Fixture"].description =~ ~r/^Claude Max · checking plan usage · 200k ctx/

      assert rows["Metered Fixture"].status == ItemStatus.new(:ready, "Ready")
      refute rows["Metered Fixture"].description =~ "plan usage"
      assert rows["Offline Setup"].status == ItemStatus.new(:error, "Unavailable")

      assert rows["Offline Setup"].description =~
               ~r/^#{Regex.escape(FixtureInferenceRoute.remedy())} · 200k ctx/

      cases = [
        {[window.(0.45, :allowed)], ItemStatus.new(:ready, "Ready · 45%")},
        {[window.(0.79, :allowed)], ItemStatus.new(:ready, "Ready · 79%")},
        {[window.(0.82, :warning)], ItemStatus.new(:warn, "Ready · 82%")},
        {[window.(1.0, :warning)], ItemStatus.new(:error, "Limit reached")},
        {[window.(0.6, :rejected)], ItemStatus.new(:error, "Limit reached")},
        {[], ItemStatus.new(:ready, "Ready")}
      ]

      for {windows, chip} <- cases do
        :ok = InferenceRouteRegistry.report_usage(ctx.registry, reporter, windows)
        row = route_items(ctx.registry)["Setup Fixture"]
        assert row.status == chip, "#{inspect(windows)} gave #{inspect(row.status)}"
        # The chip is the only usage signal; the description keeps the account and the reset time.
        refute row.description =~ "%"
        refute row.description =~ "Ready"
        refute row.description =~ "subscription"
        assert row.description =~ ~r/^Claude Max/
        assert windows == [] != (row.description =~ ~r/5h limit resets (\w{3} )?\d{1,2}:\d{2}/)
      end
    end

    test "a ready subscription route says it is checking plan usage until its first report",
         ctx do
      {:ok, _reporter} =
        InferenceRouteRegistry.register(
          ctx.registry,
          [
            source: {:extension, :fixture_bridge},
            id: "metered#{ctx.setup_id}",
            module: FixtureInferenceRoute,
            display_name: "Metered Fixture"
          ],
          config: [models: [FixtureInferenceRoute.model(id: "metered-model", cost: :metered)]]
        )

      :ok =
        InferenceRouteRegistry.report_status(
          ctx.registry,
          ctx.reporters[ctx.setup_id],
          {:ready, "me"}
        )

      rows = route_items(ctx.registry)

      # Usage follows readiness; the metered and the unavailable routes have no plan to wait for.
      assert rows["Setup Fixture"].status == ItemStatus.new(:checking, "Checking…")
      assert rows["Setup Fixture"].description =~ ~r/^me · checking plan usage/
      assert rows["Offline Setup"].status.tone != :checking
      assert rows["Metered Fixture"].status.tone != :checking
      refute rows["Metered Fixture"].description =~ "checking"

      :ok = InferenceRouteRegistry.report_usage(ctx.registry, ctx.reporters[ctx.setup_id], [])

      rows = route_items(ctx.registry)
      assert rows["Setup Fixture"].status == ItemStatus.new(:ready, "Ready")
      refute rows["Setup Fixture"].description =~ "checking"
      refute rows["Setup Fixture"].description =~ "limit"
    end

    test "an open chooser lists usage as soon as a route reports it and keeps query and selection",
         ctx do
      :ok = Minga.Events.subscribe(:inference_route_status_changed, registry: ctx.events)
      %{connection: connection} = Session.editor_snapshot(ctx.session)
      task_supervisor = start_supervised!({Task.Supervisor, []})
      scheduler = start_supervised!({EffectScheduler, task_supervisor: task_supervisor})
      :ok = EffectScheduler.attach(scheduler, self())
      {state, _workspace_id} = editor_state(connection, "Prior Model", scheduler)
      assert {:ok, state} = SlashCommand.execute(state, "/model")

      # Discovery checks the route and publishes its readiness while the first fetch is in flight.
      setup_id = ctx.setup_id
      assert_receive {:fixture_availability_checked, ^setup_id, _worker}, 1_000

      assert_receive {:minga_event, :inference_route_status_changed,
                      %StatusChangedEvent{route_id: ^setup_id}} = ready_event,
                     1_000

      assert {:noreply, state} = MingaEditor.handle_info(ready_event, state)
      assert {:ok, state} = land_fetch(state, scheduler)

      # A change that arrived during the fetch is listed again after it lands, without a new check.
      assert picker_ui(state).load_status == :loading
      assert {:ok, state} = land_fetch(state, scheduler)
      refute_received {:fixture_availability_checked, _id, _caller}

      assert row_item(state, "Setup Fixture").status == ItemStatus.new(:checking, "Checking…")

      state =
        PickerUI.update_picker(state, fn ps ->
          filtered = Picker.filter(ps.picker, "fixture model")
          model = Enum.find(filtered.filtered, &(&1.group == "Setup Fixture"))
          PickerState.update_picker(ps, Picker.select_id(filtered, model.id))
        end)

      selected = Picker.selected_id(picker_ui(state).picker)
      refute selected == Picker.selected_id(Picker.select_index(picker_ui(state).picker, 0))

      :ok =
        InferenceRouteRegistry.report_usage(ctx.registry, ctx.reporters[setup_id], [
          %{kind: "five_hour", utilization: 0.45, resets_at: nil, status: :allowed}
        ])

      assert_receive {:minga_event, :inference_route_status_changed,
                      %StatusChangedEvent{status: %Status{plan_usage: [_window]}}} = usage_event,
                     1_000

      assert {:noreply, state} = MingaEditor.handle_info(usage_event, state)
      assert {:ok, state} = land_fetch(state, scheduler)
      refute_received {:fixture_availability_checked, _id, _caller}

      assert row_item(state, "Setup Fixture").status == ItemStatus.new(:ready, "Ready · 45%")
      assert row_item(state, "Setup Fixture").description =~ "fixture@example.com · 5h limit ·"

      assert picker_ui(state).picker.query == "fixture model"
      assert Picker.selected_id(picker_ui(state).picker) == selected
    end
  end

  # Model rows by route display name (the row's group), from a session that lists the registry's current routes.
  defp route_items(registry) do
    opts = [
      backend_spec: MingaAgent.ProviderPacks.Native.spec(),
      credential_snapshot: Snapshot.new(%{}, nil),
      models: [],
      inference_routes: registry
    ]

    session =
      start_supervised!({ModelPickerSession, ModelResolver.candidates(opts)},
        id: make_ref()
      )

    context(connection(session), 1)
    |> model_items()
    |> Map.new(fn item -> {item.group, item} end)
  end

  defp land_fetch(state, scheduler) do
    assert_receive {:effect_result, ^scheduler,
                    %Outcome{value: {:completed, {:ok, _items, _candidates, _meta}}} = fetched},
                   1_000

    {:noreply, state} = MingaEditor.handle_info({:effect_result, scheduler, fetched}, state)
    {:ok, state}
  end

  defp picker_ui(state) do
    {:picker, %{picker_ui: picker_ui}} = state.shell_runtime.state.modal
    picker_ui
  end

  defp row_item(state, route_name) do
    Enum.find(
      picker_ui(state).picker.items,
      &(model_choice?(&1) and &1.group == route_name)
    )
  end

  defp start_codex_session(plug, path \\ "/tmp/model-picker-oauth.json") do
    credential = OAuth.new("picker-account", path)
    snapshot = Snapshot.new(%{"openai" => :env}, credential)

    oauth = fn :openai_codex, oauth_file: path ->
      {:ok,
       %{
         provider_key: "openai-codex",
         account_id: credential.account_id,
         oauth_file: path,
         token: "picker-token"
       }}
    end

    start_supervised!(
      {Session,
       provider: Native,
       credentials_snapshot_fn: fn -> snapshot end,
       model: "openai:no-such-model",
       persist?: false,
       provider_opts: [
         model_resolver_opts:
           Keyword.put(ModelSelectionFixture.resolver_opts(), :apple_availability_fn, fn ->
             {:error, :unsupported}
           end),
         credential_opts: [
           oauth_path: path,
           oauth_resolver: oauth,
           plug: plug
         ]
       ]}
    )
  end

  test "Codex discovery failure keeps API-key choices and shows a login notice" do
    session = start_codex_session(fn conn -> Plug.Conn.send_resp(conn, 401, "") end)

    connection = connection(session)
    {state, workspace_id} = editor_state(connection, "Prior Model", nil)
    ctx = context(connection, workspace_id)

    assert {:ok, items, %{status: status} = meta} = AgentModelSource.async_fetch(ctx)
    assert [item] = Enum.filter(items, &model_choice?/1)

    assert request_provider(item) == :openai
    assert status =~ "/login"

    # The API-key model is usable, so connection actions sit behind one row. ChatGPT lists no
    # model, so the child still offers a first sign-in.
    refute Enum.any?(items, &match?({:connect, _}, &1.meta.intent))
    assert connect_row(items)
    labels = items |> connect_row() |> child_items(ctx) |> Enum.map(& &1.label)
    assert "Sign in with ChatGPT" in labels
    refute "Connect openai with API key" in labels
    assert {:ok, [candidate]} = Session.get_available_models(session)
    assert candidate.selection.route.request_provider == :openai

    Session.refresh_credentials(session)
    assert {:ok, _} = Session.get_available_models(session)

    {opened, revision} =
      PickerUI.open_loading(state, AgentModelSource, ctx.picker_ui.context)

    assert {:ok, published} =
             PickerUI.apply_fetch_result(
               opened,
               AgentModelSource,
               revision,
               {:ok, items, Candidate.from_items(items), meta}
             )

    assert {:picker, %{picker_ui: %{picker: %{items: ^items}}}} =
             published.shell_runtime.state.modal

    assert published.shell_runtime.state.notice == opened.shell_runtime.state.notice
  end

  test "canceling a refresh preserves the completed inventory until a new result replaces it" do
    owner = self()
    calls = :atomics.new(1, [])

    session =
      start_codex_session(fn conn ->
        case :atomics.add_get(calls, 1, 1) do
          1 ->
            Req.Test.json(conn, %{"models" => [%{"slug" => "test-model", "visibility" => "list"}]})

          2 ->
            send(owner, {:refresh_started, self()})

            receive do
              :finish -> Plug.Conn.send_resp(conn, 401, "")
            end

          3 ->
            Plug.Conn.send_resp(conn, 401, "")
        end
      end)

    ctx = context(connection(session), 1)
    assert {:ok, ready, meta} = AgentModelSource.async_fetch(ctx)

    providers = for item <- ready, model_choice?(item), do: request_provider(item)
    assert Enum.sort(providers) == [:openai, :openai_codex]

    worker = spawn(fn -> AgentModelSource.async_fetch(ctx) end)
    monitor = Process.monitor(worker)
    assert_receive {:refresh_started, ^worker}, 1_000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

    assert {:ok, candidates} = Session.get_available_models(session)
    assert Enum.any?(candidates, &(&1.selection.route.request_provider == :openai_codex))

    assert {:ok, _items, %{status: _}} = AgentModelSource.async_fetch(ctx)
    assert {:ok, [candidate]} = Session.get_available_models(session)
    assert candidate.selection.route.request_provider == :openai

    assert {:ok, projected, _, empty_meta} =
             AgentModelSource.for_publication(
               {:ok, ready, Candidate.from_items(ready), meta},
               session
             )

    assert [item] = Enum.filter(projected, &model_choice?/1)
    assert Enum.reject(projected, &model_choice?/1) == Enum.reject(ready, &model_choice?/1)
    assert request_provider(item) == :openai
    assert empty_meta == %{}
  end

  @tag :tmp_dir
  test "a same-account sign-in supersedes a pending model lookup", %{tmp_dir: dir} do
    owner = self()

    session =
      start_codex_session(
        fn conn ->
          send(owner, {:discovery_started, self()})

          receive do
            :reply -> Plug.Conn.send_resp(conn, 401, "")
          end
        end,
        Path.join(dir, "oauth.json")
      )

    worker = Task.async(fn -> AgentModelSource.async_fetch(context(connection(session), 1)) end)
    assert_receive {:discovery_started, pid}, 5_000
    %{target: target} = Session.editor_snapshot(session).connection
    assert {:ok, ref} = Session.begin_connection(session, target, :oauth_manual, self())
    assert :ok = Session.register_connection_worker(session, target, ref, self())

    replacement =
      Secret.new(%{
        access: "replacement-access",
        refresh: "replacement-refresh",
        account_id: "picker-account",
        expires: System.system_time(:millisecond) + 3_600_000
      })

    assert {:ok, _snapshot} = Session.commit_oauth(session, target, ref, replacement)
    assert {:ok, [_]} = Session.get_available_models(session)
    send(pid, :reply)

    assert {:ok, items, meta} = Task.await(worker)
    assert [item] = Enum.filter(items, &model_choice?/1)
    assert request_provider(item) == :openai
    assert meta == %{}
  end

  test "retrying the connection supersedes a pending model lookup" do
    owner = self()

    session =
      start_codex_session(fn conn ->
        send(owner, {:discovery_started, self()})

        receive do
          :reply ->
            Req.Test.json(conn, %{"models" => [%{"slug" => "test-model", "visibility" => "list"}]})
        end
      end)

    worker = Task.async(fn -> AgentModelSource.async_fetch(context(connection(session), 1)) end)
    assert_receive {:discovery_started, pid}, 5_000
    %{target: target} = Session.editor_snapshot(session).connection
    assert :ok = Session.retry_connection(session, target)
    send(pid, :reply)

    assert {:ok, items, meta} = Task.await(worker)
    assert meta == %{}
    assert [item] = Enum.filter(items, &model_choice?/1)
    assert request_provider(item) == :openai
  end

  test "keeps duplicate display names distinct by exact route identity" do
    first =
      ModelSelectionFixture.selection(
        model_id: "shared-name",
        display_name: "Shared Model",
        route_id: "openai/shared-name"
      )

    second =
      ModelSelectionFixture.selection(
        model_id: "shared-name-v2",
        display_name: "Shared Model",
        route_id: "openai/shared-name-v2"
      )

    candidates = [
      %ModelCandidate{selection: first, favorite: false, current: true},
      %ModelCandidate{selection: second, favorite: false, current: false}
    ]

    session = start_supervised!({ModelPickerSession, candidates})
    items = model_items(context(connection(session), 1))

    assert Enum.map(items, & &1.label) == ["Shared Model", "Shared Model"]
    assert items |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 2
    assert Enum.all?(items, &String.contains?(&1.search_text, "api.openai.example"))
  end

  test "rejected picker selection preserves the prior visible model" do
    selection = ModelSelectionFixture.selection(display_name: "Rejected Model")
    candidate = %ModelCandidate{selection: selection, favorite: false, current: false}
    message = "The exact credential profile is unavailable. Pick another route."
    session = start_supervised!({RejectingSession, {[candidate], message}})
    task_supervisor = start_supervised!({Task.Supervisor, []})
    scheduler = start_supervised!({EffectScheduler, task_supervisor: task_supervisor})
    :ok = EffectScheduler.attach(scheduler, self())
    connection = connection(session)
    {state, workspace_id} = editor_state(connection, "Prior Model", scheduler)
    [item] = model_items(context(connection, workspace_id))

    state = AgentModelSource.on_select(item, state)
    assert_receive {:effect_result, ^scheduler, %Outcome{} = outcome}, 1_000

    assert {:noreply, state} =
             MingaEditor.handle_info({:effect_result, scheduler, outcome}, state)

    assert state.workspace.agent_ui.panel.model_name == "Prior Model"
    assert state.shell_runtime.state.notice.message == message
  end

  test "a delayed save for the same durable ID cannot notify a replacement conversation" do
    session = start_supervised!({ModelPickerSession, []})
    committed = connection(session)
    {state, id} = editor_state(committed, "Active Model", nil)
    saved = {:agent_event, session, {:connection_api_key_saved, id, committed.target, make_ref()}}

    assert {:noreply, notified} = MingaEditor.handle_info(saved, state)
    assert notified.shell_runtime.state.notice.message == "API key saved."

    replacement = connection(session)
    assert replacement.target.session_id == committed.target.session_id
    {replaced, ^id} = editor_state(replacement, "Restored Model", nil)

    assert {:noreply, ignored} = MingaEditor.handle_info(saved, replaced)
    refute ignored.shell_runtime.state.notice.message
  end

  test "a delayed authorization link failure cannot notify a replacement sign-in" do
    session = start_supervised!({ModelPickerSession, []})
    original = connection(session)
    first = make_ref()
    next = make_ref()
    {state, id} = editor_state(%{original | operation: {:connecting, first}}, "Active Model", nil)
    url = "https://auth.openai.com/oauth/authorize?fixture=1"
    ready = MingaAgent.OAuth.ManualReady.new(original.target, first, self(), "first", url)
    state = ConnectionSetup.offer_oauth(state, id, ready)
    prompt = state.workspace.agent_ui.connection_prompt

    effect = %ConnectionSetup{
      workspace_id: id,
      target: original.target,
      intent: {:authorization_url, :open, prompt}
    }

    request = Request.new(effect, {:connection_authorization, session}, Policy.fifo(0))
    failed = Outcome.failed(request, :authorization_link_unavailable)
    {notified, _} = ConnectionSetup.apply(state, failed)
    assert notified.shell_runtime.state.notice.message =~ "Could not open or copy"

    {replacement, ^id} =
      editor_state(%{original | operation: {:connecting, next}}, "Active Model", nil)

    ready = MingaAgent.OAuth.ManualReady.new(original.target, next, self(), "next", url)
    replacement = ConnectionSetup.offer_oauth(replacement, id, ready)
    {ignored, _} = ConnectionSetup.apply(replacement, failed)
    assert ignored.shell_runtime.state.notice == replacement.shell_runtime.state.notice
    assert ignored.workspace.agent_ui.connection_prompt.operation_ref == next
  end

  defp editor_state(
         %ConnectionSnapshot{target: %{session: session}} = connection,
         model_name,
         scheduler
       ) do
    {tab_bar, workspace} =
      1
      |> Tab.new_agent("Agent")
      |> TabBar.new()
      |> TabBar.add_workspace("Agent", session)

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(1, workspace.id)
      |> Map.put(:active_id, 1)

    agent_ui =
      UIState.new()
      |> UIState.project_connection(connection)
      |> UIState.set_model_name(model_name)

    state =
      %EditorState{
        frontend: %MingaEditor.State.Frontend{port_manager: nil, rendering: :disabled},
        workspace: %MingaEditor.Session.State{editing: VimState.new(), agent_ui: agent_ui},
        effect_scheduler: scheduler
      }
      |> then(fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tab_bar
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)
      |> MingaEditor.Shell.Traditional.Workflow.install_agent_state(%AgentState{
        runtime: %RuntimeState{status: :idle},
        error: nil,
        spinner_timer: nil
      })

    {state, workspace.id}
  end

  defp context(%ConnectionSnapshot{target: %{session: session} = target} = snapshot, workspace_id) do
    %Context{
      buffers: %Buffers{},
      editing: VimState.new(),
      search: %Search{},
      viewport: Viewport.new(80, 24),
      tab_bar: %{},
      agent_session: session,
      picker_ui: %{
        context: %{
          target: target,
          connection: snapshot,
          workspace_id: workspace_id,
          connection_prompt: nil
        }
      },
      capabilities: %{},
      theme: Theme.get!(:doom_one)
    }
  end

  defp connect_row(items),
    do: Enum.find(items, &(&1.id == {:connection, :connect_another_provider}))

  # The rows of the child picker that a "Connect another provider…" row opens.
  defp child_items(item, %Context{picker_ui: %{context: origin}} = ctx) do
    assert {:stay_open, {:nested, AgentConnectionSource, child}} =
             AgentModelSource.selection_disposition(item, origin)

    AgentConnectionSource.candidates(%{ctx | picker_ui: %{context: child}})
  end

  defp model_items(context) do
    Enum.filter(AgentModelSource.candidates(context), &model_choice?/1)
  end

  defp model_choice?(item), do: match?({:model, %ModelSelection{}}, item.meta.intent)

  defp request_provider(%{meta: %{intent: {:model, selection}}}),
    do: selection.route.request_provider

  defp connection(session) do
    %ConnectionSnapshot{
      target: ConnectionTarget.new(session, "fixture-conversation", nil, make_ref()),
      credential_readiness: :configured,
      provider_phase: :running,
      model_selection: nil,
      operation: :idle,
      problem: nil
    }
  end
end
