defmodule MingaEditor.LayoutPresetTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.LayoutPreset
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.Window.Content

  defp make_state do
    {:ok, buf} = BufferProcess.start_link(content: "hello world")
    window = Window.new(1, buf, 24, 80)

    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: buf, list: [buf]},
        windows: %MingaEditor.State.Windows{
          tree: {:leaf, 1},
          map: %{1 => window},
          active: 1,
          next_id: 2
        }
      }
    }
  end

  describe "apply/3 :agent_right" do
    test "creates a vertical split with agent chat window" do
      state = make_state()

      new_state = LayoutPreset.apply(state, :agent_right, nil)

      # Window tree should be a vertical split
      assert {:split, :vertical, {:leaf, 1}, {:leaf, 2}, _} = new_state.workspace.windows.tree

      # New window should have agent_chat content
      agent_win = new_state.workspace.windows.map[2]
      assert Content.agent_chat?(agent_win.content)
      assert agent_win.buffer == nil

      # Original window unchanged
      assert Content.buffer?(new_state.workspace.windows.map[1].content)

      # next_id incremented
      assert new_state.workspace.windows.next_id == 3
    end

    test "is a no-op if agent chat window already exists" do
      state = make_state()

      state = LayoutPreset.apply(state, :agent_right, nil)
      state2 = LayoutPreset.apply(state, :agent_right, nil)

      assert state == state2
    end
  end

  describe "apply/3 :agent_bottom" do
    test "creates a horizontal split with agent chat window" do
      state = make_state()

      new_state = LayoutPreset.apply(state, :agent_bottom, nil)

      assert {:split, :horizontal, {:leaf, 1}, {:leaf, 2}, _} = new_state.workspace.windows.tree
      assert Content.agent_chat?(new_state.workspace.windows.map[2].content)
    end
  end

  describe "apply/3 :default" do
    test "removes agent chat window" do
      state = make_state()

      state = LayoutPreset.apply(state, :agent_right, nil)
      assert LayoutPreset.has_agent_chat?(state)

      state = LayoutPreset.apply(state, :default, nil)
      refute LayoutPreset.has_agent_chat?(state)

      # Back to single window
      assert {:leaf, 1} = state.workspace.windows.tree
    end

    test "is a no-op if no agent chat window exists" do
      state = make_state()
      state2 = LayoutPreset.apply(state, :default, self())

      assert state == state2
    end
  end

  describe "restore_default/1" do
    test "keeps the agent pane when its focus restore target has died" do
      state = make_state()
      file_buffer = state.workspace.buffers.active

      state =
        state
        |> LayoutPreset.apply(:agent_right, nil)
        |> MingaEditor.WindowFocus.focus(2)

      monitor = Process.monitor(file_buffer)
      GenServer.stop(file_buffer, :normal)
      assert_receive {:DOWN, ^monitor, :process, ^file_buffer, :normal}

      assert LayoutPreset.restore_default(state) == state
      assert state.workspace.windows.active == 2
      assert Map.has_key?(state.workspace.windows.map, 2)
    end

    test "switches active window away from agent before removing" do
      state = make_state()
      file_buffer = state.workspace.buffers.active

      state =
        state
        |> LayoutPreset.apply(:agent_right, nil)
        |> MingaEditor.WindowFocus.focus(2)

      assert state.workspace.windows.active == 2
      assert state.workspace.buffers.active == nil
      assert state.workspace.keymap_scope == :agent

      state = LayoutPreset.restore_default(state)

      # Active should be the file buffer window (1), not the deleted agent window (2)
      assert state.workspace.windows.active == 1
      assert state.workspace.buffers.active == file_buffer
      assert state.workspace.keymap_scope == :editor
      refute Map.has_key?(state.workspace.windows.map, 2)
    end
  end

  describe "has_agent_chat?/1" do
    test "returns false when no agent chat windows" do
      refute LayoutPreset.has_agent_chat?(make_state())
    end

    test "returns true after applying agent preset" do
      state = make_state()
      state = LayoutPreset.apply(state, :agent_right, nil)
      assert LayoutPreset.has_agent_chat?(state)
    end
  end
end
