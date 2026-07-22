defmodule MingaEditor.Agent.CompactionTest do
  @moduledoc "Behavior tests for the session-keyed agent compaction effect."

  use ExUnit.Case, async: true

  alias MingaEditor.Agent.Compaction
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Session.State, as: WorkspaceState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar

  test "request is zero-queue FIFO keyed by session pid" do
    session = fake_session()
    request = Compaction.request(session)

    assert request.resource == {:agent_session, session}
    assert request.policy.mode == :fifo
    assert request.policy.max_queued == 0
  end

  test "failed and canceled outcomes clear matching progress while stale results do not" do
    session = fake_session()
    state = state_for(session)
    request = Compaction.request(session)

    {failed, %Outcome{status: :failed}} =
      Compaction.apply(state, Outcome.failed(request, :provider_error))

    refute failed.workspace.agent_ui.view.compaction_in_progress
    assert failed.workspace.agent_ui.view.toast.message == "Auto-compact failed: :provider_error"

    state = state_for(session)

    {canceled, %Outcome{status: :canceled}} =
      Compaction.apply(state, Outcome.canceled(request, :requested))

    refute canceled.workspace.agent_ui.view.compaction_in_progress

    other_session = fake_session()
    stale_state = state_for(other_session)

    {unchanged, %Outcome{status: :stale, reason: :agent_session_changed}} =
      Compaction.apply(stale_state, Outcome.completed(request, "summary"))

    assert unchanged == stale_state
  end

  test "background outcomes clear progress on the workspace that owns the session" do
    active_session = fake_session()
    background_session = fake_session()
    state = state_for(active_session)
    tab_bar = state.shell_runtime.state.tab_bar

    {tab_bar, background_workspace} =
      TabBar.add_workspace(tab_bar, "Background", background_session)

    background_ui =
      UIState.new()
      |> then(fn ui -> %{ui | view: %{ui.view | compaction_in_progress: true}} end)

    tab_bar =
      TabBar.set_workspace_agent_ui(tab_bar, background_workspace.id, background_ui)

    state =
      then(state, fn root ->
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

    request = Compaction.request(background_session)

    {updated, %Outcome{status: :failed}} =
      Compaction.apply(state, Outcome.failed(request, :provider_error))

    background =
      updated.shell_runtime.state.tab_bar
      |> TabBar.find_workspace_by_session(background_session)

    refute background.agent_ui.view.compaction_in_progress
    assert background.agent_ui.view.toast.message == "Auto-compact failed: :provider_error"
    assert MingaEditor.Shell.Runtime.active_session(updated.shell_runtime) == active_session
  end

  test "scheduler admission failure clears transient progress and surfaces terminal error" do
    session = fake_session()
    state = state_for(session)

    updated = Compaction.schedule(state, session)

    refute updated.workspace.agent_ui.view.compaction_in_progress
    assert updated.workspace.agent_ui.view.toast.level == :error
    assert updated.workspace.agent_ui.view.toast.message =~ "admission_failed"
    assert updated.render.render_correlation.timer != nil
    Process.cancel_timer(updated.render.render_correlation.timer)
  end

  defp state_for(session) do
    {tab_bar, workspace} =
      TabBar.add_workspace(TabBar.new(Tab.new_agent(1, "Agent")), "Agent", session)

    tab_bar = TabBar.move_tab_to_workspace(tab_bar, 1, workspace.id)

    agent_ui =
      UIState.new()
      |> then(fn ui -> %{ui | view: %{ui.view | compaction_in_progress: true}} end)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self(), backend: :tui},
      workspace: %WorkspaceState{agent_ui: agent_ui},
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          TraditionalState.install_tab_bar(%TraditionalState{}, tab_bar)
        )
    }
  end

  defp fake_session do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(pid, :stop) end)
    pid
  end
end
