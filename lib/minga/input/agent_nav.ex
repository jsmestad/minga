defmodule Minga.Input.AgentNav do
  @moduledoc """
  Thin input handler for agent chat navigation.

  When the agent chat window is focused and the prompt input is not
  focused, this handler wraps the Mode FSM call with agent-specific
  post-processing: unpinning the window so the viewport follows the
  cursor instead of snapping to the bottom.

  Domain-specific bindings (collapse, copy, focus input, session, etc.)
  are handled by the agent scope trie in `Scoped`, which runs earlier
  in the handler chain. Standard vim search (`/`, `n`, `N`) passes
  through to the Mode FSM naturally since the `*Agent*` buffer is a
  standard buffer.

  ## File viewer navigation

  When `agent_ui.focus == :file_viewer`, keys route to file viewer
  scroll commands (j/k/Ctrl-d/Ctrl-u/G) which scroll the preview pane.

  ## Side panel usage

  `AgentPanel` calls `delegate_to_mode_fsm/4` for side panel chat
  navigation. That function still performs the buffer swap pattern
  because the side panel's active buffer isn't the agent chat buffer.
  """

  @behaviour Minga.Input.Handler

  import Bitwise

  alias Minga.Agent.UIState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  def handle_key(%{keymap_scope: :agent} = state, cp, mods) do
    panel = AgentAccess.panel(state)

    if panel.input_focused do
      {:passthrough, state}
    else
      agent_ui = AgentAccess.agent_ui(state)

      case agent_ui.focus do
        :chat -> handle_chat_nav(state, cp, mods)
        :file_viewer -> handle_viewer_nav(state, cp, mods)
      end
    end
  end

  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  # ── Chat navigation ─────────────────────────────────────────────────────

  @spec handle_chat_nav(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  defp handle_chat_nav(state, cp, mods) do
    # Process the key through the Mode FSM against the current active
    # buffer (which is already the agent chat buffer, set by focus_window).
    state = Minga.Editor.do_handle_key(state, cp, mods)

    # Unpin the agent chat window so the viewport follows the cursor
    # instead of snapping to the bottom on the next render frame.
    state = unpin_agent_chat_window(state)

    {:handled, state}
  end

  # ── File viewer navigation ─────────────────────────────────────────────

  @spec handle_viewer_nav(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          Minga.Input.Handler.result()
  defp handle_viewer_nav(state, cp, mods) do
    case viewer_nav_command(cp, mods) do
      {:scroll, fun} ->
        {:handled, AgentAccess.update_agent_ui(state, fun)}

      :passthrough ->
        {:passthrough, state}
    end
  end

  @ctrl Minga.Port.Protocol.mod_ctrl()

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

  # ── Side panel delegate ─────────────────────────────────────────────────

  @doc """
  Routes a key through the Mode FSM against the given buffer.

  Used by `AgentPanel` for side panel chat navigation. The side panel's
  active buffer is NOT the agent chat buffer, so this function swaps
  `buffers.active` to the target buffer, runs through Mode FSM, blocks
  insert mode transitions (chat is read-only), syncs the buffer cursor
  to the chat scroll offset, and restores the original active buffer.
  """
  @spec delegate_to_mode_fsm(
          EditorState.t(),
          pid(),
          non_neg_integer(),
          non_neg_integer()
        ) :: EditorState.t()
  def delegate_to_mode_fsm(state, chat_buffer, cp, mods) do
    real_active = state.buffers.active
    state = put_in(state.buffers.active, chat_buffer)

    state = Minga.Editor.do_handle_key(state, cp, mods)

    # Allow visual mode (for text selection and yank) but block insert mode
    # (chat content is read-only). Other modes like operator-pending, search,
    # and command are also allowed since they're needed for full vim grammar.
    state =
      if state.vim.mode == :insert do
        EditorState.transition_mode(state, :normal)
      else
        state
      end

    # Sync buffer cursor to chat scroll offset so the side panel renderer
    # shows the region around the cursor. Unpins auto-scroll since the
    # user is navigating manually.
    {cursor_line, _col} = BufferServer.cursor(chat_buffer)
    state = sync_scroll_to_cursor(state, cursor_line)

    # Only restore the original active buffer if a command didn't
    # legitimately change it (e.g., leader commands like :new_buffer).
    if state.buffers.active == chat_buffer do
      put_in(state.buffers.active, real_active)
    else
      state
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────

  @spec sync_scroll_to_cursor(EditorState.t(), non_neg_integer()) :: EditorState.t()
  defp sync_scroll_to_cursor(state, cursor_line) do
    state =
      AgentAccess.update_agent_ui(state, fn ui ->
        %{ui | scroll: %{ui.scroll | offset: cursor_line, pinned: false}}
      end)

    unpin_agent_chat_window(state)
  end

  @spec unpin_agent_chat_window(EditorState.t()) :: EditorState.t()
  defp unpin_agent_chat_window(state) do
    case EditorState.find_agent_chat_window(state) do
      nil ->
        state

      {win_id, _window} ->
        EditorState.update_window(state, win_id, fn w -> %{w | pinned: false} end)
    end
  end
end
