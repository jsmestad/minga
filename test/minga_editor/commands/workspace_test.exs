defmodule MingaEditor.Commands.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Command
  alias MingaEditor.Commands.Workspace
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport
  alias MingaEditor.Window

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
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: buf, list: [buf]},
        windows: %MingaEditor.State.Windows{
          tree: {:leaf, 1},
          map: %{1 => window},
          active: 1,
          next_id: 2
        }
      },
      shell_state: %MingaEditor.Shell.Traditional.State{tab_bar: tb}
    }
  end

  describe "__commands__/0" do
    test "exports the workspace command contract" do
      commands = Workspace.__commands__()

      assert Enum.all?(commands, &match?(%Command{}, &1))
      assert Enum.any?(commands, &(&1.name == :workspace_next))
      assert Enum.any?(commands, &(&1.name == :workspace_next_agent))

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
    test "switches from manual workspace tabs to the last workspace" do
      state = make_state()
      result = Workspace.workspace_toggle(state)

      assert %EditorState{} = result
      assert result.shell_state.tab_bar.active_id == 3
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
