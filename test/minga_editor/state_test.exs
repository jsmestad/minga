defmodule MingaEditor.StateTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Frontend, as: FrontendState
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.Remote
  alias MingaEditor.State.Workspace, as: WorkspaceModel
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.State, as: SessionState

  defp new_state do
    %EditorState{
      workspace: %MingaEditor.Session.State{editing: VimState.new()}
    }
  end

  defp start_buffer(content) do
    {:ok, pid} = BufferProcess.start_link(content: content)
    pid
  end

  defp state_with_buffer(content \\ "hello") do
    buf = start_buffer(content)

    state =
      %{
        new_state()
        | workspace:
            SessionState.set_buffers(new_state().workspace, %Buffers{
              list: [buf],
              active_index: 0,
              active: buf
            })
      }
      |> setup_windows()

    {state, buf}
  end

  defp setup_windows(state) do
    buf = state.workspace.buffers.active
    tree = WindowTree.new(1)
    window = Window.new(1, buf, 24, 80)

    %{
      state
      | workspace:
          SessionState.set_windows(state.workspace, %Windows{
            tree: tree,
            map: %{1 => window},
            active: 1,
            next_id: 2
          })
    }
  end

  describe "root ownership shape" do
    test "contains exactly the documented 16 owner fields" do
      state = %EditorState{workspace: %SessionState{}}

      assert state |> Map.keys() |> List.delete(:__struct__) |> Enum.sort() == [
               :agent_connection,
               :appearance,
               :buffer_lifecycle,
               :effect_scheduler,
               :extension_surfaces,
               :feedback,
               :frontend,
               :git,
               :interaction,
               :lsp,
               :parser,
               :remote,
               :render,
               :session,
               :shell_runtime,
               :workspace
             ]
    end
  end

  describe "buffer and window selection" do
    test "buffer activation synchronizes the active window while preserving inactive split windows" do
      {state, buf1} = state_with_buffer()
      buf2 = start_buffer("world")

      added = MingaEditor.Handlers.BufferRegistry.add_buffer(state, buf2)
      assert added.workspace.buffers.active == buf2
      assert added.workspace.buffers.active_index == 1
      assert added.workspace.buffers.list == [buf1, buf2]
      assert Content.buffer_pid(active_window(added).content) == buf2

      switched = MingaEditor.BufferActivation.activate(added, 0)
      assert switched.workspace.buffers.active == buf1
      assert switched.workspace.buffers.active_index == 0
      assert Content.buffer_pid(active_window(switched).content) == buf1

      split_state = added |> with_split_window(2, buf2)
      split_switched = MingaEditor.BufferActivation.activate(split_state, 0)

      assert Content.buffer_pid(Map.fetch!(split_switched.workspace.windows.map, 1).content) ==
               buf1

      assert Content.buffer_pid(Map.fetch!(split_switched.workspace.windows.map, 2).content) ==
               buf2

      split_added =
        MingaEditor.Handlers.BufferRegistry.add_buffer(split_state, start_buffer("new file"))

      assert Content.buffer_pid(Map.fetch!(split_added.workspace.windows.map, 1).content) ==
               split_added.workspace.buffers.active

      assert Content.buffer_pid(Map.fetch!(split_added.workspace.windows.map, 2).content) == buf2

      no_window =
        MingaEditor.Handlers.BufferRegistry.add_buffer(new_state(), start_buffer("no window"))

      assert is_pid(no_window.workspace.buffers.active)
    end

    test "window focus snapshots and restores buffer cursors" do
      {state, buf} = state_with_buffer("hello\nworld\nfoo")
      BufferProcess.move_to(buf, {2, 0})

      state = state |> with_split_window(2, buf, second_cursor: {0, 0})
      state = MingaEditor.WindowFocus.remember_active_cursor(state)
      assert Map.fetch!(state.workspace.windows.map, 1).cursor == {2, 0}

      BufferProcess.move_to(buf, {1, 3})
      focused = MingaEditor.WindowFocus.focus(state, 2)
      assert focused.workspace.windows.active == 2
      assert BufferProcess.cursor(buf) == {0, 0}
      assert Map.fetch!(focused.workspace.windows.map, 1).cursor == {1, 3}

      assert MingaEditor.WindowFocus.focus(focused, 2) == focused
      assert MingaEditor.WindowFocus.focus(new_state(), 2) == new_state()
      assert MingaEditor.WindowFocus.remember_active_cursor(new_state()) == new_state()
    end

    test "cursor snapshot does not write an active buffer cursor into another buffer window" do
      {state, files_buf} = state_with_buffer("files")
      file_buf = start_buffer("typed text")
      BufferProcess.move_to(file_buf, {0, 5})

      state = %{
        state
        | workspace:
            SessionState.set_buffers(
              state.workspace,
              Buffers.add(state.workspace.buffers, file_buf)
            )
      }

      synced = MingaEditor.WindowFocus.remember_active_cursor(state)

      assert Content.buffer_pid(active_window(synced).content) == files_buf
      assert active_window(synced).cursor == active_window(state).cursor
    end
  end

  describe "tab context restore" do
    test "file tab restore syncs the active window back to the restored active buffer" do
      {state, files_buf} = state_with_buffer("files")
      file_buf = start_buffer("typed text")
      buffers = %Buffers{list: [files_buf, file_buf], active: file_buf, active_index: 1}
      windows = state.workspace.windows
      files_window = Window.new(1, files_buf, 24, 80)

      context =
        %{state.workspace | buffers: buffers, windows: %{windows | map: %{1 => files_window}}}
        |> SessionState.to_tab_context()

      tab = Tab.new_file(1, "Untitled-1") |> Tab.set_context(context)

      state =
        then(state, fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              TabBar.new(tab)
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      restored = EditorState.restore_tab_context(state, context)

      assert restored.workspace.buffers.active == file_buf
      assert Content.buffer_pid(active_window(restored).content) == file_buf
      assert Content.buffer_pid(active_window(restored).content) == file_buf
    end
  end

  describe "window content synchronization" do
    test "screen rect and buffer activation update buffer windows without rewriting agent chat content" do
      {state, buf1} = state_with_buffer("hello")

      unchanged =
        MingaEditor.BufferActivation.activate(state, state.workspace.buffers,
          notify_shell?: false
        )

      assert Content.buffer_pid(active_window(unchanged).content) == buf1
      assert active_window(unchanged).content == active_window(state).content

      buf2 = start_buffer("world")

      state = %{
        state
        | workspace:
            SessionState.set_buffers(state.workspace, Buffers.add(state.workspace.buffers, buf2))
      }

      synced =
        MingaEditor.BufferActivation.activate(state, state.workspace.buffers,
          notify_shell?: false
        )

      assert Content.buffer_pid(active_window(synced).content) == buf2
      assert Content.buffer?(active_window(synced).content)
      assert Content.buffer_pid(active_window(synced).content) == buf2

      agent_state = state_with_agent_tab()
      file_buf = start_buffer("defmodule Foo, do: :ok")

      agent_state = %{
        agent_state
        | workspace:
            SessionState.set_buffers(
              agent_state.workspace,
              Buffers.add(agent_state.workspace.buffers, file_buf)
            )
      }

      synced_agent =
        MingaEditor.BufferActivation.activate(agent_state, agent_state.workspace.buffers,
          notify_shell?: false
        )

      assert Content.buffer_pid(active_window(synced_agent).content) == nil
      assert Content.agent_chat?(active_window(synced_agent).content)
    end

    test "add_buffer from an agent tab creates an editor file tab and buffer content snapshot" do
      state = state_with_agent_tab()
      file_buf = start_buffer("file content")
      new_state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, file_buf)
      active_tab = TabBar.active(new_state.shell_runtime.state.tab_bar)
      active_window = active_window(new_state)
      tab_window = active_tab.context.windows.map[active_tab.context.windows.active]

      assert active_tab.kind == :file
      assert new_state.workspace.keymap_scope == :editor
      assert Content.buffer_pid(active_window.content) == file_buf
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

      manual_workspace =
        tab_bar
        |> TabBar.get_workspace(0)
        |> WorkspaceModel.add_file(old_active_ref)
        |> WorkspaceModel.add_file(old_list_ref)

      agent_workspace =
        agent_workspace
        |> WorkspaceModel.add_file(agent_ref)

      tab_bar =
        tab_bar
        |> TabBar.move_tab_to_workspace(agent_tab.id, agent_workspace.id)
        |> TabBar.accept_workspace(manual_workspace)
        |> TabBar.accept_workspace(agent_workspace)

      state = %EditorState{
        frontend: FrontendState.new(port_manager: self()),
        workspace:
          %SessionState{}
          |> SessionState.set_file_tree(%FileTreeState{project_root: root}),
        shell_runtime: Runtime.new(Runtime.default_entry(), %ShellState{tab_bar: tab_bar})
      }

      updated_state =
        MingaEditor.BufferFileIdentity.rebind(state, target_buffer, target_path)

      updated_tb = updated_state.shell_runtime.state.tab_bar

      assert TabBar.get(updated_tb, matching_tab.id).file_ref == target_ref
      assert TabBar.get(updated_tb, list_only_tab.id).file_ref == old_list_ref
      assert TabBar.get(updated_tb, agent_tab.id).file_ref == agent_ref
      assert WorkspaceModel.has_file?(TabBar.get_workspace(updated_tb, 0), target_ref)
      assert WorkspaceModel.has_file?(TabBar.get_workspace(updated_tb, 0), old_list_ref)

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

      manual_workspace =
        tab_bar
        |> TabBar.get_workspace(0)
        |> WorkspaceModel.add_file(active_ref)

      tab_bar = TabBar.accept_workspace(tab_bar, manual_workspace)

      state = %EditorState{
        frontend: FrontendState.new(port_manager: self()),
        workspace:
          %SessionState{
            buffers: %Buffers{active: active_buffer, list: [active_buffer], active_index: 0}
          }
          |> SessionState.set_file_tree(%FileTreeState{project_root: root}),
        shell_runtime: Runtime.new(Runtime.default_entry(), %ShellState{tab_bar: tab_bar})
      }

      updated_state = MingaEditor.BufferFileIdentity.rebind(state, target_buffer, path)
      updated_tb = updated_state.shell_runtime.state.tab_bar

      assert TabBar.get(updated_tb, inactive_tab.id).file_ref == new_ref
      assert TabBar.get(updated_tb, active_tab.id).file_ref == active_ref
      assert WorkspaceModel.has_file?(TabBar.get_workspace(updated_tb, 0), new_ref)
      refute WorkspaceModel.has_file?(TabBar.get_workspace(updated_tb, 0), old_ref)
    end
  end

  describe "buffer monitoring" do
    test "monitor helpers store idempotent refs for one or many buffers" do
      buf1 = start_buffer("one")
      buf2 = start_buffer("two")

      state = new_state() |> MingaEditor.Handlers.BufferRegistry.monitor_buffer(buf1)
      assert is_reference(state.buffer_lifecycle.buffer_monitors[buf1])

      state2 = MingaEditor.Handlers.BufferRegistry.monitor_buffer(state, buf1)

      assert state2.buffer_lifecycle.buffer_monitors[buf1] ==
               state.buffer_lifecycle.buffer_monitors[buf1]

      assert map_size(state2.buffer_lifecycle.buffer_monitors) == 1

      state3 = new_state() |> MingaEditor.Handlers.BufferRegistry.monitor_buffers([buf1, buf2])

      assert Map.keys(state3.buffer_lifecycle.buffer_monitors) |> Enum.sort() ==
               Enum.sort([buf1, buf2])
    end

    test "remove_dead_buffer cleans lists, active buffer, monitors, and special slots" do
      buf1 = start_buffer("one")
      buf2 = start_buffer("two")

      state =
        new_state()
        |> MingaEditor.Handlers.BufferRegistry.add_buffer(buf1)
        |> MingaEditor.Handlers.BufferRegistry.add_buffer(buf2)
        |> MingaEditor.Handlers.BufferRegistry.monitor_buffer(buf1)
        |> MingaEditor.Handlers.BufferRegistry.monitor_buffer(buf2)

      state = %{
        state
        | remote:
            state.remote
            |> Remote.put_buffer("server-a", "/remote/one.ex", buf1)
            |> Remote.put_buffer("server-b", "/remote/one.ex", buf1)
            |> Remote.put_buffer("server-a", "/remote/two.ex", buf2),
          lsp:
            state.lsp
            |> LSPState.accept_semantic_tokens(buf1, 0, ["@lsp.type.variable"], [])
            |> LSPState.accept_semantic_tokens(buf2, 0, ["@lsp.type.variable"], [])
      }

      removed_inactive = EditorState.remove_buffer(state, buf1)
      refute buf1 in removed_inactive.workspace.buffers.list
      assert buf2 in removed_inactive.workspace.buffers.list
      refute Map.has_key?(removed_inactive.buffer_lifecycle.buffer_monitors, buf1)
      assert Map.has_key?(removed_inactive.buffer_lifecycle.buffer_monitors, buf2)
      refute Map.has_key?(removed_inactive.lsp.semantic_tokens, buf1)
      assert Map.has_key?(removed_inactive.lsp.semantic_tokens, buf2)
      refute Remote.buffer(removed_inactive.remote, "server-a", "/remote/one.ex")
      refute Remote.buffer(removed_inactive.remote, "server-b", "/remote/one.ex")
      assert Remote.buffer(removed_inactive.remote, "server-a", "/remote/two.ex") == buf2

      refute Enum.any?(Remote.all_buffers(removed_inactive.remote), fn {_server, _path, pid} ->
               pid == buf1
             end)

      removed_active = EditorState.remove_buffer(state, buf2)
      assert removed_active.workspace.buffers.active == buf1
      assert removed_active.workspace.buffers.list == [buf1]
      assert Remote.buffer(removed_active.remote, "server-a", "/remote/one.ex") == buf1
      assert Remote.buffer(removed_active.remote, "server-b", "/remote/one.ex") == buf1
      refute Remote.buffer(removed_active.remote, "server-a", "/remote/two.ex")
      refute Map.has_key?(removed_active.lsp.semantic_tokens, buf2)
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

    %{
      state
      | workspace:
          SessionState.set_windows(state.workspace, %{
            windows
            | tree: tree,
              map: Map.put(windows.map, id, win2),
              next_id: id + 1
          })
    }
  end

  defp state_with_agent_tab do
    root = new_state()

    state = %{
      root
      | workspace:
          SessionState.set_buffers(root.workspace, %Buffers{
            list: [],
            active_index: 0,
            active: nil
          })
    }

    agent_window = Window.new_agent_chat(1, 24, 80)

    state =
      %{
        state
        | workspace:
            SessionState.set_windows(state.workspace, %Windows{
              tree: WindowTree.new(1),
              map: %{1 => agent_window},
              active: 1,
              next_id: 2
            })
      }
      |> then(fn root ->
        %{root | workspace: SessionState.set_keymap_scope(root.workspace, :agent)}
      end)
      |> then(fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            TabBar.new(Tab.new_agent(1, "Agent"))
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    state
  end
end
