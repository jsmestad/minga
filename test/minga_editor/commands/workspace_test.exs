defmodule MingaEditor.Commands.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Command
  alias MingaAgent.SessionManager
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.Commands.Workspace
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.State.Workspace, as: WorkspaceModel
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.WorkspaceIconSource
  alias MingaEditor.UI.Picker.WorkspaceSource
  alias MingaEditor.UI.Prompt.WorkspaceRename
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Workspace.State, as: WorkspaceState

  # Builds an EditorState with a manual workspace file tab and two agent workspaces.
  # The manual tab is id 1 / workspace 0; agent tabs are ids 2 and 3 / workspaces 1 and 2.
  defp make_state do
    {:ok, buf} = start_supervised({BufferProcess, content: "hello"})

    window = Window.new(1, buf, 24, 80)

    file_tab = Tab.new_file(1, "file.ex")
    agent_tab_1 = %{Tab.new_agent(2, "Agent 1") | group_id: 1}
    agent_tab_2 = %{Tab.new_agent(3, "Agent 2") | group_id: 2}

    tb = %{
      TabBar.new(file_tab)
      | tabs: [file_tab, agent_tab_1, agent_tab_2],
        active_id: 1,
        next_id: 4
    }

    {tb, _} = TabBar.add_workspace(tb, "Agent 1")

    {tb, _} = TabBar.add_workspace(tb, "Agent 2")

    %EditorState{
      port_manager: self(),
      workspace: %WorkspaceState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: buf, list: [buf]},
        windows: %Windows{
          tree: {:leaf, 1},
          map: %{1 => window},
          active: 1,
          next_id: 2
        }
      },
      shell_state: %TraditionalState{tab_bar: tb}
    }
  end

  defp manual_workspace_state(buffer, mode) do
    %WorkspaceState{
      viewport: Viewport.new(24, 80),
      keymap_scope: :editor,
      buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => Window.new(1, buffer, 24, 80)},
        active: 1,
        next_id: 2
      },
      editing: VimState.transition(VimState.new(), mode)
    }
  end

  defp agent_workspace_state(buffer, mode) do
    %WorkspaceState{
      viewport: Viewport.new(24, 80),
      keymap_scope: :agent,
      buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
      windows: %Windows{
        tree: WindowTree.new(1),
        map: %{1 => Window.new_agent_chat(1, buffer, 24, 80)},
        active: 1,
        next_id: 2
      },
      editing: VimState.transition(VimState.new(), mode)
    }
  end

  defp make_workspace_switch_state do
    manual_saved_buf =
      start_supervised!(
        Supervisor.child_spec({BufferProcess, [content: "manual saved"]},
          id: {:buffer_process, :manual_saved}
        )
      )

    manual_live_buf =
      start_supervised!(
        Supervisor.child_spec({BufferProcess, [content: "manual live"]},
          id: {:buffer_process, :manual_live}
        )
      )

    agent_buf =
      start_supervised!(
        Supervisor.child_spec({BufferProcess, [content: "agent"]},
          id: {:buffer_process, :agent}
        )
      )

    manual_saved_ctx =
      manual_saved_buf
      |> manual_workspace_state(:normal)
      |> TabContext.from_workspace()

    agent_ctx =
      agent_buf
      |> agent_workspace_state(:normal)
      |> TabContext.from_workspace()

    manual_tab = Tab.new_file(1, "manual.ex") |> Tab.set_context(manual_saved_ctx)

    {tb, agent_workspace} = TabBar.add_workspace(TabBar.new(manual_tab), "Agent")

    agent_tab =
      Tab.new_agent(2, "Agent") |> Tab.set_group(agent_workspace.id) |> Tab.set_context(agent_ctx)

    tb = %{tb | tabs: [manual_tab, agent_tab], active_id: 1, next_id: 3}

    state = %EditorState{
      port_manager: self(),
      workspace: manual_workspace_state(manual_live_buf, :insert),
      shell_state: %TraditionalState{tab_bar: tb}
    }

    {state, manual_live_buf, agent_buf}
  end

  describe "__commands__/0" do
    test "exports the workspace command contract" do
      commands = Workspace.__commands__()

      assert Enum.all?(commands, &match?(%Command{}, &1))

      for name <- [
            :workspace_next,
            :workspace_prev,
            :manual_workspace,
            :workspace_toggle,
            :workspace_close,
            :workspace_list,
            :workspace_rename,
            :workspace_set_icon,
            :workspace_next_agent
          ] do
        assert Enum.any?(commands, &(&1.name == name))
      end

      for n <- 1..9 do
        assert Enum.any?(commands, &(&1.name == String.to_atom("workspace_goto_#{n}")))
      end

      assert %{description: "Next workspace", requires_buffer: false} =
               Enum.find(commands, &(&1.name == :workspace_next))

      assert %{description: "Workspace 1", requires_buffer: false} =
               Enum.find(commands, &(&1.name == :workspace_goto_1))
    end
  end

  describe "workspace_next/1" do
    test "switches to the next workspace's first tab" do
      state = make_state()
      result = Workspace.workspace_next(state)

      assert %EditorState{} = result
      assert result.shell_state.tab_bar.active_id == 2
    end
  end

  describe "workspace_prev/1" do
    test "switches to the previous workspace's first tab" do
      state = make_state()
      result = Workspace.workspace_prev(state)

      assert %EditorState{} = result
      assert result.shell_state.tab_bar.active_id == 3
    end
  end

  describe "workspace_toggle/1" do
    test "restores the incoming workspace context and snapshots the tab left behind" do
      {state, manual_live_buf, agent_buf} = make_workspace_switch_state()
      result = Workspace.workspace_toggle(state)

      assert %EditorState{} = result
      assert result.shell_state.tab_bar.active_id == 2
      assert result.workspace.buffers.active == agent_buf
      assert result.workspace.editing.mode == :normal

      manual_tab = TabBar.get(result.shell_state.tab_bar, 1)
      assert manual_tab.context.buffers.active == manual_live_buf
      assert manual_tab.context.editing.mode == :insert
    end
  end

  describe "workspace_close/1" do
    test "migrates the active agent workspace tabs back to manual" do
      state = make_state() |> Workspace.workspace_next()
      result = Workspace.workspace_close(state)

      assert %EditorState{} = result
      tab_bar = result.shell_state.tab_bar
      assert TabBar.active_workspace_id(tab_bar) == 0
      assert TabBar.get_workspace(tab_bar, 1) == nil
      assert Enum.map(TabBar.tabs_in_workspace(tab_bar, 0), & &1.id) == [1, 2]
      assert Enum.map(TabBar.tabs_in_workspace(tab_bar, 2), & &1.id) == [3]
    end

    test "leaving the manual workspace alone is a no-op" do
      state = make_state()
      assert Workspace.workspace_close(state) == state
    end

    test "stops the session owned by the closed workspace" do
      {:ok, _session_id, session} = SessionManager.start_session([])
      on_exit(fn -> stop_session(session) end)
      ref = Process.monitor(session)

      state = make_state() |> Workspace.workspace_next()

      tab_bar =
        TabBar.update_workspace(
          state.shell_state.tab_bar,
          1,
          &WorkspaceModel.set_session(&1, session)
        )

      state = EditorState.set_tab_bar(state, tab_bar)
      result = Workspace.workspace_close(state)

      assert_receive {:DOWN, ^ref, :process, ^session, _reason}
      assert TabBar.get_workspace(result.shell_state.tab_bar, 1) == nil
      assert SessionManager.session_id_for_pid(session) == {:error, :not_found}
    end
  end

  describe "workspace_list/1" do
    test "opens the picker with the active workspace selected" do
      state = make_state() |> Workspace.workspace_next()
      result = Workspace.workspace_list(state)

      assert {:picker,
              %{picker_ui: %{source: WorkspaceSource, picker: %{title: "Switch Workspace"}}}} =
               result.shell_state.modal

      active_item =
        result
        |> Context.from_editor_state()
        |> WorkspaceSource.candidates()
        |> Enum.find(&(&1.id == 1))

      assert active_item.label =~ "Agent 1"
      assert String.ends_with?(active_item.label, " •")
    end
  end

  defp stop_session(pid) when is_pid(pid) do
    AgentSession.stop_session_pid(pid)
  end

  defp stop_session(_pid), do: :ok

  describe "workspace_set_icon/1" do
    test "opens the icon picker for the active workspace" do
      state = make_state() |> Workspace.workspace_next()
      result = Workspace.workspace_set_icon(state)

      assert {:picker,
              %{picker_ui: %{source: WorkspaceIconSource, picker: %{title: "Set Workspace Icon"}}}} =
               result.shell_state.modal

      current_icon =
        result
        |> Context.from_editor_state()
        |> WorkspaceIconSource.candidates()
        |> Enum.find(&(&1.label == "cpu •"))

      assert current_icon != nil
    end
  end

  describe "workspace_rename/1" do
    test "opens the prompt with the active workspace label prefilled" do
      state = make_state() |> Workspace.workspace_next()
      result = Workspace.workspace_rename(state)

      assert {:prompt,
              %{
                prompt_ui: %{
                  handler: WorkspaceRename,
                  label: "Rename workspace: ",
                  text: "Agent 1",
                  cursor: 7
                }
              }} =
               result.shell_state.modal
    end
  end

  describe "switch_to_manual_workspace/1" do
    test "switches to the first manual workspace tab" do
      state = make_state() |> Workspace.workspace_next()
      result = Workspace.switch_to_manual_workspace(state)

      assert %EditorState{} = result
      assert result.shell_state.tab_bar.active_id == 1
    end
  end

  describe "workspace_goto/2" do
    test "workspace 0 switches to manual workspace tabs" do
      state = make_state() |> Workspace.workspace_next()
      result = Workspace.workspace_goto(state, 0)

      assert %EditorState{} = result
      assert result.shell_state.tab_bar.active_id == 1
    end

    test "workspace numbers are one-based" do
      state = make_state()

      assert Workspace.workspace_goto(state, 1).shell_state.tab_bar.active_id == 2
      assert Workspace.workspace_goto(state, 2).shell_state.tab_bar.active_id == 3
    end
  end
end
