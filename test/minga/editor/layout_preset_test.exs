defmodule Minga.Editor.LayoutPresetTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.LayoutPreset
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content

  defp make_state do
    {:ok, buf} = BufferServer.start_link(content: "hello world")
    window = Window.new(1, buf, 24, 80)

    %EditorState{
      port_manager: self(),
      workspace: %Minga.Workspace.State{
        viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
        buffers: %Buffers{active: buf, list: [buf]},
        windows: %{
          tree: {:leaf, 1},
          map: %{1 => window},
          active: 1,
          next_id: 2
        },
        vim: VimState.new(),
        keymap_scope: :editor
      }
    }
  end

  defp agent_buffer do
    {:ok, buf} = BufferServer.start_link(content: "## Agent\n\nHello")
    buf
  end

  describe "apply/3 :agent_right" do
    test "creates a vertical split with agent chat window" do
      state = make_state()
      buf = agent_buffer()

      new_state = LayoutPreset.apply(state, :agent_right, buf)

      # Window tree should be a vertical split
      assert {:split, :vertical, {:leaf, 1}, {:leaf, 2}, _} = new_state.workspace.windows.tree

      # New window should have agent_chat content
      agent_win = new_state.workspace.windows.map[2]
      assert Content.agent_chat?(agent_win.content)
      assert agent_win.buffer == buf

      # Original window unchanged
      assert Content.buffer?(new_state.workspace.windows.map[1].content)

      # next_id incremented
      assert new_state.workspace.windows.next_id == 3
    end

    test "is a no-op if agent chat window already exists" do
      state = make_state()
      buf = agent_buffer()

      state = LayoutPreset.apply(state, :agent_right, buf)
      state2 = LayoutPreset.apply(state, :agent_right, buf)

      assert state == state2
    end
  end

  describe "apply/3 :agent_bottom" do
    test "creates a horizontal split with agent chat window" do
      state = make_state()
      buf = agent_buffer()

      new_state = LayoutPreset.apply(state, :agent_bottom, buf)

      assert {:split, :horizontal, {:leaf, 1}, {:leaf, 2}, _} = new_state.workspace.windows.tree
      assert Content.agent_chat?(new_state.workspace.windows.map[2].content)
    end
  end

  describe "apply/3 :default" do
    test "removes agent chat window" do
      state = make_state()
      buf = agent_buffer()

      state = LayoutPreset.apply(state, :agent_right, buf)
      assert LayoutPreset.has_agent_chat?(state)

      state = LayoutPreset.apply(state, :default, buf)
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
    test "switches active window away from agent before removing" do
      state = make_state()
      buf = agent_buffer()

      state = LayoutPreset.apply(state, :agent_right, buf)

      # Set agent window as active
      state = %{state | workspace: %{state.workspace | windows: %{state.workspace.windows | active: 2}}}

      state = LayoutPreset.restore_default(state)

      # Active should be the file buffer window (1), not the deleted agent window (2)
      assert state.workspace.windows.active == 1
      refute Map.has_key?(state.workspace.windows.map, 2)
    end
  end

  describe "has_agent_chat?/1" do
    test "returns false when no agent chat windows" do
      refute LayoutPreset.has_agent_chat?(make_state())
    end

    test "returns true after applying agent preset" do
      state = make_state()
      state = LayoutPreset.apply(state, :agent_right, agent_buffer())
      assert LayoutPreset.has_agent_chat?(state)
    end
  end
end
