defmodule MingaEditor.Agent.StartupCatalogBoundaryTest do
  # Erlang trace patterns are global; serialize this boundary probe.
  use ExUnit.Case, async: false

  alias MingaEditor.Agent.UIState
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.StatusBar.Data

  test "pre-ready readiness routing and status projection do not enter the catalog" do
    state = TestHelpers.base_state(rendering: :disabled)
    session = self()
    tab_bar = TabBar.new(Tab.new_agent(1, "Agent"))
    {tab_bar, workspace} = TabBar.add_workspace(tab_bar, "Startup")

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(1, workspace.id)
      |> TabBar.set_workspace_session(workspace.id, session)

    shell_state = TraditionalState.install_tab_bar(Runtime.state(state.shell_runtime), tab_bar)

    state = %{
      state
      | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }

    refute state.session.session_started?

    {panel, calls} =
      trace_catalog(fn ->
        ui = UIState.new()
        state = %{state | workspace: %{state.workspace | agent_ui: ui}}

        state =
          Enum.reduce([:checking, :configured], state, fn readiness, state ->
            {:noreply, projected} =
              MingaEditor.handle_info(
                {:agent_event, session, {:credentials_status, readiness}},
                state
              )

            assert projected.workspace.agent_ui.panel.credential_readiness == readiness
            assert projected.workspace.agent_ui.panel.model_name == ui.panel.model_name
            Data.from_state(projected)
            projected
          end)

        stale_session = spawn(fn -> :ok end)

        {:noreply, ignored} =
          MingaEditor.handle_info(
            {:agent_event, stale_session, {:credentials_status, :unconfigured}},
            state
          )

        assert ignored.workspace.agent_ui.panel == state.workspace.agent_ui.panel
        Data.from_state(ignored)
        agent_window = MingaEditor.Window.new_agent_chat(1, 24, 80)

        agent_state = %{
          ignored
          | workspace: %{
              ignored.workspace
              | windows: %{ignored.workspace.windows | map: %{1 => agent_window}, active: 1}
            }
        }

        Data.from_state(agent_state)
        ignored.workspace.agent_ui.panel
      end)

    assert panel.credential_readiness == :configured
    assert calls == []
  end

  test "ordinary first edit and rendering leave deferred model resolution untouched" do
    state = TestHelpers.base_state(rendering: :disabled, content: "startup fixture")

    {state, calls} =
      trace_catalog(fn ->
        {:noreply, state} = MingaEditor.handle_info({:minga_input, {:key_press, ?i, 0}}, state)
        {:noreply, state} = MingaEditor.handle_info({:minga_input, {:key_press, ?X, 0}}, state)
        Data.from_state(state)
        state
      end)

    assert Minga.Buffer.content(state.workspace.buffers.active) == "Xstartup fixture"
    assert calls == []
  end

  test "the probe detects catalog entry even when another test loaded its data" do
    {_models, calls} = trace_catalog(fn -> LLMDB.models() end)
    assert {LLMDB, :models, []} in calls
  end

  test "opening the Agent with no configured model makes no catalog or resolver call in the Editor" do
    _catalog = LLMDB.providers()
    options = start_supervised!({Minga.Config.Options, name: nil})
    state = agent_open_state(options, silent_manager())

    {opened, calls} =
      trace_catalog(fn -> MingaEditor.Commands.Agent.new_agent_session(state) end)

    # Reading the catalog's load epoch decides whether the start must wait; it
    # never loads or walks the catalog.
    assert calls -- [{LLMDB, :epoch, []}] == []
    assert map_size(opened.agent_connection.session_starts) == 1
    assert opened.workspace.agent_ui.chat_lifecycle == :starting

    assert MingaEditor.Agent.UIState.Panel.model_label(opened.workspace.agent_ui.panel) =~
             "Resolving"
  end

  test "the launch preload loads the catalog off the Editor so the next open skips the load" do
    _catalog = LLMDB.providers()
    saved = LLMDB.Catalog.get()
    LLMDB.Catalog.clear!()
    previous = Application.get_env(:minga, :agent_catalog_preload)
    Application.put_env(:minga, :agent_catalog_preload, true)

    on_exit(fn ->
      :persistent_term.put(:llm_db_store, saved)
      Application.put_env(:minga, :agent_catalog_preload, previous)
    end)

    options = start_supervised!({Minga.Config.Options, name: nil})
    manager = silent_manager()
    cold = agent_open_state(options, manager)

    # Cold, a start cannot send its request until a catalog load finishes.
    waiting = MingaEditor.Commands.Agent.new_agent_session(cold)
    assert waiting.agent_connection.session_starts == %{}
    refute_received {:start_requested, ^manager}

    test = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:minga, :agent, :catalog_load, :start],
        fn _event, _measurements, metadata, _config -> send(test, {:catalog_load, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    launched = MingaEditor.Agent.CatalogStartup.preload(cold)
    assert_receive {:catalog_load, %{trigger: :preload}}, 2_000

    # A start that arrives during the preload joins it instead of loading again.
    assert {:ok, :ready} = MingaAgent.ModelCatalog.load()
    refute_received {:catalog_load, _metadata}
    refute LLMDB.epoch() == 0

    opened = MingaEditor.Commands.Agent.new_agent_session(launched)
    assert map_size(opened.agent_connection.session_starts) == 1
    assert_receive {:start_requested, ^manager}
  end

  @spec agent_open_state(GenServer.server(), pid()) :: MingaEditor.State.t()
  defp agent_open_state(options, manager) do
    state = TestHelpers.base_state(rendering: :disabled)
    state = MingaEditor.WorkspaceWorkflow.install_tab_bar(state, TabBar.new(Tab.new_file(1, "f")))
    connection = %{state.agent_connection | session_manager: manager}

    %{
      state
      | agent_connection: connection,
        interaction: MingaEditor.State.Interaction.new(options_server: options)
    }
  end

  @spec silent_manager() :: pid()
  defp silent_manager do
    test = self()

    spawn_link(fn ->
      receive do
        {:"$gen_call", _from, {:start_session, _opts}} ->
          send(test, {:start_requested, self()})
          receive(do: (:never -> :ok))
      end
    end)
  end

  @spec trace_catalog((-> result)) :: {result, [tuple()]} when result: var
  defp trace_catalog(operation) do
    {:module, LLMDB} = Code.ensure_loaded(LLMDB)
    {:module, MingaAgent.ModelResolver} = Code.ensure_loaded(MingaAgent.ModelResolver)
    :erlang.trace_pattern({LLMDB, :_, :_}, true, [])
    :erlang.trace_pattern({MingaAgent.ModelResolver, :_, :_}, true, [])
    tracer = spawn_link(fn -> collect([]) end)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      result = operation.()
      :erlang.trace(self(), false, [:call])
      ref = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _, ^ref}
      send(tracer, {:take, self()})
      assert_receive {:calls, calls}
      {result, calls}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({LLMDB, :_, :_}, false, [])
      :erlang.trace_pattern({MingaAgent.ModelResolver, :_, :_}, false, [])
      send(tracer, :stop)
    end
  end

  @spec collect([tuple()]) :: :ok
  defp collect(calls) do
    receive do
      {:trace, _pid, :call, call} ->
        collect([call | calls])

      {:take, owner} ->
        send(owner, {:calls, calls})
        collect([])

      :stop ->
        :ok
    end
  end
end
