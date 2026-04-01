defmodule MingaEditor.AgentActivation do
  @moduledoc """
  Atomically activates the agent view for a Board card.

  Consolidates the five pieces of state that must change when zooming
  into an agent card: session attachment, keymap scope, window content,
  prompt focus, and prompt buffer creation. Both the GUI click path
  and the keyboard Enter path call this single function instead of
  scattering the logic across board.ex, input.ex, and editor.ex.

  This is a Layer 2 module (orchestration) because it mutates
  EditorState fields across workspace, agent, and windows.
  """

  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.Window.Content
  alias MingaEditor.Shell.Board.Card

  @doc """
  Activates the agent view for a Board card on full EditorState.

  Sets up everything needed for the agent chat to render and accept
  input. Idempotent: safe to call even if some pieces are already set.

  Does nothing for "You" cards (they use the editor view, not agent).
  Does nothing if the card has no session (agent not started yet).
  """
  @spec activate_for_card(EditorState.t(), Card.t() | nil) :: EditorState.t()
  def activate_for_card(state, nil), do: state

  def activate_for_card(state, %Card{} = card) do
    if Card.you_card?(card) or card.session == nil do
      state
    else
      state
      |> attach_session(card.session)
      |> set_agent_scope()
      |> set_agent_chat_window_content(card.session)
      |> focus_prompt()
    end
  end

  @doc """
  Deactivates the agent view, reversing the activation steps.

  Clears the session singleton, resets keymap scope to `:editor`,
  and unfocuses the prompt. Does NOT modify `workspace.windows` —
  that is handled by the workspace restore in zoom_out.

  Symmetric counterpart to `activate_for_card/2`.
  """
  @spec deactivate(EditorState.t()) :: EditorState.t()
  def deactivate(state) do
    state
    |> clear_session()
    |> reset_scope()
    |> unfocus_prompt()
  end

  # ── Private steps ───────────────────────────────────────────────────────

  @spec attach_session(EditorState.t(), pid()) :: EditorState.t()
  defp attach_session(state, session) do
    AgentAccess.update_agent(state, fn a ->
      AgentState.set_session(a, session)
    end)
  end

  @spec set_agent_scope(EditorState.t()) :: EditorState.t()
  defp set_agent_scope(state) do
    put_in(state.workspace.keymap_scope, :agent)
  end

  @spec set_agent_chat_window_content(EditorState.t(), pid()) :: EditorState.t()
  defp set_agent_chat_window_content(state, session) do
    active_id = state.workspace.windows.active
    active_win = Map.get(state.workspace.windows.map, active_id)

    if active_win do
      updated_win = %{active_win | content: Content.agent_chat(session)}
      new_map = Map.put(state.workspace.windows.map, active_id, updated_win)
      put_in(state.workspace.windows.map, new_map)
    else
      state
    end
  end

  @spec focus_prompt(EditorState.t()) :: EditorState.t()
  defp focus_prompt(state) do
    AgentAccess.update_agent_ui(state, fn ui ->
      UIState.set_input_focused(ui, true)
    end)
  end

  # ── Deactivation steps ─────────────────────────────────────────────────

  @spec clear_session(EditorState.t()) :: EditorState.t()
  defp clear_session(state) do
    AgentAccess.update_agent(state, fn a ->
      AgentState.clear_session(a)
    end)
  end

  @spec reset_scope(EditorState.t()) :: EditorState.t()
  defp reset_scope(state) do
    put_in(state.workspace.keymap_scope, :editor)
  end

  @spec unfocus_prompt(EditorState.t()) :: EditorState.t()
  defp unfocus_prompt(state) do
    AgentAccess.update_agent_ui(state, fn ui ->
      UIState.set_input_focused(ui, false)
    end)
  end
end
