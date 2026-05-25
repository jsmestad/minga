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

  alias MingaAgent.Session, as: AgentSession
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
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
      return_target = build_return_target(state)

      state
      |> refresh_agent_cache(card.session)
      |> activate_agent_view(return_target)
      |> set_agent_scope()
      |> set_agent_chat_window_content(card.session)
      |> focus_prompt()
    end
  end

  @doc """
  Deactivates the agent view, reversing the activation steps.

  Resets the rendering cache (status/error/pending_approval) to idle and restores the recorded editor return target when one exists. The return target includes window layout, file tree state, keymap scope, active buffer, and prompt focus. Without a return target, deactivation falls back to editor scope with the prompt unfocused. It does NOT clear the card's `:session` field; the session keeps running in the background and the card retains its pid.

  Symmetric counterpart to `activate_for_card/2`.
  """
  @spec deactivate(EditorState.t()) :: EditorState.t()
  def deactivate(state) do
    return_target = AgentAccess.view(state).return_target

    state
    |> reset_cache()
    |> deactivate_agent_view()
    |> restore_return_target(return_target)
    |> restore_deactivated_scope(return_target)
    |> restore_deactivated_prompt_focus(return_target)
  end

  # ── Private steps ───────────────────────────────────────────────────────

  @spec build_return_target(EditorState.t()) :: UIState.View.return_target()
  defp build_return_target(state) do
    UIState.return_target(
      active_tab_id(state),
      state.workspace.buffers.active,
      state.workspace.windows,
      EditorState.file_tree_state(state),
      state.workspace.keymap_scope,
      AgentAccess.input_focused?(state)
    )
  end

  @spec active_tab_id(EditorState.t()) :: pos_integer() | nil
  defp active_tab_id(state) do
    case EditorState.active_tab(state) do
      %Tab{id: id} -> id
      nil -> nil
    end
  end

  @spec activate_agent_view(EditorState.t(), UIState.View.return_target()) :: EditorState.t()
  defp activate_agent_view(state, return_target) do
    AgentAccess.update_agent_ui(
      state,
      &UIState.activate(&1, return_target.windows, return_target.file_tree, return_target)
    )
  end

  # Populates the rendering cache (status, error, pending_approval) from
  # the session process. The session pid itself lives on the card, not
  # on the agent struct.
  @spec refresh_agent_cache(EditorState.t(), pid()) :: EditorState.t()
  defp refresh_agent_cache(state, session) do
    case agent_snapshot(session) do
      nil ->
        AgentAccess.update_agent(state, &AgentState.clear_active_tool_name/1)

      snapshot ->
        AgentAccess.update_agent(state, fn agent ->
          AgentState.apply_session_snapshot(
            agent,
            snapshot.status,
            snapshot.pending_approval,
            snapshot.error,
            Map.get(snapshot, :active_tool_name)
          )
        end)
    end
  end

  @spec agent_snapshot(pid()) :: map() | nil
  defp agent_snapshot(session_pid) do
    AgentSession.editor_snapshot(session_pid)
  catch
    :exit, _ -> nil
  end

  @spec set_agent_scope(EditorState.t()) :: EditorState.t()
  defp set_agent_scope(state) do
    EditorState.set_keymap_scope(state, :agent)
  end

  @spec set_agent_chat_window_content(EditorState.t(), pid()) :: EditorState.t()
  defp set_agent_chat_window_content(state, session) do
    active_id = state.workspace.windows.active

    EditorState.update_windows(state, fn windows ->
      Windows.update(windows, active_id, fn active_win ->
        %{active_win | content: Content.agent_chat(session)}
      end)
    end)
  end

  @spec focus_prompt(EditorState.t()) :: EditorState.t()
  defp focus_prompt(state) do
    AgentAccess.update_agent_ui(state, fn ui ->
      UIState.set_input_focused(ui, true)
    end)
  end

  # ── Deactivation steps ─────────────────────────────────────────────────

  @spec deactivate_agent_view(EditorState.t()) :: EditorState.t()
  defp deactivate_agent_view(state) do
    AgentAccess.update_agent_ui(state, fn ui ->
      {ui, _windows, _file_tree} = UIState.deactivate(ui)
      ui
    end)
  end

  @spec restore_return_target(EditorState.t(), UIState.View.return_target() | nil) ::
          EditorState.t()
  defp restore_return_target(state, nil), do: state

  defp restore_return_target(state, return_target) do
    EditorState.set_workspace(state, restore_workspace(state.workspace, return_target))
  end

  @spec restore_workspace(SessionState.t(), UIState.View.return_target()) :: SessionState.t()
  defp restore_workspace(workspace, return_target) do
    workspace
    |> SessionState.set_keymap_scope(return_target.keymap_scope)
    |> SessionState.set_windows(return_target.windows)
    |> SessionState.set_file_tree(return_target.file_tree)
    |> restore_active_buffer(return_target.active_buffer)
  end

  @spec restore_active_buffer(SessionState.t(), pid() | nil) :: SessionState.t()
  defp restore_active_buffer(workspace, active_buffer) when is_pid(active_buffer) do
    SessionState.set_buffers(workspace, Buffers.switch_to_pid(workspace.buffers, active_buffer))
  end

  defp restore_active_buffer(workspace, _active_buffer), do: workspace

  @spec restore_deactivated_prompt_focus(EditorState.t(), UIState.View.return_target() | nil) ::
          EditorState.t()
  defp restore_deactivated_prompt_focus(state, %{prompt_focused: true}) do
    AgentAccess.update_agent_ui(state, &UIState.set_input_focused(&1, true))
  end

  defp restore_deactivated_prompt_focus(state, _return_target) do
    AgentAccess.update_agent_ui(state, &UIState.set_input_focused(&1, false))
  end

  @spec reset_cache(EditorState.t()) :: EditorState.t()
  defp reset_cache(state) do
    AgentAccess.update_agent(state, &AgentState.reset_cache/1)
  end

  @spec restore_deactivated_scope(EditorState.t(), UIState.View.return_target() | nil) ::
          EditorState.t()
  defp restore_deactivated_scope(state, %{keymap_scope: keymap_scope}) do
    EditorState.set_keymap_scope(state, keymap_scope)
  end

  defp restore_deactivated_scope(state, _return_target) do
    EditorState.set_keymap_scope(state, :editor)
  end
end
