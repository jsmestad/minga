defmodule MingaEditor.UI.Picker.AgentModelSourceTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Credentials.Secret
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.InferenceRouteRegistry
  alias MingaAgent.ModelResolver
  alias MingaAgent.ModelCandidate
  alias MingaAgent.ModelSelection
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
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Picker.AgentModelSource
  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.Context
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

  test "shows exact route, unverified status, favorite, and thinking controls" do
    selection =
      ModelSelectionFixture.selection(
        model_provider: "openai",
        model_id: "gpt-4",
        display_name: "GPT-4",
        base_url: "https://api.openai.com/v1",
        transport: "http",
        reasoning: %{effort: "low", options: ["off", "low", "high"]},
        limits: %{context: 128_000, input: nil, output: 8_192, request_output: 2_048},
        capabilities: %{tools: true, images: true, streaming: true}
      )

    candidate = %ModelCandidate{selection: selection, favorite: true, current: true}
    session = start_supervised!({ModelPickerSession, [candidate]})

    assert [item] = model_items(context(connection(session), 1))
    assert item.id == ModelSelection.id(selection)
    assert item.active
    assert item.annotation == "★ favorite"
    assert item.description =~ "openai via openai_chat"
    assert item.description =~ "https://api.openai.com/v1/chat/completions"
    assert item.description =~ "unverified catalog route"
    assert item.description =~ "openai:env"
    assert item.description =~ "thinking low (off/low/high)"
    assert item.description =~ "tools yes, images yes, streaming yes"
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
    assert apple.description =~ "No credentials"
    assert apple.description =~ "Ready on this device"
    assert apple.description =~ "Compact file tools"

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

    test "rows show route readiness, remedy, thinking, and capabilities from the route", %{
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
      ready = Enum.find(items, &(&1.description =~ "Fixture Route"))
      offline = Enum.find(items, &(&1.description =~ "Offline Route"))

      assert ready.label == "Fixture Model"
      assert ready.description =~ "Ready (fixture@example.com)"
      assert ready.description =~ "200k ctx"
      assert ready.description =~ "thinking off (off/low/high)"
      assert ready.description =~ "tools yes, images yes, streaming yes"
      assert ready.description =~ "subscription"
      refute ready.description =~ "unverified catalog route"

      assert offline.description =~ "Unavailable: #{FixtureInferenceRoute.remedy()}"
      refute offline.description =~ "unverified catalog route"
      assert Enum.all?([ready, offline], &(request_provider(&1) == :contributed))
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
      offline = Enum.find(items, &(&1.description =~ "Offline Route"))
      assert offline.description =~ "Unavailable: #{FixtureInferenceRoute.remedy()}"

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
      registry = :"picker_setup_routes_#{suffix}"
      start_supervised!({InferenceRouteRegistry, name: registry})

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
      items = AgentModelSource.candidates(context(connection, 1))
      rows = setup_rows(items)

      ready = Enum.find(rows, &(&1.label == "Use Setup Fixture"))
      offline = Enum.find(rows, &(&1.label == "Use Offline Setup"))

      assert ready.description =~ "Minga never sees your login."
      assert ready.description =~ "Ready: fixture@example.com"
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

      [row | _rest] =
        context(connection, workspace_id)
        |> AgentModelSource.candidates()
        |> setup_rows()
        |> Enum.filter(&(&1.label == "Use Setup Fixture"))

      assert_receive {:fixture_availability_checked, _id, _discovery_caller}

      state = AgentModelSource.on_select(row, state)
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

      assert {:ok, %Minga.Command{}} =
               Minga.Command.Registry.lookup(Minga.Command.Registry, :agent_pick_model)
    end

    test "subscription rows show reported usage and nothing without data", ctx do
      opts = [
        backend_spec: MingaAgent.ProviderPacks.Native.spec(),
        credential_snapshot: Snapshot.new(%{}, nil),
        models: [],
        inference_routes: ctx.registry
      ]

      session =
        start_supervised!({ModelPickerSession, ModelResolver.candidates(opts)},
          id: :without_usage
        )

      row =
        Enum.find(
          model_items(context(connection(session), 1)),
          &(&1.description =~ "Setup Fixture")
        )

      refute row.description =~ "limit"

      resets_at = DateTime.add(DateTime.utc_now(), 3_600)

      :ok =
        InferenceRouteRegistry.report_usage(ctx.registry, ctx.reporters[ctx.setup_id], [
          %{kind: "five_hour", utilization: 0.82, resets_at: resets_at, status: :warning},
          %{kind: "seven_day", utilization: 0.31, resets_at: nil, status: :allowed}
        ])

      session =
        start_supervised!({ModelPickerSession, ModelResolver.candidates(opts)}, id: :with_usage)

      row =
        Enum.find(
          model_items(context(connection(session), 1)),
          &(&1.description =~ "Setup Fixture")
        )

      assert row.description =~ ~r/82% of 5h limit · resets \d{1,2}:\d{2} (AM|PM)/
      refute row.description =~ "7d"
    end
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
    assert Enum.any?(items, &match?({:connect, _}, &1.meta.intent))
    assert status =~ "/login"
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
    assert Enum.all?(items, &String.contains?(&1.description, "api.openai.example"))
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
