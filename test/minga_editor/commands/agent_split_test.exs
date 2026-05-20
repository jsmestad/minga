defmodule MingaEditor.Commands.AgentSplitTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.State, as: EditorState
  alias MingaAgent.RuntimeState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias Minga.Test.StubServer

  defp make_state do
    {:ok, buf} = BufferProcess.start_link(content: "hello world")
    {:ok, _prompt_buf} = BufferProcess.start_link(content: "")
    agent_buf = AgentBufferSync.start_buffer()
    {:ok, fake_session} = StubServer.start_link()

    window = Window.new(1, buf, 24, 80)

    agent = %AgentState{
      buffer: agent_buf,
      runtime: %RuntimeState{status: :idle}
    }

    # File tab with context
    file_tab = Tab.new_file(1, "[no file]")

    file_context = %{
      keymap_scope: :editor,
      windows: %Windows{
        tree: {:leaf, 1},
        map: %{1 => window},
        active: 1,
        next_id: 2
      }
    }

    file_tab = Tab.set_context(file_tab, file_context)

    # Agent tab with context containing an agent_chat window. The session
    # pid lives on the tab; AgentAccess.session/1 reads it through the
    # shell's active_session callback when this tab is active.
    agent_tab = Tab.new_agent(2, "Agent") |> Tab.set_session(fake_session)

    agent_win = Window.new_agent_chat(1, agent_buf, 24, 80)

    agent_context = %{
      keymap_scope: :agent,
      windows: %Windows{
        tree: {:leaf, 1},
        map: %{1 => agent_win},
        active: 1,
        next_id: 2
      }
    }

    agent_tab = Tab.set_context(agent_tab, agent_context)

    tb = %TabBar{
      tabs: [file_tab, agent_tab],
      active_id: 1,
      next_id: 3
    }

    %EditorState{
      port_manager: self(),
      shell: MingaEditor.Shell.Traditional,
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: buf, list: [buf]},
        windows: %Windows{
          tree: {:leaf, 1},
          map: %{1 => window},
          active: 1,
          next_id: 2
        }
      },
      shell_state: %MingaEditor.Shell.Traditional.State{agent: agent, tab_bar: tb}
    }
  end

  describe "toggle_agent_split/1" do
    test "switches to agent tab when on file tab" do
      state = make_state()
      assert EditorState.active_tab_kind(state) == :file

      new_state = AgentCommands.toggle_agent_split(state)

      assert EditorState.active_tab_kind(new_state) == :agent
      assert new_state.shell_state.tab_bar.active_id == 2
    end

    test "switches back to file tab when on agent tab" do
      state = make_state()

      # Toggle on (switch to agent)
      state = AgentCommands.toggle_agent_split(state)
      assert EditorState.active_tab_kind(state) == :agent

      # Toggle off (switch to file)
      state = AgentCommands.toggle_agent_split(state)
      assert EditorState.active_tab_kind(state) == :file
      assert state.shell_state.tab_bar.active_id == 1
    end

    test "agent tab has agent_chat window in context" do
      state = make_state()
      state = AgentCommands.toggle_agent_split(state)

      # After switching to agent tab, the windows should include an agent_chat window
      agent_win =
        Map.values(state.workspace.windows.map) |> Enum.find(&Content.agent_chat?(&1.content))

      assert agent_win != nil
    end

    test "round-trip toggle restores file state" do
      state = make_state()
      original_buf = state.workspace.buffers.active
      original_active = state.shell_state.tab_bar.active_id

      state = AgentCommands.toggle_agent_split(state)
      state = AgentCommands.toggle_agent_split(state)

      assert state.shell_state.tab_bar.active_id == original_active
      assert state.workspace.buffers.active == original_buf
    end
  end
end
