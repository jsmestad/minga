defmodule MingaEditor.Commands.AgentGroupTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias MingaEditor.Commands.AgentGroup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport
  alias MingaEditor.Window

  # Builds an EditorState with an ungrouped file tab (id 1, group 0),
  # and two agent groups each with one tab (ids 2 and 3, groups 1 and 2).
  defp make_state do
    {:ok, buf} = start_supervised({BufferServer, content: "hello"})

    window = Window.new(1, buf, 24, 80)

    file_tab = Tab.new_file(1, "file.ex")
    agent_tab_1 = %{Tab.new_agent(2, "Agent 1") | group_id: 1}
    agent_tab_2 = %{Tab.new_agent(3, "Agent 2") | group_id: 2}

    {tb, _} =
      TabBar.add_agent_group(
        %TabBar{
          tabs: [file_tab, agent_tab_1, agent_tab_2],
          active_id: 1,
          next_id: 4
        },
        "Agent 1"
      )

    {tb, _} = TabBar.add_agent_group(tb, "Agent 2")

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

  describe "agent_group_next/1" do
    test "does not crash on EditorState struct" do
      state = make_state()
      # Before the fix, this crashed with KeyError because
      # switch_via_group accessed state.tab_bar instead of
      # state.shell_state.tab_bar
      result = AgentGroup.agent_group_next(state)
      assert %EditorState{} = result
    end
  end

  describe "agent_group_prev/1" do
    test "does not crash on EditorState struct" do
      state = make_state()
      result = AgentGroup.agent_group_prev(state)
      assert %EditorState{} = result
    end
  end

  describe "agent_group_toggle/1" do
    test "does not crash on EditorState struct" do
      state = make_state()
      result = AgentGroup.agent_group_toggle(state)
      assert %EditorState{} = result
    end
  end

  describe "switch_to_ungrouped/1" do
    test "does not crash on EditorState struct" do
      state = make_state()
      result = AgentGroup.switch_to_ungrouped(state)
      assert %EditorState{} = result
    end
  end
end
