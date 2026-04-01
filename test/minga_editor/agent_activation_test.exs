defmodule MingaEditor.AgentActivationTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Agent.UIState
  alias MingaEditor.AgentActivation
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp base_state do
    %EditorState{
      port_manager: self(),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        keymap_scope: :editor,
        agent_ui: UIState.new()
      },
      shell_state: %MingaEditor.Shell.Traditional.State{agent: %AgentState{}}
    }
  end

  defp activated_state do
    # Simulate an activated agent: session set, scope is :agent, prompt focused
    fake_pid = spawn(fn -> Process.sleep(:infinity) end)

    state = base_state()

    state =
      AgentAccess.update_agent(state, fn a ->
        AgentState.set_session(a, fake_pid)
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
    test "clears the agent session" do
      {state, _pid} = activated_state()
      assert AgentAccess.session(state) != nil

      result = AgentActivation.deactivate(state)

      assert AgentAccess.session(result) == nil
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
