defmodule Minga.Input.AgentChatNav do
  @moduledoc """
  Input handler for vim navigation of agent chat content.

  Sits after `Scoped` in the handler chain. When the agentic view is
  active and the prompt input is not focused, this handler routes keys
  through the standard Mode FSM against the agent's `*Agent*` buffer.
  This gives chat navigation the full vim grammar (motions, counts,
  search, text objects, visual selection for yank) for free.

  Domain-specific bindings (toggle collapse, copy code block, focus
  input, session switcher, etc.) are handled by the agent scope trie
  in `Scoped`, which runs earlier in the chain. Only keys that the
  scope trie doesn't claim reach this handler.

  After the Mode FSM processes the key, the buffer cursor position is
  synced to the chat scroll offset so the renderer shows the correct
  region.

  ## Why a separate handler (not inline in Scoped)

  The scope trie and Mode FSM are two independent key dispatch systems.
  Mixing them in a single handler creates prefix collisions (`g` is a
  prefix in both) and forces reimplementation of vim commands as scope
  bindings. Separating them keeps each system focused:

  - Scope trie: domain commands only (collapse, copy, focus, session)
  - Mode FSM: all vim navigation (motions, search, counts, dot repeat)

  ## Why buffer swap (not a structured NavigableContent adapter)

  The `*Agent*` buffer already contains the chat content as markdown,
  synced by `BufferSync`. Using it for navigation gives us all vim
  motions, search, and counts immediately. A structured ChatSnapshot
  adapter is the next evolution: when built, this handler's internals
  change (swap `do_handle_key` for NavigableContent dispatch) but its
  position in the handler chain and its API remain the same.

  ## Editor scope side panel

  The side panel (`AgentPanel`, keymap_scope: :editor) uses the same
  `delegate_to_mode_fsm/4` function for its chat navigation. Both
  paths share the buffer-swap-and-sync pattern.
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

  # i/a/A in chat nav mode focuses the prompt input and enters insert mode,
  # rather than trying to enter insert mode on the read-only chat buffer.
  defp handle_chat_nav(state, cp, _mods) when cp in [?i, ?a, ?A] and state.vim.mode == :normal do
    state = AgentAccess.update_agent_ui(state, &UIState.set_input_focused(&1, true))

    {:handled, EditorState.transition_mode(state, :insert)}
  end

  defp handle_chat_nav(state, cp, mods) do
    agent = AgentAccess.agent(state)

    if is_pid(agent.buffer) do
      {:handled, delegate_to_mode_fsm(state, agent.buffer, cp, mods)}
    else
      {:passthrough, state}
    end
  end

  # ── File viewer navigation ─────────────────────────────────────────────

  # The file viewer is a preview pane with its own scroll state, not a
  # buffer with a cursor. Navigation keys scroll the preview.
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

  # ── Shared dispatch ─────────────────────────────────────────────────────

  @doc """
  Routes a key through the Mode FSM against the given buffer.

  Swaps `buffers.active` to the target buffer, runs through
  `do_handle_key` (Mode FSM + full KeyDispatch pipeline including
  counts, dot repeat, macros), blocks mode transitions to insert
  (chat is read-only, always normal mode), syncs the buffer cursor
  to the chat scroll offset, and restores the original active buffer.

  Used by both `AgentChatNav` (agentic view) and `AgentPanel` (side
  panel) for chat navigation.
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

    # Sync buffer cursor to chat scroll offset so the renderer shows the
    # region around the cursor. Unpins auto-scroll since the user is
    # navigating manually.
    {cursor_line, _col} = BufferServer.cursor(chat_buffer)
    state = sync_scroll_to_cursor(state, cursor_line)

    # Only restore the original active buffer if a command didn't
    # legitimately change it. Leader commands like :new_buffer update
    # buffers.active to the newly created buffer. If we blindly restore
    # real_active, state.buffers.active and window.buffer diverge:
    # the window shows the new buffer but keystrokes write to the old one.
    if state.buffers.active == chat_buffer do
      put_in(state.buffers.active, real_active)
    else
      state
    end
  end

  @spec sync_scroll_to_cursor(EditorState.t(), non_neg_integer()) :: EditorState.t()
  defp sync_scroll_to_cursor(state, cursor_line) do
    state =
      AgentAccess.update_agent_ui(state, fn ui ->
        %{ui | scroll: %{ui.scroll | offset: cursor_line, pinned: false}}
      end)

    # Also unpin the agent chat window so the render pipeline doesn't
    # snap the viewport back to the bottom on the next frame.
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
