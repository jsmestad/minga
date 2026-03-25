defmodule Minga.Editor.Commands.AgentSplitTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.UIState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Agent, as: AgentCommands
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

    # File tab with context
    file_tab = Tab.new_file(1, "[no file]")

    file_context = %{
      keymap_scope: :editor,
      windows: %{
        tree: {:leaf, 1},
        map: %{1 => window},
        active: 1,
        next_id: 2
      }
    }

    file_tab = %{file_tab | context: file_context}

    # Agent tab with context containing an agent_chat window
    agent_tab = Tab.new_agent(2, "Agent")

    agent_win = Window.new_agent_chat(1, agent_buf, 24, 80)

    agent_context = %{
      keymap_scope: :agent,
      windows: %{
        tree: {:leaf, 1},
        map: %{1 => agent_win},
        active: 1,
        next_id: 2
      }
    }

    agent_tab = %{agent_tab | context: agent_context}

    tb = %TabBar{
      tabs: [file_tab, agent_tab],
      active_id: 1,
      next_id: 3
    }

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
        keymap_scope: :editor,
        agent_ui: UIState.new(),
        file_tree: %FileTreeState{}
      },
      agent: agent,
      tab_bar: tb
    }
  end

  describe "toggle_agent_split/1" do
    test "switches to agent tab when on file tab" do
      state = make_state()
      assert EditorState.active_tab_kind(state) == :file

      new_state = AgentCommands.toggle_agent_split(state)

      assert EditorState.active_tab_kind(new_state) == :agent
      assert new_state.tab_bar.active_id == 2
    end

    test "switches back to file tab when on agent tab" do
      state = make_state()

      # Toggle on (switch to agent)
      state = AgentCommands.toggle_agent_split(state)
      assert EditorState.active_tab_kind(state) == :agent

      # Toggle off (switch to file)
      state = AgentCommands.toggle_agent_split(state)
      assert EditorState.active_tab_kind(state) == :file
      assert state.tab_bar.active_id == 1
    end

    test "agent tab has agent_chat window in context" do
      state = make_state()
      state = AgentCommands.toggle_agent_split(state)

      # After switching to agent tab, the windows should include an agent_chat window
      agent_win = Map.values(state.workspace.windows.map) |> Enum.find(&Content.agent_chat?(&1.content))
      assert agent_win != nil
    end

    test "round-trip toggle restores file state" do
      state = make_state()
      original_buf = state.workspace.buffers.active
      original_active = state.tab_bar.active_id

      state = AgentCommands.toggle_agent_split(state)
      state = AgentCommands.toggle_agent_split(state)

      assert state.tab_bar.active_id == original_active
      assert state.workspace.buffers.active == original_buf
    end
  end
end
