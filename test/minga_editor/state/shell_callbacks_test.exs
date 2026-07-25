defmodule MingaEditor.State.ShellCallbacksTest do
  @moduledoc """
  Tests for shell callback dispatch in `EditorState`.

  Verifies that buffer activation, removal, and shell-owned tab queries
  functions correctly dispatch through the Shell behaviour. Tests both
  Traditional (with tab bar) and tab-less extension shell paths.

  Part of the shell-owned state transitions proposal
  (`docs/PROPOSAL-shell-state-transitions.md`).
  """

  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Agent
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.State.Workspace.Persistence
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.WindowTree
  alias MingaEditor.Session.State, as: SessionState

  import MingaEditor.RenderPipeline.TestHelpers

  # ── Helpers ──────────────────────────────────────────────────────────────────

  @spec start_buffer(String.t()) :: pid()
  defp start_buffer(content) do
    {:ok, pid} = BufferProcess.start_link(content: content)
    pid
  end

  @spec state_with_file_tab(keyword()) :: EditorState.t()
  defp state_with_file_tab(opts \\ []) do
    state = base_state(opts)
    tab = Tab.new_file(1, "test.ex")
    tb = TabBar.new(tab)
    context = MingaEditor.State.Tab.Context.snapshot(state.workspace)
    tb = TabBar.update_context(tb, 1, context)

    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.install_tab_bar(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          tb
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
  end

  @spec state_with_agent_chat() :: EditorState.t()
  defp state_with_agent_chat do
    win_id = 1
    agent_window = Window.new_agent_chat(win_id, 24, 80)

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      shell_runtime: Runtime.new(Registry.get(:traditional), %TraditionalState{}),
      workspace: %SessionState{
        editing: VimState.new(),
        keymap_scope: :agent,
        buffers: %Buffers{active: nil, list: [], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => agent_window},
          active: win_id,
          next_id: win_id + 1
        }
      }
    }

    state
  end

  @spec state_with_agent_tab() :: EditorState.t()
  defp state_with_agent_tab do
    win_id = 1
    agent_window = Window.new_agent_chat(win_id, 24, 80)

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      shell_runtime: Runtime.new(Registry.get(:traditional), %TraditionalState{}),
      workspace: %SessionState{
        editing: VimState.new(),
        keymap_scope: :agent,
        buffers: %Buffers{active: nil, list: [], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => agent_window},
          active: win_id,
          next_id: win_id + 1
        }
      }
    }

    agent_tab = Tab.new_agent(1, "Agent")
    tb = TabBar.new(agent_tab)
    context = MingaEditor.State.Tab.Context.snapshot(state.workspace)
    tb = TabBar.update_context(tb, 1, context)

    state =
      then(state, fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tb
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    state
  end

  # ── on_buffer_switched via BufferActivation ─────────────────────────────────

  describe "BufferActivation.activate/2 dispatches on_buffer_switched" do
    test "Traditional: tab context.buffers.active tracks workspace after switch" do
      state = state_with_file_tab()
      buf2 = start_buffer("second.ex")
      state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, buf2)

      new_state = MingaEditor.BufferActivation.activate(state, 1)

      assert new_state.workspace.buffers.active == buf2

      active_tab = TabBar.active(new_state.shell_runtime.state.tab_bar)
      assert active_tab.context.buffers.active == buf2
      assert active_tab.context.buffers.active == new_state.workspace.buffers.active
    end

    @tag :tmp_dir
    test "Traditional: workspace file retargeting persists after buffer activation", %{
      tmp_dir: dir
    } do
      first_path = Path.join(dir, "first.ex")
      second_path = Path.join(dir, "second.ex")
      {:ok, first_ref} = FileRef.from_path(dir, first_path)
      {:ok, second_ref} = FileRef.from_path(dir, second_path)

      first_buffer =
        start_supervised!(
          Supervisor.child_spec(
            {BufferProcess, content: "first", file_path: first_path},
            id: make_ref()
          )
        )

      second_buffer =
        start_supervised!(
          Supervisor.child_spec(
            {BufferProcess, content: "second", file_path: second_path},
            id: make_ref()
          )
        )

      state = base_state()

      workspace =
        state.workspace
        |> SessionState.set_buffers(%Buffers{
          active: first_buffer,
          list: [first_buffer, second_buffer],
          active_index: 0
        })
        |> SessionState.set_file_tree(%FileTreeState{project_root: dir})

      tab = Tab.new_file(1, "first.ex") |> Tab.set_file_ref(first_ref)
      tab_bar = TabBar.new(tab, dir)
      {tab_bar, agent_workspace} = TabBar.add_workspace(tab_bar, "Agent")

      tab_bar =
        tab_bar
        |> TabBar.move_tab_to_workspace(tab.id, agent_workspace.id)
        |> TabBar.retarget_tab_file(tab.id, first_ref)
        |> TabBar.update_context(tab.id, MingaEditor.State.Tab.Context.snapshot(workspace))

      shell_state = TraditionalState.install_tab_bar(state.shell_runtime.state, tab_bar)

      state = %{
        state
        | workspace: workspace,
          shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)
      }

      activated = MingaEditor.BufferActivation.activate(state, 1)

      assert activated.workspace.buffers.active == second_buffer

      assert {:ok, persisted} =
               Persistence.read(Persistence.path_for(dir, agent_workspace.id), dir)

      assert Enum.any?(persisted.files, &FileRef.equal?(&1, second_ref))
    end

    test "Traditional: agent tab context.buffers.active tracks workspace after switch" do
      state = state_with_agent_tab()
      buf1 = start_buffer("first agent workspace buffer")
      buf2 = start_buffer("second agent workspace buffer")

      # Manually add buf2 to the buffer list without triggering tab creation
      # (EditorState.add_buffer from an agent tab would create a new file tab)
      state =
        then(state, fn state ->
          %{
            state
            | workspace:
                then(
                  state.workspace,
                  &MingaEditor.Session.State.set_buffers(
                    &1,
                    (fn buffers ->
                       %{buffers | active: buf1, list: [buf1, buf2], active_index: 0}
                     end).(state.workspace.buffers)
                  )
                )
          }
        end)

      new_state = MingaEditor.BufferActivation.activate(state, 1)

      assert new_state.workspace.buffers.active == buf2

      active_tab = TabBar.active(new_state.shell_runtime.state.tab_bar)
      assert active_tab.kind == :agent
      assert active_tab.context.buffers.active == buf2
      assert active_tab.context.buffers.active == new_state.workspace.buffers.active
    end

    test "Traditional: find_tab_by_buffer returns active tab after switch" do
      state = state_with_file_tab()
      buf2 = start_buffer("second.ex")
      state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, buf2)

      new_state = MingaEditor.BufferActivation.activate(state, 1)

      tab = MingaEditor.Shell.Runtime.find_tab_by_buffer(new_state.shell_runtime, buf2)
      assert %Tab{kind: :file} = tab
      assert tab.id == new_state.shell_runtime.state.tab_bar.active_id
    end

    test "Traditional: dirty marker queries correct buffer after switch" do
      state = state_with_file_tab()
      buf1 = state.workspace.buffers.active
      buf2 = start_buffer("clean.ex")
      state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, buf2)

      BufferProcess.insert_char(buf1, "x")
      assert BufferProcess.dirty?(buf1)
      refute BufferProcess.dirty?(buf2)

      new_state = MingaEditor.BufferActivation.activate(state, 1)

      active_tab = TabBar.active(new_state.shell_runtime.state.tab_bar)
      tab_buf = active_tab.context.buffers.active
      assert tab_buf == buf2
      refute BufferProcess.dirty?(tab_buf)
    end

    test "Traditional: repeated switch_buffer cycles maintain snapshot invariant" do
      state = state_with_file_tab()
      buf2 = start_buffer("second.ex")
      buf3 = start_buffer("third.ex")
      state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, buf2)
      state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, buf3)

      state = MingaEditor.BufferActivation.activate(state, 1)
      assert TabBar.active(state.shell_runtime.state.tab_bar).context.buffers.active == buf2

      state = MingaEditor.BufferActivation.activate(state, 2)
      assert TabBar.active(state.shell_runtime.state.tab_bar).context.buffers.active == buf3

      state = MingaEditor.BufferActivation.activate(state, 0)
      buf1 = state.workspace.buffers.active
      assert TabBar.active(state.shell_runtime.state.tab_bar).context.buffers.active == buf1

      assert MingaEditor.Shell.Runtime.find_tab_by_buffer(state.shell_runtime, buf1) != nil
    end

    test "no tab bar: switch_buffer still works" do
      state = base_state()
      buf2 = start_buffer("second")
      state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, buf2)

      # Switch back to first buffer
      new_state = MingaEditor.BufferActivation.activate(state, 0)

      # The active buffer changed without error
      refute new_state.workspace.buffers.active == buf2
    end

    test "tab-less extension shell: switch_buffer preserves agent_chat window content" do
      state = state_with_agent_chat()
      file_buf = start_buffer("file content")

      # Add file buffer (the tab-less shell's on_buffer_added doesn't overwrite agent_chat)
      state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, file_buf)

      # Verify window still shows agent_chat
      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      assert Content.agent_chat?(window.content)

      # Switch to the only file buffer. The agent window content stays semantic.
      new_state = MingaEditor.BufferActivation.activate(state, 0)
      assert new_state.workspace.buffers.active == file_buf

      # Window content should still be agent_chat
      window = Map.fetch!(new_state.workspace.windows.map, win_id)
      assert Content.agent_chat?(window.content)
    end
  end

  # ── on_buffer_died via remove_buffer/2 ───────────────────────────────────────

  describe "remove_buffer/2 dispatches on_buffer_died" do
    test "Traditional: syncs active window after buffer death" do
      state = state_with_file_tab()
      buf1 = state.workspace.buffers.active
      buf2 = start_buffer("second")
      state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, buf2)
      state = MingaEditor.Handlers.BufferRegistry.monitor_buffer(state, buf1)
      state = MingaEditor.Handlers.BufferRegistry.monitor_buffer(state, buf2)

      # Close the active buffer (buf2)
      new_state = EditorState.remove_buffer(state, buf2)

      # buf1 should become active
      assert new_state.workspace.buffers.active == buf1

      # Window should be synced to show buf1 (via on_buffer_died callback)
      win_id = new_state.workspace.windows.active
      window = Map.fetch!(new_state.workspace.windows.map, win_id)
      assert window.content == {:buffer, buf1}
    end

    test "tab-less extension shell: preserves agent_chat window content on buffer death" do
      state = state_with_agent_chat()
      file_buf = start_buffer("file content")

      # Add and monitor the file buffer
      state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, file_buf)
      state = MingaEditor.Handlers.BufferRegistry.monitor_buffer(state, file_buf)

      # Verify agent_chat window
      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      assert Content.agent_chat?(window.content)

      # Close the file buffer
      new_state = EditorState.remove_buffer(state, file_buf)

      # Window should still show agent_chat (on_buffer_died respects content guard)
      window = Map.fetch!(new_state.workspace.windows.map, win_id)

      assert Content.agent_chat?(window.content),
             "agent_chat window content should be preserved after buffer death"
    end
  end

  # ── Tab delegate callbacks ──────────────────────────────────────────────────

  describe "Runtime.active_tab/1 delegates to shell" do
    test "Traditional: returns active tab" do
      state = state_with_file_tab()
      tab = MingaEditor.Shell.Runtime.active_tab(state.shell_runtime)
      assert %Tab{kind: :file} = tab
    end

    test "no tab bar: returns nil" do
      state = base_state()
      assert MingaEditor.Shell.Runtime.active_tab(state.shell_runtime) == nil
    end
  end

  describe "Runtime.find_tab_by_buffer/2 delegates to shell" do
    test "Traditional: finds tab by buffer pid" do
      state = state_with_file_tab()
      buf = state.workspace.buffers.active

      tab = MingaEditor.Shell.Runtime.find_tab_by_buffer(state.shell_runtime, buf)
      assert %Tab{kind: :file} = tab
    end

    test "Traditional: returns nil for unknown buffer" do
      state = state_with_file_tab()
      fake_pid = spawn(fn -> :ok end)
      assert MingaEditor.Shell.Runtime.find_tab_by_buffer(state.shell_runtime, fake_pid) == nil
    end

    test "no tab bar: returns nil" do
      state = base_state()
      buf = state.workspace.buffers.active
      assert MingaEditor.Shell.Runtime.find_tab_by_buffer(state.shell_runtime, buf) == nil
    end
  end

  describe "active_tab_kind/1 delegates to shell" do
    test "Traditional: returns :file for file tab" do
      state = state_with_file_tab()
      assert MingaEditor.Shell.Runtime.active_tab_kind(state.shell_runtime) == :file
    end

    test "no tab bar: returns :file (default)" do
      state = base_state()
      assert MingaEditor.Shell.Runtime.active_tab_kind(state.shell_runtime) == :file
    end
  end

  describe "set_tab_session/3 delegates to shell" do
    test "Traditional: associates session pid with tab" do
      tab = Tab.new_agent(1, "Agent")
      tb = TabBar.new(tab)
      {tb, workspace} = TabBar.add_workspace(tb, "Agent")
      tb = TabBar.move_tab_to_workspace(tb, tab.id, workspace.id)

      state = %EditorState{
        shell_runtime: Runtime.new(Runtime.default_entry(), %TraditionalState{tab_bar: tb}),
        workspace: %SessionState{}
      }

      session_pid = spawn(fn -> :ok end)
      tab = MingaEditor.Shell.Runtime.active_tab(state.shell_runtime)

      new_state =
        then(state, fn state ->
          %{
            state
            | shell_runtime:
                MingaEditor.Shell.Runtime.set_tab_session(
                  state.shell_runtime,
                  tab.id,
                  session_pid
                )
          }
        end)

      updated_tab = MingaEditor.Shell.Runtime.active_tab(new_state.shell_runtime)
      assert %Agent{session: ^session_pid} = updated_tab.payload
    end

    test "no tab bar: set_tab_session is no-op" do
      state = base_state()
      session_pid = spawn(fn -> :ok end)

      # Should not crash
      new_state =
        then(state, fn state ->
          %{
            state
            | shell_runtime:
                MingaEditor.Shell.Runtime.set_tab_session(state.shell_runtime, 1, session_pid)
          }
        end)

      assert new_state.shell_runtime == state.shell_runtime
    end
  end

  # ── switch_tab/2 no longer pattern-matches tab_bar ──────────────────────────

  describe "switch_tab/2 accessor-based dispatch" do
    test "no-op when tab bar is nil" do
      state = base_state()
      {new_state, result} = EditorState.switch_tab(state, 999)
      assert new_state == state
      assert result == :unchanged
    end

    test "no-op when switching to already active tab" do
      state = state_with_file_tab()
      tb = state.shell_runtime.state.tab_bar
      active_id = tb.active_id

      {new_state, result} = EditorState.switch_tab(state, active_id)
      assert new_state == state
      assert result == :unchanged
    end
  end
end
