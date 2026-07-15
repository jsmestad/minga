defmodule MingaEditor.Shell.Traditional.BackgroundSubagentTest do
  use ExUnit.Case, async: true

  alias Minga.Test.StubServer
  alias MingaAgent.Subagent.Handle
  alias MingaEditor.Handlers.EventDispatcher
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace.Persistence, as: WorkspacePersistence
  alias MingaEditor.Viewport
  alias MingaEditor.Session.State, as: SessionState

  test "background subagent event creates one agent tab for the child session" do
    handle = background_handle(session_id: "session-2", pid: self(), task: "write tests")
    shell_state = %ShellState{tab_bar: TabBar.new(Tab.new_file(1, "editor.ex"))}
    workspace = %SessionState{viewport: Viewport.new(24, 80)}

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

  @tag :tmp_dir
  test "background subagent dispatch persists its created workspace", %{tmp_dir: root} do
    session = start_supervised!({StubServer, []})
    handle = background_handle(session_id: "session-4", pid: session, task: "persist tests")
    tab_bar = TabBar.new(Tab.new_file(1, "editor.ex"), root)

    state = %EditorState{
      shell_runtime: Runtime.new(Runtime.default_entry(), %ShellState{tab_bar: tab_bar}),
      workspace: %SessionState{viewport: Viewport.new(24, 80)}
    }

    result = EventDispatcher.dispatch(state, :background_subagent_started, handle, :event)
    workspace = TabBar.find_workspace_by_session(result.shell_runtime.state.tab_bar, session)
    path = WorkspacePersistence.path_for(root, workspace.id)

    assert File.exists?(path)
    assert {:ok, persisted} = WorkspacePersistence.read(path, root)
    assert persisted.label == "session-4: persist tests"
  end

  test "duplicate background subagent event for the same pid does not create another tab" do
    handle = background_handle(session_id: "session-3", pid: self(), task: "avoid duplicates")
    shell_state = %ShellState{tab_bar: TabBar.new(Tab.new_file(1, "editor.ex"))}
    workspace = %SessionState{viewport: Viewport.new(24, 80)}

    {shell_state, ^workspace} =
      Traditional.handle_event(shell_state, workspace, {:background_subagent_started, handle})

    {shell_state, ^workspace} =
      Traditional.handle_event(shell_state, workspace, {:background_subagent_started, handle})

    assert TabBar.count(shell_state.tab_bar) == 2
    assert Enum.count(shell_state.tab_bar.tabs, &(&1.session == self())) == 1
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
