defmodule MingaEditor.Shell.Traditional.BackgroundSubagentTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Subagent.Handle
  alias MingaEditor.Shell.Traditional
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Viewport
  alias MingaEditor.Workspace.State, as: WorkspaceState

  test "background subagent event creates one agent tab for the child session" do
    handle = background_handle(session_id: "session-2", pid: self(), task: "write tests")
    shell_state = %ShellState{tab_bar: TabBar.new(Tab.new_file(1, "editor.ex"))}
    workspace = %WorkspaceState{viewport: Viewport.new(24, 80)}

    {shell_state, ^workspace} =
      Traditional.handle_event(shell_state, workspace, {:background_subagent_started, handle})

    assert TabBar.count(shell_state.tab_bar) == 2

    tab = TabBar.find_by_session(shell_state.tab_bar, self())
    assert tab.kind == :agent
    assert tab.session == self()
    assert tab.agent_status == :thinking
    assert tab.background_subagent == handle
    assert tab.label == "session-2: write tests"
    assert tab.context.keymap_scope == :agent
  end

  test "duplicate background subagent event for the same pid does not create another tab" do
    handle = background_handle(session_id: "session-3", pid: self(), task: "avoid duplicates")
    shell_state = %ShellState{tab_bar: TabBar.new(Tab.new_file(1, "editor.ex"))}
    workspace = %WorkspaceState{viewport: Viewport.new(24, 80)}

    {shell_state, ^workspace} =
      Traditional.handle_event(shell_state, workspace, {:background_subagent_started, handle})

    {shell_state, ^workspace} =
      Traditional.handle_event(shell_state, workspace, {:background_subagent_started, handle})

    assert TabBar.count(shell_state.tab_bar) == 2
    assert length(Enum.filter(shell_state.tab_bar.tabs, &(&1.session == self()))) == 1
  end

  defp background_handle(opts) do
    Handle.new(
      session_id: Keyword.fetch!(opts, :session_id),
      pid: Keyword.fetch!(opts, :pid),
      task: Keyword.fetch!(opts, :task),
      started_at: ~U[2026-05-09 00:00:00Z]
    )
  end
end
