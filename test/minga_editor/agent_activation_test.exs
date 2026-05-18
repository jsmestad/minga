defmodule MingaEditor.AgentActivationTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.UIState
  alias MingaEditor.AgentActivation
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp base_state do
    %EditorState{
      port_manager: self(),
      shell: MingaEditor.Shell.Traditional,
      workspace: %MingaEditor.Workspace.State{
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

    test "unfocuses the prompt" do
      {state, _pid} = activated_state()
      assert AgentAccess.input_focused?(state) == true

      result = AgentActivation.deactivate(state)

      assert AgentAccess.input_focused?(result) == false
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
