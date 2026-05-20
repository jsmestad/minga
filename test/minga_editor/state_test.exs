defmodule MingaEditor.StateTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Workspace, as: WorkspaceModel
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.State, as: SessionState

  defp new_state do
    %EditorState{
      port_manager: nil,
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new()
      }
    }
  end

  defp start_buffer(content) do
    {:ok, pid} = BufferProcess.start_link(content: content)
    pid
  end

  defp state_with_buffer(content \\ "hello") do
    buf = start_buffer(content)

    state =
      put_in(new_state().workspace.buffers, %Buffers{list: [buf], active_index: 0, active: buf})
      |> setup_windows()

    {state, buf}
  end

  defp setup_windows(state) do
    buf = state.workspace.buffers.active
    tree = WindowTree.new(1)
    window = Window.new(1, buf, 24, 80)

    put_in(state.workspace.windows, %Windows{
      tree: tree,
      map: %{1 => window},
      active: 1,
      next_id: 2
    })
  end

  describe "buffer and window selection" do
    test "add_buffer and switch_buffer sync the active window while preserving inactive split windows" do
      {state, buf1} = state_with_buffer()
      buf2 = start_buffer("world")

      added = EditorState.add_buffer(state, buf2)
      assert added.workspace.buffers.active == buf2
      assert added.workspace.buffers.active_index == 1
      assert added.workspace.buffers.list == [buf1, buf2]
      assert active_window(added).buffer == buf2

      switched = EditorState.switch_buffer(added, 0)
      assert switched.workspace.buffers.active == buf1
      assert switched.workspace.buffers.active_index == 0
      assert active_window(switched).buffer == buf1

      split_state = added |> with_split_window(2, buf2)
      split_switched = EditorState.switch_buffer(split_state, 0)
      assert Map.fetch!(split_switched.workspace.windows.map, 1).buffer == buf1
      assert Map.fetch!(split_switched.workspace.windows.map, 2).buffer == buf2

      split_added = EditorState.add_buffer(split_state, start_buffer("new file"))

      assert Map.fetch!(split_added.workspace.windows.map, 1).buffer ==
               split_added.workspace.buffers.active

      assert Map.fetch!(split_added.workspace.windows.map, 2).buffer == buf2

      no_window = EditorState.add_buffer(new_state(), start_buffer("no window"))
      assert is_pid(no_window.workspace.buffers.active)
    end

    test "focus_window and sync_active_window_cursor snapshot and restore buffer cursors" do
      {state, buf} = state_with_buffer("hello\nworld\nfoo")
      BufferProcess.move_to(buf, {2, 0})

      state = state |> with_split_window(2, buf, second_cursor: {0, 0})
      state = EditorState.sync_active_window_cursor(state)
      assert Map.fetch!(state.workspace.windows.map, 1).cursor == {2, 0}

      BufferProcess.move_to(buf, {1, 3})
      focused = EditorState.focus_window(state, 2)
      assert focused.workspace.windows.active == 2
      assert BufferProcess.cursor(buf) == {0, 0}
      assert Map.fetch!(focused.workspace.windows.map, 1).cursor == {1, 3}

      assert EditorState.focus_window(focused, 2) == focused
      assert EditorState.focus_window(new_state(), 2) == new_state()
      assert EditorState.sync_active_window_cursor(new_state()) == new_state()
    end
  end

  describe "window content synchronization" do
    test "screen rect and buffer sync update buffer windows without rewriting agent chat content" do
      {state, buf1} = state_with_buffer("hello")
      assert EditorState.screen_rect(state) == {0, 0, 80, 23}

      unchanged = EditorState.sync_active_window_buffer(state)
      assert active_window(unchanged).buffer == buf1
      assert active_window(unchanged).content == active_window(state).content

      buf2 = start_buffer("world")
      state = put_in(state.workspace.buffers, Buffers.add(state.workspace.buffers, buf2))
      synced = EditorState.sync_active_window_buffer(state)
      assert active_window(synced).buffer == buf2
      assert Content.buffer?(active_window(synced).content)
      assert Content.buffer_pid(active_window(synced).content) == buf2

      {agent_state, agent_buf} = state_with_agent_tab()
      file_buf = start_buffer("defmodule Foo, do: :ok")

      agent_state =
        put_in(
          agent_state.workspace.buffers,
          Buffers.add(agent_state.workspace.buffers, file_buf)
        )

      synced_agent = EditorState.sync_active_window_buffer(agent_state)
      assert active_window(synced_agent).buffer == agent_buf
      assert Content.agent_chat?(active_window(synced_agent).content)
    end

    test "add_buffer from an agent tab creates an editor file tab and buffer content snapshot" do
      {state, _agent_buf} = state_with_agent_tab()
      file_buf = start_buffer("file content")
      new_state = EditorState.add_buffer(state, file_buf)
      active_tab = TabBar.active(new_state.shell_state.tab_bar)
      active_window = active_window(new_state)
      tab_window = active_tab.context.windows.map[active_tab.context.windows.active]

      assert active_tab.kind == :file
      assert new_state.workspace.keymap_scope == :editor
      assert active_window.buffer == file_buf
      assert Content.buffer?(active_window.content)
      refute Content.agent_chat?(active_window.content)
      assert Content.buffer?(tab_window.content)
    end
  end

  describe "rebind_buffer_file_identity/2" do
    test "only retargets file tabs whose active buffer matches the buffer pid" do
      uniq = System.unique_integer([:positive])
      root = Path.join(System.tmp_dir!(), "minga-state-rebind-buffer-identity-#{uniq}")
      target_path = Path.join([root, "lib", "target.ex"])
      other_path = Path.join([root, "lib", "other.ex"])
      File.mkdir_p!(Path.dirname(target_path))
      File.write!(target_path, "target")
      File.write!(other_path, "other")

      target_buffer =
        start_supervised!(%{
          id: {:target_buffer, uniq},
          start:
            {BufferProcess, :start_link,
             [[file_path: target_path, buffer_name: "target-#{uniq}"]]},
          restart: :temporary
        })

      other_buffer =
        start_supervised!(%{
          id: {:other_buffer, uniq},
          start:
            {BufferProcess, :start_link, [[file_path: other_path, buffer_name: "other-#{uniq}"]]},
          restart: :temporary
        })

      {:ok, target_ref} = FileRef.from_path(root, target_path)
      {:ok, old_active_ref} = FileRef.from_path(root, "lib/active.ex")
      {:ok, old_list_ref} = FileRef.from_path(root, "lib/list-only.ex")
      {:ok, agent_ref} = FileRef.from_path(root, "lib/agent.ex")

      matching_tab =
        Tab.new_file(1, "target")
        |> Tab.set_file_ref(old_active_ref)
        |> Tab.set_context(%{
          buffers: %Buffers{active: target_buffer, list: [target_buffer], active_index: 0}
        })

      list_only_tab =
        Tab.new_file(2, "list-only")
        |> Tab.set_file_ref(old_list_ref)
        |> Tab.set_context(%{
          buffers: %Buffers{
            active: other_buffer,
            list: [other_buffer, target_buffer],
            active_index: 0
          }
        })

      agent_tab =
        Tab.new_agent(3, "Agent")
        |> Tab.set_file_ref(agent_ref)
        |> Tab.set_context(%{
          buffers: %Buffers{active: target_buffer, list: [target_buffer], active_index: 0}
        })

      tab_bar = TabBar.new(matching_tab, root)

      tab_bar = %{
        tab_bar
        | tabs: [matching_tab, list_only_tab, agent_tab],
          active_id: 1,
          next_id: 4
      }

      {tab_bar, agent_workspace} = TabBar.add_workspace(tab_bar, "Agent")

      tab_bar =
        tab_bar
        |> TabBar.move_tab_to_workspace(agent_tab.id, agent_workspace.id)
        |> TabBar.update_workspace(0, fn ws ->
          ws
          |> WorkspaceModel.add_file(old_active_ref)
          |> WorkspaceModel.add_file(old_list_ref)
          |> WorkspaceModel.set_active_file(old_active_ref)
        end)
        |> TabBar.update_workspace(agent_workspace.id, fn ws ->
          ws
          |> WorkspaceModel.add_file(agent_ref)
          |> WorkspaceModel.set_active_file(agent_ref)
        end)

      state = %EditorState{
        port_manager: self(),
        workspace: %SessionState{
          viewport: Viewport.new(24, 80),
          file_tree: %FileTreeState{project_root: root}
        },
        shell_state: %ShellState{tab_bar: tab_bar}
      }

      updated_state = EditorState.rebind_buffer_file_identity(state, target_buffer)
      updated_tb = updated_state.shell_state.tab_bar

      assert TabBar.get(updated_tb, matching_tab.id).file_ref == target_ref
      assert TabBar.get(updated_tb, list_only_tab.id).file_ref == old_list_ref
      assert TabBar.get(updated_tb, agent_tab.id).file_ref == agent_ref
      assert TabBar.get_workspace(updated_tb, 0).active_file == target_ref
      assert WorkspaceModel.has_file?(TabBar.get_workspace(updated_tb, 0), target_ref)
      assert WorkspaceModel.has_file?(TabBar.get_workspace(updated_tb, 0), old_list_ref)
      assert TabBar.get_workspace(updated_tb, agent_workspace.id).active_file == agent_ref

      assert WorkspaceModel.has_file?(
               TabBar.get_workspace(updated_tb, agent_workspace.id),
               agent_ref
             )
    end

    test "rebinds an inactive saved buffer ref even when its context lacks an active buffer" do
      uniq = System.unique_integer([:positive])
      root = Path.join(System.tmp_dir!(), "minga-state-rebind-buffer-identity-minimal-#{uniq}")
      path = Path.join([root, "lib", "target.ex"])
      active_path = Path.join([root, "lib", "active.ex"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(active_path, "active")

      target_buffer =
        start_supervised!(%{
          id: {:target_buffer, uniq},
          start:
            {BufferProcess, :start_link, [[content: "target", buffer_name: "target-#{uniq}"]]},
          restart: :temporary
        })

      active_buffer =
        start_supervised!(%{
          id: {:active_buffer, uniq},
          start:
            {BufferProcess, :start_link,
             [[file_path: active_path, buffer_name: "active-#{uniq}"]]},
          restart: :temporary
        })

      {:ok, active_ref} = FileRef.from_path(root, active_path)
      {:ok, new_ref} = FileRef.from_path(root, path)
      old_ref = FileRef.from_buffer(target_buffer)

      :ok = BufferProcess.save_as(target_buffer, path)

      active_tab =
        Tab.new_file(1, "active.ex")
        |> Tab.set_file_ref(active_ref)
        |> Tab.set_context(%{
          buffers: %Buffers{active: active_buffer, list: [active_buffer], active_index: 0}
        })

      inactive_tab =
        Tab.new_file(2, "scratch")
        |> Tab.set_file_ref(old_ref)
        |> Tab.set_context(%{
          buffers: %Buffers{active: nil, list: [target_buffer], active_index: 0}
        })

      tab_bar = TabBar.new(active_tab, root)

      tab_bar = %{
        tab_bar
        | tabs: [active_tab, inactive_tab],
          active_id: active_tab.id,
          next_id: 3
      }

      tab_bar =
        TabBar.update_workspace(tab_bar, 0, fn ws ->
          ws
          |> WorkspaceModel.add_file(active_ref)
          |> WorkspaceModel.set_active_file(active_ref)
        end)

      state = %EditorState{
        port_manager: self(),
        workspace: %SessionState{
          viewport: Viewport.new(24, 80),
          file_tree: %FileTreeState{project_root: root},
          buffers: %Buffers{active: active_buffer, list: [active_buffer], active_index: 0}
        },
        shell_state: %ShellState{tab_bar: tab_bar}
      }

      updated_state = EditorState.rebind_buffer_file_identity(state, target_buffer)
      updated_tb = updated_state.shell_state.tab_bar

      assert TabBar.get(updated_tb, inactive_tab.id).file_ref == new_ref
      assert TabBar.get(updated_tb, active_tab.id).file_ref == active_ref
      assert TabBar.get_workspace(updated_tb, 0).active_file == active_ref
      assert WorkspaceModel.has_file?(TabBar.get_workspace(updated_tb, 0), new_ref)
      refute WorkspaceModel.has_file?(TabBar.get_workspace(updated_tb, 0), old_ref)
    end
  end

  describe "buffer monitoring" do
    test "monitor helpers store idempotent refs for one or many buffers" do
      buf1 = start_buffer("one")
      buf2 = start_buffer("two")

      state = new_state() |> EditorState.monitor_buffer(buf1)
      assert is_reference(state.buffer_monitors[buf1])

      state2 = EditorState.monitor_buffer(state, buf1)
      assert state2.buffer_monitors[buf1] == state.buffer_monitors[buf1]
      assert map_size(state2.buffer_monitors) == 1

      state3 = new_state() |> EditorState.monitor_buffers([buf1, buf2])
      assert Map.keys(state3.buffer_monitors) |> Enum.sort() == Enum.sort([buf1, buf2])
    end

    test "remove_dead_buffer cleans lists, active buffer, monitors, and special slots" do
      buf1 = start_buffer("one")
      buf2 = start_buffer("two")

      state =
        new_state()
        |> EditorState.add_buffer(buf1)
        |> EditorState.add_buffer(buf2)
        |> EditorState.monitor_buffer(buf1)
        |> EditorState.monitor_buffer(buf2)

      removed_inactive = EditorState.remove_dead_buffer(state, buf1)
      refute buf1 in removed_inactive.workspace.buffers.list
      assert buf2 in removed_inactive.workspace.buffers.list
      refute Map.has_key?(removed_inactive.buffer_monitors, buf1)
      assert Map.has_key?(removed_inactive.buffer_monitors, buf2)

      removed_active = EditorState.remove_dead_buffer(state, buf2)
      assert removed_active.workspace.buffers.active == buf1
      assert removed_active.workspace.buffers.list == [buf1]

      messages = start_buffer("messages")

      special_state =
        put_in(new_state().workspace.buffers, %Buffers{
          messages: messages,
          list: [messages],
          active: messages,
          active_index: 0
        })
        |> EditorState.monitor_buffer(messages)
        |> EditorState.remove_dead_buffer(messages)

      assert special_state.workspace.buffers.messages == nil
      assert special_state.workspace.buffers.list == []
    end
  end

  defp active_window(state) do
    Map.fetch!(state.workspace.windows.map, state.workspace.windows.active)
  end

  defp with_split_window(state, id, buffer, opts \\ []) do
    {:ok, tree} = WindowTree.split(state.workspace.windows.tree, 1, :vertical, id)
    cursor = Keyword.get(opts, :second_cursor, {0, 0})
    win2 = Window.new(id, buffer, 24, 40, cursor)
    windows = state.workspace.windows

    put_in(state.workspace.windows, %{
      windows
      | tree: tree,
        map: Map.put(windows.map, id, win2),
        next_id: id + 1
    })
  end

  defp state_with_agent_tab do
    agent_buf = start_buffer("")

    state =
      put_in(new_state().workspace.buffers, %Buffers{
        list: [agent_buf],
        active_index: 0,
        active: agent_buf
      })

    agent_window = Window.new_agent_chat(1, agent_buf, 24, 80)

    state =
      put_in(state.workspace.windows, %Windows{
        tree: WindowTree.new(1),
        map: %{1 => agent_window},
        active: 1,
        next_id: 2
      })
      |> put_in([Access.key!(:workspace), Access.key!(:keymap_scope)], :agent)
      |> EditorState.set_tab_bar(TabBar.new(Tab.new_agent(1, "Agent")))

    {state, agent_buf}
  end
end
