defmodule Minga.Input.AgentPanel do
  @moduledoc """
  Input handler for the agent side panel (editor scope, panel visible).

  When the agent panel is visible in editor scope, this handler
  intercepts keys for the panel's input field and navigation mode.

  In insert mode, it handles prompt editing (Enter, Backspace, Ctrl
  combos, arrow keys, @-mention triggers). In normal/visual/
  operator-pending mode, it routes keys through the standard Mode FSM
  by temporarily swapping the active buffer to the prompt buffer.

  Navigation mode (panel visible but input not focused) delegates to
  the mode FSM with the agent chat buffer for vim navigation of chat
  content.
  """

  @behaviour Minga.Input.Handler

  alias Minga.Agent.UIState
  alias Minga.Editor.Commands
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.LayoutPreset
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Input
  alias Minga.Input.AgentNav
  alias Minga.Keymap

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

  # Editor scope with agent side panel visible + input focused
  def handle_key(%{workspace: %{keymap_scope: :editor}} = state, cp, mods) do
    panel = AgentAccess.panel(state)

    if panel.visible and panel.input_focused do
      {:handled, handle_panel_input(state, cp, mods)}
    else
      agent = AgentAccess.agent(state)

      if panel.visible and is_pid(agent.buffer) do
        handle_panel_nav(state, cp, mods)
      else
        {:passthrough, state}
      end
    end
  end

  # Not our concern
  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  # ── Panel input mode ────────────────────────────────────────────────────

  @spec handle_panel_input(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp handle_panel_input(state, cp, mods) do
    binding_state = Minga.Editing.binding_state(state)

    if binding_state == :cua or Minga.Editing.inserting?(state) do
      # Resolve through the agent scope trie for the active binding state.
      # CUA uses the :cua trie; vim insert uses the :insert trie. Both
      # need self-insert fallback for printable chars.
      key = {cp, mods}

      case Keymap.resolve_scoped_key(:agent, binding_state, key) do
        {:command, command} ->
          Commands.execute(state, command)

        {:prefix, _node} ->
          # No prefix sequences in insert/CUA mode currently
          state

        :not_found ->
          # Printable chars and @-mention trigger
          handle_panel_self_insert(state, cp, mods)
      end
    else
      # Normal, visual, operator-pending: route through Mode FSM
      # targeting the prompt buffer
      dispatch_prompt_via_mode_fsm(state, cp, mods)
    end
  end

  @spec handle_panel_self_insert(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp handle_panel_self_insert(state, ?@, _mods) do
    AgentCommands.scope_trigger_mention(state)
  end

  defp handle_panel_self_insert(state, cp, _mods)
       when cp >= 32 do
    AgentCommands.input_char(state, <<cp::utf8>>)
  end

  defp handle_panel_self_insert(state, _cp, _mods), do: state

  # Panel insert mode keys are resolved through the agent scope insert
  # trie (see Minga.Keymap.Scope.Agent.insert_trie). This eliminates the
  # 17 hardcoded function clauses that previously duplicated the trie
  # bindings. Printable chars and @-mention fall through to
  # handle_panel_self_insert above.

  # ── Panel navigation mode ──────────────────────────────────────────────

  @spec handle_panel_nav(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  # Leader sequence in progress: passthrough to ModeFSM so the leader
  # command runs against the real active buffer, not the chat buffer.
  # Previously this called delegate_to_mode_fsm(state, 0, 0) which
  # discarded the actual key and could clobber buffers.active if the
  # leader command (e.g. :new_buffer) changed it during execution.
  defp handle_panel_nav(state, cp, mods) do
    if Minga.Editing.in_leader?(state) do
      {:passthrough, state}
    else
      handle_panel_nav_dispatch(state, cp, mods)
    end
  end

  defp handle_panel_nav_dispatch(state, cp, mods) do
    if Input.key_sequence_pending?(state) do
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
    # Close the agent split if one exists, otherwise just unfocus input
    state =
      if LayoutPreset.has_agent_chat?(state) do
        AgentCommands.toggle_agent_split(state)
      else
        AgentAccess.update_agent_ui(state, &UIState.set_input_focused(&1, false))
      end

    {:panel, state}
  end

  defp panel_nav_key(state, ?i, _mods) do
    state = AgentAccess.update_agent_ui(state, &UIState.set_input_focused(&1, true))
    {:panel, EditorState.transition_mode(state, :insert)}
  end

  defp panel_nav_key(_state, _cp, _mods), do: :delegate

  # ── Shared helpers ──────────────────────────────────────────────────────

  @doc """
  Routes a key through the standard Mode FSM targeting the prompt buffer.

  Swaps the active buffer to the prompt buffer, runs the key through
  the mode FSM (which handles all vim operations: motions, operators,
  visual mode, text objects, undo/redo), then restores the original
  active buffer.

  If the Mode FSM transitions to insert mode, we leave the mode as
  insert so that subsequent keys are handled by `handle_panel_insert`.
  """
  @spec dispatch_prompt_via_mode_fsm(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  def dispatch_prompt_via_mode_fsm(state, cp, mods) do
    panel = AgentAccess.panel(state)
    prompt_pid = panel.prompt_buffer

    if is_pid(prompt_pid) do
      try do
        real_active = state.workspace.buffers.active
        state = put_in(state.workspace.buffers.active, prompt_pid)
        state = Minga.Editor.do_handle_key(state, cp, mods)

        # Only restore if a command didn't legitimately change buffers.active.
        # Same guard as AgentNav.delegate_to_mode_fsm/4.
        if state.workspace.buffers.active == prompt_pid do
          put_in(state.workspace.buffers.active, real_active)
        else
          state
        end
      catch
        # Hot path race: prompt buffer may die between existence check and
        # key dispatch. Targeted catch per AGENTS.md rule 4.
        :exit, _ -> state
      end
    else
      # No prompt buffer, try scope bindings
      key = {cp, mods}

      case Keymap.resolve_scoped_key(:agent, :input_normal, key) do
        {:command, command} -> Commands.execute(state, command)
        {:prefix, _node} -> state
        :not_found -> state
      end
    end
  end

  # Delegates to the shared AgentNav dispatch, which swaps the active
  # buffer to the agent buffer, runs through Mode FSM, blocks mode
  # transitions, syncs cursor to scroll, and restores the original buffer.
  @spec delegate_to_mode_fsm(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp delegate_to_mode_fsm(state, cp, mods) do
    buf = AgentAccess.agent(state).buffer

    if is_pid(buf) do
      AgentNav.delegate_to_mode_fsm(state, buf, cp, mods)
    else
      state
    end
  end
end
