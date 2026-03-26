defmodule Minga.Editor.Commands.AgentSplitToggleTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.BufferSync
  alias Minga.Agent.UIState
  alias Minga.Agent.View.Preview
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Input
  alias Minga.Test.StubServer

  defp fake_session do
    {:ok, pid} = StubServer.start_link()
    pid
  end

  defp base_state(opts \\ []) do
    {:ok, buf} = BufferServer.start_link(content: "hello\nworld")
    {:ok, prompt_buf} = BufferServer.start_link(content: "")
    agent_buf = BufferSync.start_buffer()

    agent = %AgentState{
      session: Keyword.get(opts, :session, fake_session()),
      status: :idle,
      error: nil,
      spinner_timer: nil,
      buffer: agent_buf
    }

    active = Keyword.get(opts, :active, false)

    agentic = %UIState{
      panel: %UIState.Panel{
        visible: false,
        input_focused: false,
        prompt_buffer: prompt_buf
      },
      view: %UIState.View{
        active: active,
        focus: :chat,
        preview: Preview.new(),
        saved_windows: Keyword.get(opts, :saved_windows, nil),
        saved_file_tree: Keyword.get(opts, :saved_file_tree, nil)
      }
    }

    file_tab = Tab.new_file(1, "test.ex")
    tb = TabBar.new(file_tab)
    window = Window.new(1, buf, 24, 80)

    state = %EditorState{
      port_manager: self(),
      workspace: %Minga.Workspace.State{
        viewport: Viewport.new(24, 80),
        vim: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf], active_index: 0},
        agent_ui: agentic,
        windows: %Minga.Editor.State.Windows{
          tree: {:leaf, 1},
          map: %{1 => window},
          active: 1,
          next_id: 2
        }
      },
      focus_stack: Input.default_stack(),
      shell_state: %Minga.Shell.Traditional.State{agent: agent, tab_bar: tb}
    }

    if active do
      agent_win = Window.new_agent_chat(1, agent_buf, 24, 80)

      agent_ctx = %{
        keymap_scope: :agent,
        windows: %Minga.Editor.State.Windows{
          tree: {:leaf, 1},
          map: %{1 => agent_win},
          active: 1,
          next_id: 2
        }
      }

      {tb, at} = TabBar.add(tb, :agent, "Agent")
      tb = TabBar.update_context(tb, at.id, agent_ctx)
      tb = TabBar.switch_to(tb, file_tab.id)

      state =
        put_in(state.workspace.agent_ui, %{
          agentic
          | view: %{agentic.view | active: true, focus: :chat}
        })

      state = Minga.Editor.State.set_tab_bar(state, tb)

      EditorState.switch_tab(state, at.id)
    else
      # Create background agent tab with agent context
      agent_win = Window.new_agent_chat(1, agent_buf, 24, 80)

      agent_ctx = %{
        keymap_scope: :agent,
        windows: %Minga.Editor.State.Windows{
          tree: {:leaf, 1},
          map: %{1 => agent_win},
          active: 1,
          next_id: 2
        }
      }

      {tb, at} = TabBar.add(tb, :agent, "Agent")
      tb = TabBar.update_context(tb, at.id, agent_ctx)
      tb = TabBar.switch_to(tb, file_tab.id)
      Minga.Editor.State.set_tab_bar(state, tb)
    end
  end

  describe "toggle_agent_split/1 — activating (tab switch)" do
    test "switches to agent tab" do
      state = base_state()
      assert EditorState.active_tab_kind(state) == :file

      new_state = AgentCommands.toggle_agentic_view(state)

      assert EditorState.active_tab_kind(new_state) == :agent
    end

    test "keymap_scope becomes :agent" do
      state = base_state()
      new_state = AgentCommands.toggle_agentic_view(state)

      assert new_state.workspace.keymap_scope == :agent
    end

    test "agent tab has agent_chat window in context" do
      state = base_state()
      new_state = AgentCommands.toggle_agentic_view(state)

      agent_chat_exists =
        Enum.any?(new_state.workspace.windows.map, fn {_id, window} ->
          Content.agent_chat?(window.content)
        end)

      assert agent_chat_exists
    end

    test "does not double-start a session when one is already running" do
      fake_session = spawn(fn -> :timer.sleep(1000) end)
      state = base_state(session: fake_session)
      new_state = AgentCommands.toggle_agentic_view(state)

      assert AgentAccess.session(new_state) == fake_session
    end

    test "agent tab exists after toggle" do
      state = base_state()
      agent_tab_before = TabBar.find_by_kind(Minga.Editor.State.tab_bar(state), :agent)
      assert agent_tab_before != nil

      new_state = AgentCommands.toggle_agentic_view(state)

      agent_tab_after = TabBar.find_by_kind(new_state.shell_state.tab_bar, :agent)
      assert agent_tab_after != nil
      assert agent_tab_after.id == agent_tab_before.id
    end
  end

  describe "toggle_agent_split/1 — deactivating (back to file)" do
    test "switches back to file tab" do
      state = base_state()
      with_agent = AgentCommands.toggle_agentic_view(state)
      assert EditorState.active_tab_kind(with_agent) == :agent

      without_agent = AgentCommands.toggle_agentic_view(with_agent)
      assert EditorState.active_tab_kind(without_agent) == :file
    end

    test "restores :editor keymap_scope" do
      state = base_state()
      with_agent = AgentCommands.toggle_agentic_view(state)
      without_agent = AgentCommands.toggle_agentic_view(with_agent)

      assert without_agent.workspace.keymap_scope == :editor
    end
  end

  describe "kill_buffer on agent tab" do
    alias Minga.Editor.Commands.BufferManagement

    test "closes agent tab and switches to file tab" do
      state = base_state(active: true)
      assert EditorState.active_tab_kind(state) == :agent

      new_state = BufferManagement.execute(state, :kill_buffer)

      assert EditorState.active_tab_kind(new_state) == :file
      assert new_state.workspace.keymap_scope == :editor
    end

    test "does not crash when agent tab has no session" do
      state = base_state(active: true, session: nil)
      new_state = BufferManagement.execute(state, :kill_buffer)
      assert EditorState.active_tab_kind(new_state) == :file
    end

    test "removes agent tab from tab bar" do
      state = base_state(active: true)
      assert length(TabBar.filter_by_kind(Minga.Editor.State.tab_bar(state), :agent)) == 1

      new_state = BufferManagement.execute(state, :kill_buffer)
      assert TabBar.filter_by_kind(new_state.shell_state.tab_bar, :agent) == []
    end
  end

  describe "round-trip toggle" do
    test "toggle cycle returns to file tab" do
      state = base_state()
      assert EditorState.active_tab_kind(state) == :file

      with_agent = AgentCommands.toggle_agentic_view(state)
      assert EditorState.active_tab_kind(with_agent) == :agent

      restored = AgentCommands.toggle_agentic_view(with_agent)
      assert EditorState.active_tab_kind(restored) == :file
      assert restored.workspace.keymap_scope == :editor
    end

    test "agent tab persists through toggle cycles" do
      state = base_state()
      agent_tab_id = TabBar.find_by_kind(Minga.Editor.State.tab_bar(state), :agent).id

      first = AgentCommands.toggle_agentic_view(state)
      assert TabBar.get(first.shell_state.tab_bar, agent_tab_id) != nil

      second = AgentCommands.toggle_agentic_view(first)
      assert TabBar.get(second.shell_state.tab_bar, agent_tab_id) != nil

      third = AgentCommands.toggle_agentic_view(second)
      assert TabBar.get(third.shell_state.tab_bar, agent_tab_id) != nil
    end
  end
end
