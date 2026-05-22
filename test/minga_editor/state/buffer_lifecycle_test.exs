defmodule MingaEditor.State.BufferLifecycleTest do
  @moduledoc """
  Pure-function tests for buffer lifecycle operations on `EditorState`.
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.State, as: SessionState

  import MingaEditor.RenderPipeline.TestHelpers

  @spec state_with_file_tab(keyword()) :: EditorState.t()
  defp state_with_file_tab(opts \\ []) do
    state = base_state(opts)
    tab = Tab.new_file(1, "test.ex")
    tb = TabBar.new(tab) |> TabBar.update_context(1, EditorState.snapshot_tab_context(state))
    EditorState.set_tab_bar(state, tb)
  end

  @spec state_with_file_tab_for_path(String.t(), String.t()) :: {EditorState.t(), pid()}
  defp state_with_file_tab_for_path(path, content) do
    buf = start_file_buffer(path, content)
    state = state_for_buffer(buf)
    tab = Tab.new_file(1, Path.basename(path))
    tb = TabBar.new(tab) |> TabBar.update_context(1, EditorState.snapshot_tab_context(state))
    {EditorState.set_tab_bar(state, tb), buf}
  end

  @spec state_with_agent_tab() :: {EditorState.t(), pid()}
  defp state_with_agent_tab do
    agent_buf = start_buffer("")
    agent_window = Window.new_agent_chat(1, agent_buf, 24, 80)

    state = %EditorState{
      port_manager: self(),
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: :agent,
        buffers: %Buffers{active: agent_buf, list: [agent_buf], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => agent_window},
          active: 1,
          next_id: 2
        }
      }
    }

    tb =
      TabBar.new(Tab.new_agent(1, "Agent"))
      |> TabBar.update_context(1, EditorState.snapshot_tab_context(state))

    {EditorState.set_tab_bar(state, tb), agent_buf}
  end

  @spec start_buffer(String.t()) :: pid()
  defp start_buffer(content) do
    {:ok, pid} = BufferProcess.start_link(content: content)
    pid
  end

  @spec start_file_buffer(String.t(), String.t()) :: pid()
  defp start_file_buffer(path, content) do
    File.write!(path, content)
    {:ok, pid} = BufferProcess.start_link(file_path: path)
    pid
  end

  describe "add_buffer_pure/2" do
    test "adds buffers with no tab bar, opens file tabs, previews without overwriting context, and avoids duplicate monitors" do
      no_tab = base_state()
      new_buf = start_buffer("new file")
      {new_state, effects} = EditorState.add_buffer_pure(no_tab, new_buf)
      assert new_buf in new_state.workspace.buffers.list
      assert new_state.workspace.buffers.active == new_buf
      assert {:monitor, new_buf} in effects

      state = state_with_file_tab()
      original_buf = state.workspace.buffers.active
      opened_buf = start_buffer("opened")
      {opened, effects} = EditorState.add_buffer_pure(state, opened_buf, context: :open)
      tb = opened.shell_state.tab_bar
      assert {:monitor, opened_buf} in effects
      assert TabBar.count(tb) == 2
      assert tb.active_id == 2
      assert %Buffers{active: ^original_buf} = TabBar.get(tb, 1).context.buffers
      assert %Buffers{active: ^opened_buf} = TabBar.get(tb, 2).context.buffers
      assert opened.workspace.buffers.active == opened_buf

      preview_buf = start_buffer("preview")
      {previewed, _effects} = EditorState.add_buffer_pure(state, preview_buf, context: :preview)
      assert TabBar.count(previewed.shell_state.tab_bar) == 1
      assert previewed.workspace.buffers.active == preview_buf

      assert %Buffers{active: ^original_buf} =
               TabBar.get(previewed.shell_state.tab_bar, 1).context.buffers

      assert previewed.buffer_add_context == :open

      duplicate = EditorState.add_buffer(state, opened_buf)
      {switched_back, effects} = EditorState.add_buffer_pure(duplicate, original_buf)
      assert switched_back.workspace.buffers.active == original_buf
      assert effects == []
    end

    test "opening from an agent tab snapshots agent state, creates a file tab, switches scope, and stops the spinner" do
      {state, agent_buf} = state_with_agent_tab()
      file_buf = start_buffer("file content")

      {new_state, effects} = EditorState.add_buffer_pure(state, file_buf, context: :open)
      tb = new_state.shell_state.tab_bar
      agent_tab = TabBar.get(tb, 1)
      file_tab = TabBar.active(tb)
      window = active_window(new_state)

      assert {:monitor, file_buf} in effects
      assert :stop_spinner in effects
      assert TabBar.count(tb) == 2
      assert agent_tab.kind == :agent
      assert %Buffers{active: ^agent_buf} = agent_tab.context.buffers
      assert agent_tab.context.keymap_scope == :agent
      assert file_tab.kind == :file
      assert %Buffers{active: ^file_buf} = file_tab.context.buffers
      assert file_tab.context.keymap_scope == :editor
      assert new_state.workspace.keymap_scope == :editor
      assert new_state.workspace.buffers.active == file_buf
      assert Content.buffer?(window.content)
    end

    @tag :tmp_dir
    test "file identity uses real paths, not just basenames, and existing tabs are reactivated without monitor effects",
         %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "one.ex")
      path2 = Path.join(tmp_dir, "two.ex")
      {state, buf1} = state_with_file_tab_for_path(path1, "one")
      buf2 = start_file_buffer(path2, "two")

      {state, _effects} = EditorState.add_buffer_pure(state, buf2, context: :open)
      {reactivated, effects} = EditorState.add_buffer_pure(state, buf1, context: :open)
      assert effects == []
      assert reactivated.shell_state.tab_bar.active_id == 1
      assert reactivated.workspace.buffers.active == buf1

      assert %Buffers{active: ^buf1} =
               TabBar.get(reactivated.shell_state.tab_bar, 1).context.buffers

      assert %Buffers{active: ^buf2} =
               TabBar.get(reactivated.shell_state.tab_bar, 2).context.buffers

      dir1 = Path.join(tmp_dir, "one")
      dir2 = Path.join(tmp_dir, "two")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      same1 = Path.join(dir1, "same.ex")
      same2 = Path.join(dir2, "same.ex")
      {state, same_buf1} = state_with_file_tab_for_path(same1, "one")
      same_buf2 = start_file_buffer(same2, "two")

      {distinct, effects} = EditorState.add_buffer_pure(state, same_buf2, context: :open)
      assert {:monitor, same_buf2} in effects
      assert TabBar.count(distinct.shell_state.tab_bar) == 2
      assert TabBar.get(distinct.shell_state.tab_bar, 1).label == "same.ex"
      assert TabBar.get(distinct.shell_state.tab_bar, 2).label == "same.ex"

      assert %Buffers{active: ^same_buf1} =
               TabBar.get(distinct.shell_state.tab_bar, 1).context.buffers

      assert %Buffers{active: ^same_buf2} =
               TabBar.get(distinct.shell_state.tab_bar, 2).context.buffers
    end

    test "agent chat windows without tab bars keep their content when a file buffer is added" do
      agent_buf = start_buffer("")
      agent_window = Window.new_agent_chat(1, agent_buf, 24, 80)

      state = %EditorState{
        port_manager: self(),
        workspace: %SessionState{
          viewport: Viewport.new(24, 80),
          editing: VimState.new(),
          buffers: %Buffers{active: agent_buf, list: [agent_buf], active_index: 0},
          windows: %Windows{
            tree: WindowTree.new(1),
            map: %{1 => agent_window},
            active: 1,
            next_id: 2
          }
        }
      }

      file_buf = start_buffer("file content")
      {new_state, effects} = EditorState.add_buffer_pure(state, file_buf)
      window = active_window(new_state)

      assert file_buf in new_state.workspace.buffers.list
      assert new_state.workspace.buffers.active == file_buf
      assert {:monitor, file_buf} in effects
      assert Content.agent_chat?(window.content)
      assert window.buffer == agent_buf
    end
  end

  describe "switch_buffer/2" do
    test "open switches refresh active file tab context, while preview switches keep the original context" do
      state = state_with_file_tab()
      original_buf = state.workspace.buffers.active
      other_buf = start_buffer("other")
      state = with_buffer_pool(state, [original_buf, other_buf])

      opened = EditorState.switch_buffer(state, 1)
      assert opened.workspace.buffers.active == other_buf

      assert %Buffers{active: ^other_buf} =
               TabBar.active(opened.shell_state.tab_bar).context.buffers

      preview_buf = start_buffer("preview")

      preview_state =
        state
        |> with_buffer_pool([original_buf, preview_buf])
        |> EditorState.set_buffer_add_context(:preview)

      previewed = EditorState.switch_buffer(preview_state, 1)
      assert previewed.workspace.buffers.active == preview_buf
      assert previewed.buffer_add_context == :open

      assert %Buffers{active: ^original_buf} =
               TabBar.active(previewed.shell_state.tab_bar).context.buffers
    end
  end

  describe "close_buffer_pure/2" do
    test "closing active, only, inactive, and special buffers updates buffers and monitor refs" do
      state = base_state()
      buf1 = state.workspace.buffers.active
      buf2 = start_buffer("second")

      state =
        state
        |> EditorState.add_buffer(buf2)
        |> EditorState.monitor_buffer(buf1)
        |> EditorState.monitor_buffer(buf2)

      {closed_active, effects} = EditorState.close_buffer_pure(state, buf2)
      assert effects == []
      refute buf2 in closed_active.workspace.buffers.list
      assert closed_active.workspace.buffers.active == buf1
      refute Map.has_key?(closed_active.buffer_monitors, buf2)

      buf3 = start_buffer("third")

      inactive_state =
        state
        |> EditorState.add_buffer(buf3)
        |> EditorState.monitor_buffer(buf3)

      {closed_inactive, _effects} = EditorState.close_buffer_pure(inactive_state, buf1)
      assert closed_inactive.workspace.buffers.active == buf3
      refute buf1 in closed_inactive.workspace.buffers.list

      only_state = base_state()
      only_buf = only_state.workspace.buffers.active
      only_state = EditorState.monitor_buffer(only_state, only_buf)
      {closed_only, effects} = EditorState.close_buffer_pure(only_state, only_buf)
      assert effects == []
      assert closed_only.workspace.buffers.list == []
      assert closed_only.workspace.buffers.active == nil
      refute Map.has_key?(closed_only.buffer_monitors, only_buf)

      msg_buf = start_buffer("")

      special_state =
        state_for_buffer(msg_buf, messages: msg_buf) |> EditorState.monitor_buffer(msg_buf)

      {closed_special, _effects} = EditorState.close_buffer_pure(special_state, msg_buf)
      assert closed_special.workspace.buffers.messages == nil
    end

    test "closing buffers scrubs inactive tab snapshots, including tabs whose only buffer died" do
      buf_a = start_buffer("file A")
      buf_b = start_buffer("file B")

      state =
        state_for_buffer(buf_a, list: [buf_a, buf_b])
        |> EditorState.monitor_buffers([buf_a, buf_b])

      {state, tab_b} = state_with_inactive_tab_buffer(state, buf_b)

      {new_state, _effects} = EditorState.close_buffer_pure(state, buf_b)
      tab_b_after = TabBar.get(EditorState.tab_bar(new_state), tab_b.id)
      refute buf_b in tab_b_after.context.buffers.list
      assert tab_b_after.context.buffers.active != buf_b

      restored_ws = SessionState.restore_tab_context(new_state.workspace, tab_b_after.context)
      refute buf_b in restored_ws.buffers.list
      assert restored_ws.buffers.active != buf_b

      only = start_buffer("only buffer")
      only_state = state_for_buffer(only) |> EditorState.monitor_buffer(only)
      {only_state, only_tab} = state_with_inactive_tab_buffer(only_state, only)
      {closed_only, _effects} = EditorState.close_buffer_pure(only_state, only)
      only_tab_after = TabBar.get(EditorState.tab_bar(closed_only), only_tab.id)
      assert only_tab_after.context.buffers.list == []
      assert only_tab_after.context.buffers.active == nil
    end
  end

  defp state_for_buffer(buf, opts \\ []) do
    buffers = %Buffers{
      active: buf,
      list: Keyword.get(opts, :list, [buf]),
      active_index: 0,
      messages: Keyword.get(opts, :messages)
    }

    %EditorState{
      port_manager: self(),
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        buffers: buffers,
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => Window.new(1, buf, 24, 80)},
          active: 1,
          next_id: 2
        }
      }
    }
  end

  defp with_buffer_pool(state, buffers) do
    EditorState.update_buffers(state, fn %Buffers{} = current ->
      %{current | list: buffers}
    end)
  end

  defp active_window(state),
    do: Map.fetch!(state.workspace.windows.map, state.workspace.windows.active)

  defp state_with_inactive_tab_buffer(state, inactive_buf) do
    tab_a = Tab.new_file(1, "a.ex")
    {tb, tab_b} = TabBar.insert(TabBar.new(tab_a), :file, "b.ex")

    tab_b_context = %{
      buffers: %Buffers{active: inactive_buf, list: [inactive_buf], active_index: 0},
      editing: VimState.new(),
      viewport: Viewport.new(24, 80)
    }

    tb = TabBar.update_context(tb, tab_b.id, tab_b_context)
    state_with_tb = EditorState.set_tab_bar(state, tb)
    tb = TabBar.update_context(tb, 1, EditorState.snapshot_tab_context(state_with_tb))
    {EditorState.set_tab_bar(state, tb), tab_b}
  end
end
