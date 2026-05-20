defmodule MingaEditor.Commands.AgentCommandsTest do
  @moduledoc """
  Characterization tests for Commands.Agent.

  Tests pure `state -> state` functions for agent-related commands.
  Agent state now lives on EditorState (agent panel, session, status).

  Functions that require a live Agent.Session (submit_prompt, abort_agent,
  clear_chat_display, etc.) are tested via EditorCase integration tests
  in a separate file.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.Agent.UIState
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace, as: WorkspaceModel
  alias MingaEditor.State.Windows
  alias MingaEditor.Workspace.State, as: WorkspaceState
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias MingaEditor.Input
  alias Minga.Test.StubServer

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp base_state(opts \\ []) do
    {:ok, buf} = BufferProcess.start_link(content: Keyword.get(opts, :content, "hello\nworld"))

    {:ok, prompt_buf} = BufferProcess.start_link(content: "")

    default_session =
      if Keyword.has_key?(opts, :session) do
        Keyword.get(opts, :session)
      else
        {:ok, pid} = StubServer.start_link()
        pid
      end

    agent = %AgentState{
      buffer: Keyword.get(opts, :agent_buffer, nil)
    }

    agentic = %UIState{
      panel: %UIState.Panel{
        visible: Keyword.get(opts, :panel_visible, true),
        input_focused: Keyword.get(opts, :input_focused, false),
        prompt_buffer: prompt_buf
      }
    }

    # Active tab is an agent tab carrying the session pid; AgentAccess.session/1
    # reads it through the Traditional shell's active_session/1.
    agent_tab = Tab.new_agent(1, "Agent") |> Tab.set_session(default_session)
    tb = TabBar.new(agent_tab)

    %EditorState{
      port_manager: nil,
      shell: MingaEditor.Shell.Traditional,
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf], active_index: 0},
        windows: %Windows{
          tree: {:leaf, 1},
          map: %{1 => Window.new(1, buf, 24, 80)},
          active: 1,
          next_id: 2
        },
        agent_ui: agentic
      },
      shell_state: %MingaEditor.Shell.Traditional.State{agent: agent, tab_bar: tb},
      focus_stack: Input.default_stack()
    }
  end

  defp source_workspace_state do
    state = base_state(session: nil)
    source_ref = FileRef.from_buffer(state.workspace.buffers.active)

    file_tab =
      Tab.new_file(1, FileRef.display_label(source_ref))
      |> Tab.set_file_ref(source_ref)
      |> Tab.set_context(WorkspaceState.to_tab_context(state.workspace))

    tab_bar =
      file_tab
      |> TabBar.new()
      |> TabBar.update_workspace(0, fn workspace ->
        workspace
        |> WorkspaceModel.add_file(source_ref)
        |> WorkspaceModel.set_active_file(source_ref)
      end)

    %{state | shell_state: %{state.shell_state | tab_bar: tab_bar}}
  end

  defp source_workspace_with_background_agent_tab do
    state = source_workspace_state()
    {tab_bar, _agent_tab} = TabBar.insert(state.shell_state.tab_bar, :agent, "Agent")
    %{state | shell_state: %{state.shell_state | tab_bar: tab_bar}}
  end

  defp active_agent_workspace_state do
    {:ok, agent_buf} = BufferProcess.start_link(content: "old chat")
    state = base_state(agent_buffer: agent_buf)
    windows = agent_windows(agent_buf)

    EditorState.update_workspace(state, fn workspace ->
      workspace
      |> WorkspaceState.set_buffers(%Buffers{
        active: agent_buf,
        list: [agent_buf],
        active_index: 0
      })
      |> WorkspaceState.set_windows(windows)
      |> WorkspaceState.set_agent_ui(UIState.new())
    end)
  end

  defp agent_windows(agent_buf) when is_pid(agent_buf) do
    win_id = 1

    %Windows{
      tree: WindowTree.new(win_id),
      map: %{win_id => Window.new_agent_chat(win_id, agent_buf, 24, 80)},
      active: win_id,
      next_id: win_id + 1
    }
  end

  # ── submit_prompt ────────────────────────────────────────────────────────

  describe "submit_prompt/1" do
    test "no-ops on empty input" do
      state = base_state()
      assert AgentCommands.submit_prompt(state) == state
    end

    test "sets error status when no session exists" do
      state = base_state(session: nil)

      state =
        AgentAccess.update_agent_ui(state, fn ui ->
          ui = UIState.ensure_prompt_buffer(ui)
          BufferProcess.replace_content(ui.panel.prompt_buffer, "hello agent")
          ui
        end)

      new_state = AgentCommands.submit_prompt(state)

      assert new_state.shell_state.status_msg =~ "No agent session"
    end
  end

  # ── scroll_chat ──────────────────────────────────────────────────────────

  describe "scroll_chat_up/1 and scroll_chat_down/1" do
    test "scrolls when panel is visible" do
      state = base_state(panel_visible: true)
      new_state = AgentCommands.scroll_chat_up(state)

      # Scroll offset should change (exact value depends on panel height)
      assert AgentAccess.panel(new_state).scroll != AgentAccess.panel(state).scroll
    end
  end

  # ── input_char / input_backspace / input_paste ───────────────────────────

  describe "input_char/2" do
    test "inserts character when panel is visible" do
      state = base_state(panel_visible: true, input_focused: true)
      new_state = AgentCommands.input_char(state, "a")

      assert UIState.input_text(AgentAccess.panel(new_state)) == "a"
    end

    test "inserts multiple characters sequentially" do
      state = base_state(panel_visible: true, input_focused: true)

      state =
        state
        |> AgentCommands.input_char("h")
        |> AgentCommands.input_char("i")

      assert UIState.input_text(AgentAccess.panel(state)) == "hi"
    end
  end

  describe "input_backspace/1" do
    test "deletes last character when panel is visible" do
      state = base_state(panel_visible: true, input_focused: true)

      state =
        state
        |> AgentCommands.input_char("a")
        |> AgentCommands.input_char("b")
        |> AgentCommands.input_backspace()

      assert UIState.input_text(AgentAccess.panel(state)) == "a"
    end
  end

  describe "input_paste/2" do
    test "inserts pasted text when panel is visible" do
      state = base_state(panel_visible: true, input_focused: true)
      new_state = AgentCommands.input_paste(state, "pasted")

      text = UIState.input_text(AgentAccess.panel(new_state))
      assert text =~ "pasted"
    end
  end

  # ── abort_agent ──────────────────────────────────────────────────────────

  describe "abort_agent/1" do
    test "no-ops when no session exists" do
      state = base_state(session: nil)
      assert AgentCommands.abort_agent(state) == state
    end
  end

  # ── ensure_agent_session ─────────────────────────────────────────────────

  describe "ensure_agent_session/1" do
    test "no-ops when session already exists" do
      fake_pid = spawn(fn -> :timer.sleep(:infinity) end)
      state = base_state(session: fake_pid)
      assert AgentCommands.ensure_agent_session(state) == state
    end
  end

  # ── cycle_thinking_level ─────────────────────────────────────────────────

  describe "cycle_thinking_level/1" do
    test "sets status message when no session exists" do
      state = base_state(session: nil)
      new_state = AgentCommands.cycle_thinking_level(state)

      assert new_state.shell_state.status_msg =~ "No agent session"
    end
  end

  describe "cycle_model/1" do
    test "updates model and thinking level from the session response" do
      {:ok, session} =
        StubServer.start_link(
          cycle_model:
            {:ok,
             %{
               "model" => "openai:o4-mini",
               "index" => 2,
               "total" => 3,
               "thinking_level" => "high"
             }}
        )

      state = base_state(session: session)
      state = AgentAccess.update_agent_ui(state, &UIState.set_thinking_level(&1, "medium"))

      new_state = AgentCommands.cycle_model(state)

      assert AgentAccess.panel(new_state).model_name == "openai:o4-mini"
      assert AgentAccess.panel(new_state).thinking_level == "high"
      assert new_state.shell_state.status_msg == "Model: openai:o4-mini [2/3]"
    end
  end

  # ── scope_* guard functions ──────────────────────────────────────────────
  # These functions guard on agentic/panel state. Test the guard behavior.

  describe "scope_focus_input/1" do
    test "focuses the panel input" do
      state = base_state(panel_visible: true, input_focused: false)
      new_state = AgentCommands.scope_focus_input(state)

      assert AgentAccess.input_focused?(new_state) == true
    end
  end

  describe "scope_switch_focus/1" do
    test "switches from chat to file_viewer" do
      state = base_state(panel_visible: true)

      state =
        AgentAccess.update_view(state, fn v ->
          %{v | active: true, focus: :chat}
        end)

      new_state = AgentCommands.scope_switch_focus(state)

      assert AgentAccess.view(new_state).focus == :file_viewer
    end

    test "switches from non-chat back to chat" do
      state = base_state(panel_visible: true)

      state =
        AgentAccess.update_view(state, fn v ->
          %{v | active: true, focus: :file_viewer}
        end)

      new_state = AgentCommands.scope_switch_focus(state)

      assert AgentAccess.view(new_state).focus == :chat
    end
  end

  # ── toggle_paste_expand ──────────────────────────────────────────────────

  describe "toggle_paste_expand/1" do
    test "does not crash on empty input" do
      state = base_state(panel_visible: true, input_focused: true)
      new_state = AgentCommands.toggle_paste_expand(state)

      # Should not crash, input stays the same
      assert UIState.input_text(AgentAccess.panel(new_state)) == ""
    end
  end

  # ── new_agent_session ────────────────────────────────────────────────────

  describe "new_agent_session/1" do
    test "resets agent state for a fresh session" do
      state = base_state()
      # Set some agent state
      state = AgentAccess.update_agent(state, fn a -> %{a | error: "old error"} end)

      new_state = AgentCommands.new_agent_session(state)

      # Error should be cleared
      assert AgentAccess.agent(new_state).error == nil
    end

    test "creates a fresh agent buffer for the new workspace" do
      {:ok, agent_buf} = BufferProcess.start_link(content: "old chat")
      state = base_state(agent_buffer: agent_buf)

      new_state = AgentCommands.new_agent_session(state)

      assert is_pid(AgentAccess.agent(new_state).buffer)
      assert AgentAccess.agent(new_state).buffer != agent_buf
    end

    test "creates an active agent workspace with no file context" do
      state = source_workspace_state()
      source_workspace = TabBar.get_workspace(state.shell_state.tab_bar, 0)

      new_state = AgentCommands.new_agent_session(state)
      tab_bar = new_state.shell_state.tab_bar
      active_workspace = TabBar.active_workspace(tab_bar)

      assert active_workspace.kind == :agent
      assert active_workspace.files == []
      assert active_workspace.active_file == nil
      assert is_pid(active_workspace.session)
      assert EditorState.active_tab_kind(new_state) == :agent
      assert new_state.workspace.buffers.active == AgentAccess.agent(new_state).buffer
      assert TabBar.get_workspace(tab_bar, 0) == source_workspace
      assert TabBar.active(tab_bar).session == active_workspace.session
    end

    test "creating from an existing agent workspace preserves the source tab context" do
      state = active_agent_workspace_state()
      old_tab = TabBar.active(state.shell_state.tab_bar)
      old_buffer = AgentAccess.agent(state).buffer
      old_session = old_tab.session

      new_state = AgentCommands.new_agent_session(state)
      tab_bar = new_state.shell_state.tab_bar
      updated_old_tab = TabBar.get(tab_bar, old_tab.id)
      old_context = TabContext.to_workspace_map(updated_old_tab.context)
      new_session = TabBar.active(tab_bar).session

      assert old_context.buffers.active == old_buffer
      assert old_session != nil
      assert new_session != old_session
      assert AgentAccess.agent(new_state).buffer != old_buffer
      assert new_state.workspace.buffers.active == AgentAccess.agent(new_state).buffer
    end

    test "background agent session creation does not switch active workspace" do
      state = source_workspace_with_background_agent_tab()
      source_active_id = state.shell_state.tab_bar.active_id
      source_workspace = TabBar.get_workspace(state.shell_state.tab_bar, 0)

      new_state = AgentSession.start_agent_session(state)
      tab_bar = new_state.shell_state.tab_bar
      agent_workspaces = Enum.filter(tab_bar.workspaces, &(&1.kind == :agent))

      assert tab_bar.active_id == source_active_id
      assert TabBar.active_workspace_id(tab_bar) == 0
      assert TabBar.get_workspace(tab_bar, 0) == source_workspace
      assert [%{files: [], active_file: nil, session: session}] = agent_workspaces
      assert is_pid(session)
    end
  end

  # ── cycle_agent_tabs ─────────────────────────────────────────────────────

  describe "cycle_agent_tabs/1" do
    test "creates an agent tab when none exist" do
      state = base_state()
      new_state = AgentCommands.cycle_agent_tabs(state)

      agent_tabs = TabBar.filter_by_kind(new_state.shell_state.tab_bar, :agent)
      assert agent_tabs != []
    end
  end
end
