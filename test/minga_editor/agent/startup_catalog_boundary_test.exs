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

  @spec trace_catalog((-> result)) :: {result, [tuple()]} when result: var
  defp trace_catalog(operation) do
    {:module, LLMDB} = Code.ensure_loaded(LLMDB)
    :erlang.trace_pattern({LLMDB, :_, :_}, true, [])
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
