defmodule Minga.Editor.Commands.AgentSplitTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.UIState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.LayoutPreset
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Test.StubServer

  defp make_state do
    {:ok, buf} = BufferServer.start_link(content: "hello world")
    {:ok, _prompt_buf} = BufferServer.start_link(content: "")
    agent_buf = AgentBufferSync.start_buffer()
    {:ok, fake_session} = StubServer.start_link()

    window = Window.new(1, buf, 24, 80)

    agent = %AgentState{
      buffer: agent_buf,
      session: fake_session,
      status: :idle,
      error: nil,
      spinner_timer: nil
    }

    # Create a background agent tab to hold agent state
    file_tab = Tab.new_file(1, "[no file]")

    file_context = %{
      keymap_scope: :editor
    }

    file_tab = %{file_tab | context: file_context}
    agent_tab = Tab.new_agent(2, "Agent")

    agent_context = %{
      keymap_scope: :agent
    }

    agent_tab = %{agent_tab | context: agent_context}

    tb = %TabBar{
      tabs: [file_tab, agent_tab],
      active_id: 1,
      next_id: 3
    }

    %EditorState{
      port_manager: self(),
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      buffers: %Buffers{active: buf, list: [buf]},
      windows: %{
        tree: {:leaf, 1},
        map: %{1 => window},
        active: 1,
        next_id: 2
      },
      vim: VimState.new(),
      keymap_scope: :editor,
      agent: agent,
      agent_ui: UIState.new(),
      tab_bar: tb,
      file_tree: %FileTreeState{}
    }
  end

  describe "toggle_agent_split/1" do
    test "creates agent chat split pane" do
      state = make_state()

      refute LayoutPreset.has_agent_chat?(state)

      new_state = AgentCommands.toggle_agent_split(state)

      assert LayoutPreset.has_agent_chat?(new_state)

      # Window tree should have a split
      assert {:split, :vertical, {:leaf, 1}, {:leaf, 2}, _} = new_state.windows.tree

      # New window is agent chat content
      agent_win = new_state.windows.map[2]
      assert Content.agent_chat?(agent_win.content)
    end

    test "toggles off: removes agent chat pane" do
      state = make_state()

      state = AgentCommands.toggle_agent_split(state)
      assert LayoutPreset.has_agent_chat?(state)

      state = AgentCommands.toggle_agent_split(state)
      refute LayoutPreset.has_agent_chat?(state)

      # Back to single window
      assert {:leaf, 1} = state.windows.tree
    end

    test "preserves file buffer as active" do
      state = make_state()
      original_buf = state.buffers.active

      new_state = AgentCommands.toggle_agent_split(state)

      # File buffer window is still active
      assert new_state.windows.active == 1
      assert new_state.buffers.active == original_buf
    end

    test "stays on editor keymap scope" do
      state = make_state()

      new_state = AgentCommands.toggle_agent_split(state)

      # Focus is on the file buffer window, so scope stays :editor
      assert new_state.keymap_scope == :editor
    end

    test "is idempotent (double-apply is a no-op)" do
      state = make_state()
      state = AgentCommands.toggle_agent_split(state)

      state2 = AgentCommands.toggle_agent_split(state)

      # Toggling again removes the pane
      refute LayoutPreset.has_agent_chat?(state2)
    end
  end
end
