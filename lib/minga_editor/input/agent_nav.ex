defmodule MingaEditor.Input.AgentNav do
  @moduledoc """
  Thin input handler for agent chat navigation.

  When the agent chat window is focused and the prompt input is not
  focused, this handler maps common Vim navigation keys onto the
  semantic transcript scroll state.

  Domain-specific bindings (collapse, copy, focus input, session, etc.)
  are handled by the agent scope trie in `Scoped`, which runs earlier
  in the handler chain.

  ## File viewer navigation

  When `agent_ui.focus == :file_viewer`, navigation keys scroll the preview pane.
  Keys not claimed by earlier scope handlers stop here so the read-only viewer cannot edit an underlying human buffer.

  ## Side panel usage

  `AgentPanel` calls `handle_chat_nav/3` for side panel chat navigation,
  so both full agent workspaces and editor side panels share one
  semantic navigation path.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  import Bitwise

  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState

  @ctrl MingaEditor.Input.mod_ctrl()
  @alt MingaEditor.Input.mod_alt()

  # Normal-mode keys the chat hands to the mode FSM: leader, command line,
  # eval line, and transcript search.
  @mode_fsm_entry_keys [{?\s, 0}, {?:, 0}, {?:, @alt}, {?/, 0}, {?n, 0}, {?N, 0}]

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{workspace: %{keymap_scope: :agent}} = state, cp, mods) do
    panel = state.workspace.agent_ui.panel

    if panel.input_focused do
      {:passthrough, state}
    else
      view = state.workspace.agent_ui.view

      case UIState.View.focus(view) do
        :chat -> handle_agent_chat_key(state, cp, mods)
        :file_viewer -> handle_viewer_nav(state, cp, mods)
      end
    end
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  # ── Chat navigation ─────────────────────────────────────────────────────

  @spec handle_chat_nav(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_chat_nav(state, cp, mods) do
    case chat_nav_command(cp, mods) do
      {:scroll, fun} -> {:handled, scroll_chat(state, fun)}
      :passthrough -> {:passthrough, state}
    end
  end

  # The agent chat owns no editable buffer. A key that neither scrolls the
  # transcript nor belongs to the mode FSM (command line, search, leader)
  # stops here, so it cannot edit or refocus the human buffer behind the chat.
  @spec handle_agent_chat_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp handle_agent_chat_key(state, cp, mods) do
    binding_state = Minga.Editing.binding_state(state)

    case chat_nav_command(cp, mods) do
      # Command line, search, and eval input belong to the mode FSM.
      _command when binding_state not in [:normal, :cua] -> {:passthrough, state}
      {:scroll, fun} -> {:handled, scroll_chat(state, fun)}
      :passthrough -> unclaimed_chat_key(state, binding_state, {cp, mods})
    end
  end

  @spec unclaimed_chat_key(
          EditorState.t(),
          :normal | :cua,
          {non_neg_integer(), non_neg_integer()}
        ) ::
          MingaEditor.Input.Handler.result()
  defp unclaimed_chat_key(state, :normal, key) do
    if key in @mode_fsm_entry_keys or Minga.Editing.key_sequence_pending?(state) do
      {:passthrough, state}
    else
      {:handled, state}
    end
  end

  defp unclaimed_chat_key(state, :cua, _key), do: {:handled, state}

  @spec scroll_chat(EditorState.t(), (UIState.t() -> UIState.t())) :: EditorState.t()
  defp scroll_chat(state, fun) do
    state
    |> MingaEditor.Shell.Traditional.Workflow.install_agent_ui(fun.(state.workspace.agent_ui))
    |> unpin_agent_chat_window()
  end

  # ── File viewer navigation ─────────────────────────────────────────────

  @spec handle_viewer_nav(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp handle_viewer_nav(state, cp, mods) do
    case viewer_nav_command(cp, mods) do
      {:scroll, fun} ->
        {:handled,
         MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
           state,
           fun.(state.workspace.agent_ui)
         )}

      :passthrough ->
        {:handled, state}
    end
  end

  @spec viewer_nav_command(non_neg_integer(), non_neg_integer()) ::
          {:scroll, (UIState.t() -> UIState.t())} | :passthrough
  defp viewer_nav_command(?j, 0), do: {:scroll, &UIState.scroll_viewer_down(&1, 1)}
  defp viewer_nav_command(?k, 0), do: {:scroll, &UIState.scroll_viewer_up(&1, 1)}

  defp viewer_nav_command(?d, mods) when band(mods, @ctrl) != 0,
    do: {:scroll, &UIState.scroll_viewer_down(&1, 10)}

  defp viewer_nav_command(?u, mods) when band(mods, @ctrl) != 0,
    do: {:scroll, &UIState.scroll_viewer_up(&1, 10)}

  defp viewer_nav_command(?G, 0), do: {:scroll, &UIState.scroll_viewer_to_bottom/1}
  defp viewer_nav_command(_cp, _mods), do: :passthrough

  @spec chat_nav_command(non_neg_integer(), non_neg_integer()) ::
          {:scroll, (UIState.t() -> UIState.t())} | :passthrough
  defp chat_nav_command(?j, 0), do: {:scroll, &UIState.scroll_down(&1, 1)}
  defp chat_nav_command(?k, 0), do: {:scroll, &UIState.scroll_up(&1, 1)}

  defp chat_nav_command(?d, mods) when band(mods, @ctrl) != 0,
    do: {:scroll, &UIState.scroll_down(&1, 10)}

  defp chat_nav_command(?u, mods) when band(mods, @ctrl) != 0,
    do: {:scroll, &UIState.scroll_up(&1, 10)}

  defp chat_nav_command(?G, 0), do: {:scroll, &UIState.scroll_to_bottom/1}
  defp chat_nav_command(_cp, _mods), do: :passthrough

  @spec unpin_agent_chat_window(EditorState.t()) :: EditorState.t()
  defp unpin_agent_chat_window(state) do
    case MingaEditor.Session.State.find_agent_chat_window(state.workspace) do
      nil ->
        state

      {win_id, _window} ->
        %{
          state
          | workspace:
              MingaEditor.Session.State.set_windows(
                state.workspace,
                MingaEditor.State.Windows.set_pinned(state.workspace.windows, win_id, false)
              )
        }
    end
  end
end
