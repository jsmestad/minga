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

  ## Unclaimed keys

  The chat and the file viewer apply one rule. Keys not claimed by earlier scope handlers stop here so the read-only surface cannot edit an underlying human buffer. The mode entry keys (SPC, `:`, `/`, `n`, `N`) pass through to the mode FSM (eval opens from the leader, `SPC ;`), and every key passes through while a key sequence is pending or a command line, search, or eval prompt is open.

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

  # Normal-mode keys the chat hands to the mode FSM: leader, command line,
  # eval line, and transcript search.
  @mode_fsm_entry_keys [{?\s, 0}, {?:, 0}, {?/, 0}, {?n, 0}, {?N, 0}]

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  def handle_key(%{workspace: %{keymap_scope: :agent}} = state, cp, mods) do
    panel = state.workspace.agent_ui.panel

    # A focused draft, a pending sequence (leader, describe-key), and an open
    # command line, search, or eval prompt all own the key before navigation.
    if panel.input_focused or Minga.Editing.owns_next_key?(state) do
      {:passthrough, state}
    else
      handle_surface_key(state, UIState.View.focus(state.workspace.agent_ui.view), cp, mods)
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

  # The agent chat and file viewer own no editable buffer. A key that neither
  # scrolls the surface nor enters the mode FSM (leader, command line, eval,
  # search) stops here, so it cannot edit or refocus the human buffer behind it.
  @spec handle_surface_key(
          EditorState.t(),
          :chat | :file_viewer,
          non_neg_integer(),
          non_neg_integer()
        ) ::
          MingaEditor.Input.Handler.result()
  defp handle_surface_key(state, surface, cp, mods) do
    binding_state = Minga.Editing.binding_state(state)

    case nav_command(surface, cp, mods) do
      # Visual and insert input belong to the mode FSM.
      _command when binding_state not in [:normal, :cua] -> {:passthrough, state}
      {:scroll, fun} -> {:handled, scroll(state, surface, fun)}
      :passthrough -> unclaimed_key(state, binding_state, {cp, mods})
    end
  end

  @spec nav_command(:chat | :file_viewer, non_neg_integer(), non_neg_integer()) ::
          {:scroll, (UIState.t() -> UIState.t())} | :passthrough
  defp nav_command(:chat, cp, mods), do: chat_nav_command(cp, mods)
  defp nav_command(:file_viewer, cp, mods), do: viewer_nav_command(cp, mods)

  @spec scroll(EditorState.t(), :chat | :file_viewer, (UIState.t() -> UIState.t())) ::
          EditorState.t()
  defp scroll(state, :chat, fun), do: scroll_chat(state, fun)

  defp scroll(state, :file_viewer, fun),
    do:
      MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
        state,
        fun.(state.workspace.agent_ui)
      )

  @spec unclaimed_key(EditorState.t(), :normal | :cua, {non_neg_integer(), non_neg_integer()}) ::
          MingaEditor.Input.Handler.result()
  defp unclaimed_key(state, :normal, key) when key in @mode_fsm_entry_keys,
    do: {:passthrough, state}

  # CUA editing shortcuts (Cmd+Z and friends) stop here too: the surface does
  # not edit the file behind it. Cmd+S still saves through the macOS menu.
  defp unclaimed_key(state, _binding_state, _key), do: {:handled, state}

  @spec scroll_chat(EditorState.t(), (UIState.t() -> UIState.t())) :: EditorState.t()
  defp scroll_chat(state, fun) do
    state
    |> MingaEditor.Shell.Traditional.Workflow.install_agent_ui(fun.(state.workspace.agent_ui))
    |> unpin_agent_chat_window()
  end

  # ── File viewer navigation ─────────────────────────────────────────────

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
