defmodule Minga.Input.AgentPanel do
  @moduledoc """
  Input handler for the agent side panel (editor scope, panel visible).

  When the agent panel is visible in editor scope, this handler
  intercepts keys for the panel's input field (insert mode) and
  navigation mode. In insert mode, it handles prompt editing (Enter,
  Backspace, Ctrl combos, arrow keys, @-mention triggers). In nav
  mode, it handles q/Escape (close panel), i (focus input), and
  delegates everything else to the mode FSM with the agent buffer
  swapped in for vim navigation of chat content.
  """

  @behaviour Minga.Input.Handler

  import Bitwise

  alias Minga.Agent.PanelState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Input.Vim
  alias Minga.Keymap.Scope
  alias Minga.Port.Protocol

  @ctrl Protocol.mod_ctrl()
  @alt Protocol.mod_alt()
  @shift Protocol.mod_shift()

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

  # Editor scope with agent side panel visible + input focused
  def handle_key(
        %{
          keymap_scope: :editor,
          agent: %{panel: %{visible: true, input_focused: true}}
        } = state,
        cp,
        mods
      ) do
    {:handled, handle_panel_input(state, cp, mods)}
  end

  # Editor scope with agent side panel visible + nav mode
  def handle_key(
        %{
          keymap_scope: :editor,
          agent: %{panel: %{visible: true}, buffer: buf}
        } = state,
        cp,
        mods
      )
      when is_pid(buf) do
    handle_panel_nav(state, cp, mods)
  end

  # Not our concern
  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  # ── Panel input mode ────────────────────────────────────────────────────

  @spec handle_panel_input(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp handle_panel_input(%{agent: %{panel: panel}} = state, cp, mods) do
    case Vim.handle_key(panel.vim, panel.input, cp, mods) do
      {:handled, new_vim, new_tf} ->
        new_panel = %{panel | vim: new_vim, input: new_tf}
        %{state | agent: %{state.agent | panel: new_panel}}

      :not_handled ->
        if PanelState.input_mode(panel) == :insert do
          handle_panel_insert(state, cp, mods)
        else
          dispatch_vim_key(state, cp, mods)
        end
    end
  end

  # ── Panel insert mode keys ─────────────────────────────────────────────

  # Ctrl+Q: unfocus first, then forward the quit key
  defp handle_panel_insert(state, ?q, mods) when band(mods, @ctrl) != 0 do
    send(self(), {:minga_input, {:key_press, ?q, mods}})
    update_agent(state, &AgentState.focus_input(&1, false))
  end

  # Ctrl+S: save current buffer
  defp handle_panel_insert(state, ?s, mods) when band(mods, @ctrl) != 0 do
    if state.buffers.active do
      case BufferServer.save(state.buffers.active) do
        :ok -> :ok
        {:error, _reason} -> :ok
      end
    end

    _ = mods
    state
  end

  # Ctrl+C: submit prompt if input has text, abort if agent is active
  defp handle_panel_insert(state, ?c, mods) when band(mods, @ctrl) != 0 do
    if PanelState.input_text(state.agent.panel) == "" do
      if state.agent.status in [:thinking, :tool_executing] do
        AgentCommands.abort_agent(state)
      else
        state
      end
    else
      AgentCommands.submit_prompt(state)
    end
  end

  # Ctrl+D: scroll chat down
  defp handle_panel_insert(state, ?d, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.scroll_chat_down(state)
  end

  # Ctrl+U: scroll chat up
  defp handle_panel_insert(state, ?u, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.scroll_chat_up(state)
  end

  # Ctrl+L: clear chat display
  defp handle_panel_insert(state, ?l, mods) when band(mods, @ctrl) != 0 do
    AgentCommands.clear_chat_display(state)
  end

  # Escape: switch to normal mode (vim-style)
  defp handle_panel_insert(state, 27, _mods) do
    AgentCommands.input_to_normal(state)
  end

  # Backspace
  defp handle_panel_insert(state, 127, _mods) do
    AgentCommands.input_backspace(state)
  end

  # Insert newline: all the ways Shift+Enter arrives across terminals.
  defp handle_panel_insert(state, 13, mods) when band(mods, @shift) != 0 do
    update_agent(state, &AgentState.insert_newline/1)
  end

  defp handle_panel_insert(state, ?j, mods) when band(mods, @ctrl) != 0 do
    update_agent(state, &AgentState.insert_newline/1)
  end

  defp handle_panel_insert(state, 0x0A, _mods) do
    update_agent(state, &AgentState.insert_newline/1)
  end

  defp handle_panel_insert(state, 13, mods) when band(mods, @alt) != 0 do
    update_agent(state, &AgentState.insert_newline/1)
  end

  # Enter: submit prompt
  defp handle_panel_insert(state, 13, _mods) do
    AgentCommands.submit_prompt(state)
  end

  # Up arrow: move cursor up or recall history
  defp handle_panel_insert(state, cp, _mods) when cp in [0xF700, 57_352, 0x415B1B] do
    case AgentState.move_cursor_up(state.agent) do
      :at_top -> update_agent(state, &AgentState.history_prev/1)
      agent -> %{state | agent: agent}
    end
  end

  # Down arrow: move cursor down or forward history
  defp handle_panel_insert(state, cp, _mods) when cp in [0xF701, 57_353, 0x425B1B] do
    case AgentState.move_cursor_down(state.agent) do
      :at_bottom -> update_agent(state, &AgentState.history_next/1)
      agent -> %{state | agent: agent}
    end
  end

  # @ trigger mention completion
  defp handle_panel_insert(state, ?@, mods)
       when band(mods, @ctrl) == 0 and band(mods, @alt) == 0 do
    AgentCommands.scope_trigger_mention(state)
  end

  # Printable characters
  defp handle_panel_insert(state, cp, mods)
       when cp >= 32 and band(mods, @ctrl) == 0 and band(mods, @alt) == 0 do
    AgentCommands.input_char(state, <<cp::utf8>>)
  end

  # Swallow everything else
  defp handle_panel_insert(state, _cp, _mods), do: state

  # ── Panel navigation mode ──────────────────────────────────────────────

  @spec handle_panel_nav(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  defp handle_panel_nav(state, _cp, _mods) when is_map(state.mode_state.leader_node) do
    {:handled, delegate_to_mode_fsm(state, 0, 0)}
  end

  defp handle_panel_nav(state, cp, mods) do
    if key_sequence_pending?(state) do
      {:handled, delegate_to_mode_fsm(state, cp, mods)}
    else
      case panel_nav_key(state, cp, mods) do
        {:panel, new_state} -> {:handled, new_state}
        :delegate -> {:handled, delegate_to_mode_fsm(state, cp, mods)}
      end
    end
  end

  @spec panel_nav_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:panel, EditorState.t()} | :delegate
  defp panel_nav_key(state, cp, _mods) when cp in [?q, 27] do
    {:panel, AgentCommands.toggle_panel(state)}
  end

  defp panel_nav_key(state, ?i, _mods) do
    {:panel, update_agent(state, &AgentState.focus_input(&1, true))}
  end

  defp panel_nav_key(_state, _cp, _mods), do: :delegate

  # ── Shared helpers ──────────────────────────────────────────────────────

  @doc """
  Routes a key through Vim.handle_key for non-insert panel modes.

  Tries the Vim module first (handles arrow keys, etc.). If not handled,
  falls through to the agent scope trie for meta keys (Escape, Ctrl+C).
  Called by both AgentPanel (editor scope side panel) and Input.Scoped
  (agent scope normal mode).
  """
  @spec dispatch_vim_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  def dispatch_vim_key(state, cp, mods) do
    panel = state.agent.panel

    case Vim.handle_key(panel.vim, panel.input, cp, mods) do
      {:handled, new_vim, new_tf} ->
        new_panel = %{panel | vim: new_vim, input: new_tf}
        %{state | agent: %{state.agent | panel: new_panel}}

      :not_handled ->
        key = {cp, mods}

        case Scope.resolve_key(:agent, :input_normal, key) do
          {:command, command} -> Commands.execute(state, command)
          {:prefix, _node} -> state
          :not_found -> state
        end
    end
  end

  # Swaps the active buffer to the agent buffer, runs the key through the
  # mode FSM, blocks mode transitions, and restores the real buffer.
  # Used for panel nav mode (vim navigation of chat content).
  @spec delegate_to_mode_fsm(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp delegate_to_mode_fsm(
         %{agent: %{buffer: buf}} = state,
         cp,
         mods
       )
       when is_pid(buf) do
    real_active = state.buffers.active
    state = put_in(state.buffers.active, buf)
    state = Minga.Editor.do_handle_key(state, cp, mods)

    state =
      if state.mode != :normal do
        %{state | mode: :normal, mode_state: Minga.Mode.initial_state()}
      else
        state
      end

    put_in(state.buffers.active, real_active)
  end

  @spec key_sequence_pending?(EditorState.t()) :: boolean()
  defp key_sequence_pending?(%{mode_state: %{leader_node: node}}) when node != nil, do: true
  defp key_sequence_pending?(%{mode_state: %{pending_g: true}}), do: true
  defp key_sequence_pending?(%{mode: mode}) when mode in [:operator_pending, :command], do: true
  defp key_sequence_pending?(_state), do: false

  @spec update_agent(EditorState.t(), (AgentState.t() -> AgentState.t())) :: EditorState.t()
  defp update_agent(state, fun), do: %{state | agent: fun.(state.agent)}
end
