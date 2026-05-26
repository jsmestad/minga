defmodule MingaBoard.AgentActivationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Test.StubServer

  alias MingaEditor.Agent.UIState
  alias MingaBoard.AgentActivation
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaBoard.Shell.Card
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp base_state do
    %EditorState{
      port_manager: self(),
      shell: MingaEditor.Shell.Traditional,
      workspace: %MingaEditor.Session.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: :editor,
        agent_ui: UIState.new()
      },
      shell_state: %MingaEditor.Shell.Traditional.State{
        agent: %AgentState{},
        tab_bar: TabBar.new(Tab.new_agent(1, "Agent"))
      }
    }
  end

  defp activated_state do
    # Simulate an activated agent: session attached to active tab, scope is :agent, prompt focused
    fake_pid = self()

    state = base_state()

    state =
      EditorState.set_tab_session(state, TabBar.active(state.shell_state.tab_bar).id, fake_pid)

    # Mark the cache as "thinking" so we can verify reset_cache clears it
    state =
      AgentAccess.update_agent(state, fn a ->
        a |> AgentState.set_error("stale") |> AgentState.set_status(:thinking)
      end)

    state = put_in(state.workspace.keymap_scope, :agent)

    state =
      AgentAccess.update_agent_ui(state, fn ui ->
        UIState.set_input_focused(ui, true)
      end)

    {state, fake_pid}
  end

  defp file_active_state do
    {:ok, buf} = BufferProcess.start_link(content: "hello")

    state = base_state()

    state = %{
      state
      | workspace: %{
          state.workspace
          | buffers: %Buffers{active: buf, list: [buf], active_index: 0}
        }
    }

    {tb, file_tab} = TabBar.insert(state.shell_state.tab_bar, :file, "file.ex")
    state = EditorState.set_tab_bar(state, tb)
    state = EditorState.switch_tab(state, file_tab.id)

    {state, buf, file_tab.id}
  end

  # ── deactivate/1 ─────────────────────────────────────────────────────────────

  describe "deactivate/1" do
    test "session pid is preserved on the tab (deactivate does not clear it)" do
      # The session keeps running in the background; deactivation only
      # resets the rendering cache and view chrome.
      {state, pid} = activated_state()
      assert AgentAccess.session(state) == pid

      result = AgentActivation.deactivate(state)

      assert AgentAccess.session(result) == pid
    end

    test "resets the rendering cache to :idle and clears error" do
      {state, _pid} = activated_state()
      assert AgentAccess.agent(state).runtime.status == :thinking
      assert AgentAccess.agent(state).error == "stale"

      result = AgentActivation.deactivate(state)

      assert AgentAccess.agent(result).runtime.status == :idle
      assert AgentAccess.agent(result).error == nil
    end

    test "resets keymap_scope to :editor" do
      {state, _pid} = activated_state()
      assert state.workspace.keymap_scope == :agent

      result = AgentActivation.deactivate(state)

      assert result.workspace.keymap_scope == :editor
    end

    test "unfocuses the prompt when no return target was recorded" do
      {state, _pid} = activated_state()
      assert AgentAccess.input_focused?(state) == true

      result = AgentActivation.deactivate(state)

      assert AgentAccess.input_focused?(result) == false
    end

    test "restores the recorded workspace return target" do
      {state, _pid} = activated_state()
      windows = %Windows{tree: nil, map: %{}, active: 7, next_id: 8}
      file_tree = %FileTreeState{focused: true}

      return_target =
        UIState.return_target(
          nil,
          state.workspace.buffers.active,
          windows,
          file_tree,
          :file_tree,
          true
        )

      state =
        AgentAccess.update_agent_ui(
          state,
          &UIState.activate(&1, windows, file_tree, return_target)
        )

      result = AgentActivation.deactivate(state)

      assert result.workspace.windows == windows
      assert EditorState.file_tree_state(result) == file_tree
      assert result.workspace.keymap_scope == :file_tree
      assert AgentAccess.input_focused?(result) == true
    end

    test "return_to_editor keeps the fallback tab's own keymap scope" do
      {state, _buf, file_tab_id} = file_active_state()
      {tb, fallback_tab} = TabBar.insert(state.shell_state.tab_bar, :file, "fallback.ex")
      state = EditorState.set_tab_bar(state, tb)
      state = EditorState.switch_tab(state, fallback_tab.id)
      state = put_in(state.workspace.keymap_scope, :file_tree)
      state = EditorState.switch_tab(state, file_tab_id)
      state = AgentCommands.toggle_agentic_view(state)
      {:ok, tb} = TabBar.remove(state.shell_state.tab_bar, file_tab_id)
      state = put_in(state.shell_state.tab_bar, tb)

      result = AgentCommands.return_to_editor(state)

      assert result.shell_state.tab_bar.active_id == fallback_tab.id
      assert result.workspace.keymap_scope == :file_tree
    end

    test "activate_for_card records the current editor return target" do
      {state, buf, file_tab_id} = file_active_state()
      session = start_supervised!(StubServer)
      card = Card.new(2, session: session, task: "Agent")

      result = AgentActivation.activate_for_card(state, card)

      assert AgentAccess.view(result).return_target.active_tab_id == file_tab_id
      assert AgentAccess.view(result).return_target.active_buffer == buf
      assert AgentAccess.view(result).return_target.prompt_focused == false
      assert result.workspace.keymap_scope == :agent
      assert AgentAccess.input_focused?(result) == true
    end

    test "is idempotent on already-deactivated state" do
      state = base_state()

      result = AgentActivation.deactivate(state)

      assert AgentAccess.session(result) == nil
      assert result.workspace.keymap_scope == :editor
      assert AgentAccess.input_focused?(result) == false
    end
  end
end
