defmodule MingaEditor.UI.Picker.WorkspaceSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Mode
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.WorkspaceSource
  alias MingaEditor.UI.Theme
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  defp fake_context(tab_bar) do
    %Context{
      buffers: %Buffers{list: [], active: nil, active_index: 0},
      editing: VimState.new(),
      file_tree: nil,
      search: %Search{},
      viewport: Viewport.new(80, 24),
      tab_bar: tab_bar,
      agent_session: nil,
      picker_ui: %{},
      capabilities: %{},
      theme: Theme.get!(:doom_one)
    }
  end

  defp editor_state(tab_bar, buffer, mode) do
    %EditorState{
      port_manager: nil,
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(80, 24),
        editing: %VimState{mode: mode, mode_state: Mode.initial_state()},
        buffers: %Buffers{list: [buffer], active: buffer, active_index: 0},
        keymap_scope: :editor
      },
      shell_state: %ShellState{tab_bar: tab_bar}
    }
  end

  describe "candidates/1" do
    test "returns one item per workspace with tabs, including manual" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add(tb, :agent, "Agent")
      {tb, group} = TabBar.add_workspace(tb, "Research")
      tb = TabBar.move_tab_to_workspace(tb, 2, group.id)

      items = WorkspaceSource.candidates(fake_context(tb))
      assert Enum.map(items, & &1.id) == [0, group.id]
    end

    test "filters out agent workspaces with no tabs" do
      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, _} = TabBar.add_workspace(tb, "Empty")

      items = WorkspaceSource.candidates(fake_context(tb))
      assert Enum.map(items, & &1.id) == [0]
    end

    test "shows file names in description" do
      tb = TabBar.new(Tab.new_file(1, "editor.ex"))
      {tb, _} = TabBar.add(tb, :file, "main.ex")
      {tb, group} = TabBar.add_workspace(tb, "Work")
      tb = TabBar.move_tab_to_workspace(tb, 1, group.id)
      tb = TabBar.move_tab_to_workspace(tb, 2, group.id)

      [item] = WorkspaceSource.candidates(fake_context(tb))
      assert item.description =~ "editor.ex"
      assert item.description =~ "main.ex"
    end

    test "returns empty for context without TabBar struct" do
      ctx = %Context{
        buffers: %Buffers{list: [], active: nil, active_index: 0},
        editing: VimState.new(),
        file_tree: nil,
        search: %Search{},
        viewport: Viewport.new(80, 24),
        tab_bar: %{},
        agent_session: nil,
        picker_ui: %{},
        capabilities: %{},
        theme: Theme.get!(:doom_one)
      }

      assert WorkspaceSource.candidates(ctx) == []
    end
  end

  defp start_buffer(content) do
    start_supervised!({BufferProcess, content: content},
      id: {:workspace_source_buffer, :erlang.unique_integer([:positive])}
    )
  end

  describe "on_select/2" do
    test "switches through the editor path and restores the selected workspace" do
      buf_a = start_buffer("a")
      buf_b = start_buffer("b")

      tb = TabBar.new(Tab.new_file(1, "a.ex"))
      {tb, tab2} = TabBar.add(tb, :file, "b.ex")
      {tb, group} = TabBar.add_workspace(tb, "Agent")
      tb = TabBar.move_tab_to_workspace(tb, tab2.id, group.id)
      tb = TabBar.switch_to(tb, 1)

      target_context =
        editor_state(nil, buf_b, :insert)
        |> EditorState.snapshot_tab_context()

      tb = TabBar.update_context(tb, tab2.id, target_context)
      state = editor_state(tb, buf_a, :normal)

      switched = WorkspaceSource.on_select(%Item{id: group.id, label: "Agent"}, state)

      assert switched.workspace.buffers.active == buf_b
      assert switched.workspace.editing.mode == :insert
      assert switched.shell_state.tab_bar.active_id == tab2.id
      assert EditorState.active_tab(switched).id == tab2.id
      assert TabBar.get(switched.shell_state.tab_bar, 1).context.buffers.active == buf_a
      assert TabBar.get(switched.shell_state.tab_bar, tab2.id).context.buffers.active == buf_b
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{shell_state: %{tab_bar: TabBar.new(Tab.new_file(1, "a.ex"))}}
      assert WorkspaceSource.on_cancel(state) == state
    end
  end
end
