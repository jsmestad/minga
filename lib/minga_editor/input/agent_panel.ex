defmodule MingaEditor.Input.AgentPanel do
  @moduledoc """
  Input handler for the agent prompt and side-panel navigation.

  When the agent prompt is focused, this handler owns prompt editing in both editor scope and full agent workspaces. When the side panel is visible in editor scope but the prompt is not focused, it owns panel navigation.

  In insert mode, it handles prompt editing (Enter, Backspace, Ctrl
  combos, arrow keys, @-mention triggers). In normal/visual/
  operator-pending mode, it routes keys through the standard Mode FSM
  by temporarily swapping the active buffer to the prompt buffer.

  Navigation mode (panel visible but input not focused) delegates common
  transcript movement keys to semantic chat scroll state.
  """

  @behaviour MingaEditor.Input.Handler

  @type state :: MingaEditor.Input.Handler.handler_state()

  alias MingaEditor.Agent.UIState
  alias MingaEditor.Commands
  alias MingaEditor.Commands.Agent, as: AgentCommands
  alias MingaEditor.Commands.AgentSubStates
  alias MingaEditor.LayoutPreset
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.Input.AgentNav
  alias Minga.Keymap

  @impl true
  @spec handle_key(state(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()

  def handle_key(state, cp, mods) do
    state.workspace.agent_ui.panel |> route_panel_key(state, cp, mods)
  end

  @spec route_panel_key(UIState.Panel.t(), EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          MingaEditor.Input.Handler.result()
  defp route_panel_key(%{visible: true, input_focused: true}, state, cp, mods) do
    {:handled, handle_panel_input(state, cp, mods)}
  end

  defp route_panel_key(%{visible: true}, %{workspace: %{keymap_scope: :editor}} = state, cp, mods) do
    handle_panel_nav(state, cp, mods)
  end

  defp route_panel_key(_panel, state, _cp, _mods), do: {:passthrough, state}

  # ── Panel input mode ────────────────────────────────────────────────────

  @spec handle_panel_input(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp handle_panel_input(state, 27, 0), do: handle_panel_escape(state)

  defp handle_panel_input(state, cp, mods) do
    binding_state = Minga.Editing.binding_state(state)

    if binding_state == :cua or Minga.Editing.inserting?(state) do
      # Resolve through the agent scope trie for the active binding state.
      # CUA uses the :cua trie; vim insert uses the :insert trie. Both
      # need self-insert fallback for printable chars.
      key = {cp, mods}

      case Keymap.resolve_scoped_key(
             :agent,
             binding_state,
             key,
             keymap_server: state.interaction.keymap_server
           ) do
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

  @spec handle_panel_escape(EditorState.t()) :: EditorState.t()
  defp handle_panel_escape(state) do
    case Minga.Editing.mode(state) do
      :normal -> AgentCommands.scope_unfocus_input(state)
      _ -> dispatch_prompt_via_mode_fsm(state, 27, 0)
    end
  end

  @spec handle_panel_self_insert(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()
  defp handle_panel_self_insert(state, ?@, _mods) do
    AgentCommands.scope_trigger_mention(state)
  end

  defp handle_panel_self_insert(state, ?/, _mods) do
    if AgentSubStates.slash_command_token_at_cursor?(state) do
      AgentCommands.scope_trigger_slash_completion(state)
    else
      state = AgentCommands.input_char(state, "/")
      AgentCommands.scope_trigger_slash_completion(state)
    end
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

  @spec set_active_buffer_override(EditorState.t(), pid() | nil) :: EditorState.t()
  defp set_active_buffer_override(state, pid) do
    %{
      state
      | workspace:
          MingaEditor.Session.State.set_buffers(
            state.workspace,
            (&Buffers.set_active_override(&1, pid)).(state.workspace.buffers)
          )
    }
  end

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
    case panel_nav_key(state, cp, mods) do
      {:panel, new_state} -> {:handled, new_state}
      :delegate -> AgentNav.handle_chat_nav(state, cp, mods)
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
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          state,
          MingaEditor.Agent.PromptBuffer.set_input_focused(state.workspace.agent_ui, false)
        )
      end

    {:panel, state}
  end

  defp panel_nav_key(state, ?i, _mods) do
    state =
      MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
        state,
        MingaEditor.Agent.PromptBuffer.set_input_focused(state.workspace.agent_ui, true)
      )

    {:panel,
     %{state | workspace: MingaEditor.Session.State.transition_mode(state.workspace, :insert)}}
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
    panel = state.workspace.agent_ui.panel
    prompt_pid = panel.prompt_buffer

    if is_pid(prompt_pid) do
      try do
        real_active = state.workspace.buffers.active
        state = set_active_buffer_override(state, prompt_pid)
        state = MingaEditor.do_handle_key(state, cp, mods)

        # Only restore if a command didn't legitimately change buffers.active.
        # Same guard as chat navigation: only restore if the command did not
        # legitimately change buffers.active.
        if state.workspace.buffers.active == prompt_pid do
          set_active_buffer_override(state, real_active)
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

      case Keymap.resolve_scoped_key(
             :agent,
             :input_normal,
             key,
             keymap_server: state.interaction.keymap_server
           ) do
        {:command, command} -> Commands.execute(state, command)
        {:prefix, _node} -> state
        :not_found -> state
      end
    end
  end
end
