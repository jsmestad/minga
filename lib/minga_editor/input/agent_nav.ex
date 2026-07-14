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

  When `agent_ui.focus == :file_viewer`, keys route to file viewer
  scroll commands (j/k/Ctrl-d/Ctrl-u/G) which scroll the preview pane.

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
        :chat -> handle_chat_nav(state, cp, mods)
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
      {:scroll, fun} ->
        state =
          state
          |> then(fn state ->
            MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
              state,
              fun.(state.workspace.agent_ui)
            )
          end)
          |> unpin_agent_chat_window()

        {:handled, state}

      :passthrough ->
        {:passthrough, state}
    end
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
        {:passthrough, state}
    end
  end

  @ctrl MingaEditor.Input.mod_ctrl()

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
    case EditorState.find_agent_chat_window(state) do
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
