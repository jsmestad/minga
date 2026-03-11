defmodule Minga.Input.Scoped do
  @moduledoc """
  Scope-aware input handler that replaces per-view focus stack entries.

  Sits in the focus stack between modal overlays (picker, completion, conflict
  prompt) and the vim mode FSM fallback. Resolves keys through the active
  keymap scope, handling scope-specific bindings, prefix sequences, and
  sub-state dispatch (search input, mention completion).

  For the `:editor` scope, keys pass through to the mode FSM unless the agent
  side panel is visible, in which case panel-specific handling applies.

  For the `:agent` scope, keys are resolved against the agent scope trie.
  Context-dependent sub-states (search input, mention completion, tool
  approval, diff review) are handled before trie lookup. The leader key
  (SPC) always passes through to the mode FSM for which-key integration.

  For the `:file_tree` scope, tree-specific keys are handled via scope
  resolution and unmatched keys delegate to the mode FSM with the tree
  buffer swapped in as the active buffer (providing full vim navigation).
  """

  @behaviour Minga.Input.Handler

  import Bitwise

  alias Minga.Agent.PanelState
  alias Minga.Agent.View.Mouse, as: AgentViewMouse
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.Commands
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.Layout
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.FileTree
  alias Minga.Input.Vim
  alias Minga.Keymap.Scope
  alias Minga.Port.Protocol

  @ctrl Protocol.mod_ctrl()
  @alt Protocol.mod_alt()
  @tab 9
  @shift Protocol.mod_shift()
  @space 32

  # ── Handler callback ───────────────────────────────────────────────────────

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

  # ── Editor scope ─────────────────────────────────────────────────────────

  # Editor scope with agent side panel visible + input focused:
  # intercept all keys for the input field.
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

  # Editor scope with agent side panel visible + nav mode:
  # handle panel-specific keys, delegate rest to mode FSM with agent buffer.
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

  # Editor scope (no panel): always passthrough to mode FSM
  def handle_key(%{keymap_scope: :editor} = state, _cp, _mods) do
    {:passthrough, state}
  end

  # ── Agent scope ──────────────────────────────────────────────────────────

  # Agent scope: dispatch through scope resolution
  def handle_key(%{keymap_scope: :agent, agentic: %{active: true}} = state, cp, mods) do
    handle_agent_key(state, cp, mods)
  end

  # Agent scope but agentic view not active (race condition guard): passthrough
  def handle_key(%{keymap_scope: :agent} = state, _cp, _mods) do
    {:passthrough, state}
  end

  # ── File tree scope ──────────────────────────────────────────────────────

  # File tree scope with tree focused: handle via scope + mode FSM delegation
  def handle_key(
        %{keymap_scope: :file_tree, file_tree: %{tree: %FileTree{}, focused: true}} = state,
        cp,
        mods
      ) do
    handle_file_tree_key(state, cp, mods)
  end

  # File tree scope but not focused: passthrough
  def handle_key(%{keymap_scope: :file_tree} = state, _cp, _mods) do
    {:passthrough, state}
  end

  # Unknown scope: passthrough
  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  # ══════════════════════════════════════════════════════════════════════════
  # Agent scope dispatch
  # ══════════════════════════════════════════════════════════════════════════

  @spec handle_agent_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

  # Dismiss toast on any key (then re-process)
  defp handle_agent_key(%{agentic: %{toast: toast}} = state, cp, mods)
       when toast != nil do
    state = %{state | agentic: ViewState.dismiss_toast(state.agentic)}
    handle_agent_key(state, cp, mods)
  end

  # SPC when not in insert mode: passthrough to leader/which-key
  defp handle_agent_key(
         %{agent: %{panel: %{input_focused: false}}} = state,
         @space,
         mods
       )
       when band(mods, @ctrl) == 0 do
    {:passthrough, state}
  end

  # Leader sequence in progress: passthrough ALL keys to mode FSM
  defp handle_agent_key(
         %{mode_state: %{leader_node: node}, agent: %{panel: %{input_focused: false}}} = state,
         _cp,
         _mods
       )
       when is_map(node) do
    {:passthrough, state}
  end

  # Sub-state: search input active
  defp handle_agent_key(
         %{agentic: %{search: %{input_active: true}}} = state,
         cp,
         _mods
       ) do
    {:handled, AgentCommands.handle_search_key(state, cp)}
  end

  # Sub-state: mention completion active (insert mode only)
  defp handle_agent_key(
         %{agent: %{panel: %{input_focused: true, mention_completion: comp}}} = state,
         cp,
         mods
       )
       when comp != nil do
    {:handled, AgentCommands.handle_mention_key(state, cp, mods)}
  end

  # Sub-state: tool approval pending (y/n/Y/N)
  defp handle_agent_key(
         %{agent: %{pending_approval: approval, panel: %{input_focused: false}}} = state,
         cp,
         _mods
       )
       when is_map(approval) do
    handle_approval_key(state, cp)
  end

  # Sub-state: diff review active in file_viewer focus (y/x/Y/X)
  defp handle_agent_key(
         %{
           agentic: %{focus: :file_viewer, preview: %Preview{content: {:diff, _}}},
           agent: %{panel: %{input_focused: false}}
         } = state,
         cp,
         _mods
       ) do
    handle_diff_review_key(state, cp)
  end

  # Normal dispatch: determine vim state and resolve through scope
  # Tab on a paste placeholder line: toggle expand/collapse
  defp handle_agent_key(
         %{agent: %{panel: %{input_focused: true} = panel}} = state,
         @tab,
         0
       ) do
    {cursor_line, _} = panel.input.cursor
    current_line = Enum.at(panel.input.lines, cursor_line)

    if PanelState.paste_placeholder?(current_line) or cursor_on_expanded_block?(panel) do
      {:handled, AgentCommands.toggle_paste_expand(state)}
    else
      resolve_agent_key(state, :insert, @tab, 0)
    end
  end

  defp handle_agent_key(%{agent: %{panel: %{input_focused: true} = panel}} = state, cp, mods) do
    mode = PanelState.input_mode(panel)

    if mode == :insert do
      resolve_agent_key(state, :insert, cp, mods)
    else
      dispatch_vim_key(state, cp, mods)
    end
  end

  defp handle_agent_key(state, cp, mods) do
    resolve_agent_key(state, :normal, cp, mods)
  end

  # ── Agent scope trie resolution ────────────────────────────────────────────

  @spec resolve_agent_key(
          EditorState.t(),
          Scope.vim_state(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  defp resolve_agent_key(state, vim_state, cp, mods) do
    key = {cp, mods}

    # Check if we're continuing a prefix sequence
    case state.agentic.pending_prefix do
      nil ->
        # Fresh lookup
        resolve_scope_key(state, :agent, vim_state, key, cp, mods)

      prefix_node when is_map(prefix_node) ->
        # Continuing a prefix sequence stored as a trie node
        state = %{state | agentic: ViewState.clear_prefix(state.agentic)}

        case Scope.resolve_key_in_node(prefix_node, key) do
          {:command, command} ->
            {:handled, Commands.execute(state, command)}

          {:prefix, sub_node} ->
            # Another prefix level (rare)
            {:handled, %{state | agentic: ViewState.set_prefix(state.agentic, sub_node)}}

          :not_found ->
            # Invalid prefix continuation, re-process the key normally
            resolve_scope_key(state, :agent, vim_state, key, cp, mods)
        end

      _atom_prefix ->
        # Legacy atom prefix (shouldn't happen in new system, but handle gracefully)
        state = %{state | agentic: ViewState.clear_prefix(state.agentic)}
        resolve_scope_key(state, :agent, vim_state, key, cp, mods)
    end
  end

  @spec resolve_scope_key(
          EditorState.t(),
          Scope.scope_name(),
          Scope.vim_state(),
          {non_neg_integer(), non_neg_integer()},
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}
  defp resolve_scope_key(state, scope_name, vim_state, key, cp, mods) do
    case Scope.resolve_key(scope_name, vim_state, key) do
      {:command, command} ->
        {:handled, Commands.execute(state, command)}

      {:prefix, prefix_node} ->
        # Store the prefix node for the next key
        {:handled, %{state | agentic: ViewState.set_prefix(state.agentic, prefix_node)}}

      :not_found ->
        # No scope binding. In insert mode, self-insert printable chars.
        if vim_state == :insert and cp >= 32 and band(mods, @ctrl) == 0 and
             band(mods, @alt) == 0 do
          handle_agent_self_insert(state, cp, mods)
        else
          # Not handled by scope, swallow the key
          {:handled, state}
        end
    end
  end

  # Routes a key through Vim.handle_key for non-insert input modes.
  # If the Vim module handles the key, update panel state.
  # If not, fall through to the scope trie for meta keys (Escape, Ctrl+C, etc.).
  @spec dispatch_vim_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()}
  defp dispatch_vim_key(state, cp, mods) do
    panel = state.agent.panel

    case Vim.handle_key(panel.vim, panel.input, cp, mods) do
      {:handled, new_vim, new_tf} ->
        new_panel = %{panel | vim: new_vim, input: new_tf}
        {:handled, %{state | agent: %{state.agent | panel: new_panel}}}

      :not_handled ->
        # Fall through to scope trie for meta keys
        {:handled, new_state} =
          resolve_scope_key(state, :agent, :input_normal, {cp, mods}, cp, mods)

        {:handled, new_state}
    end
  end

  # ── Agent self-insert (insert mode, printable chars) ───────────────────────

  @spec handle_agent_self_insert(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()}
  defp handle_agent_self_insert(state, ?@, _mods) do
    {:handled, AgentCommands.scope_trigger_mention(state)}
  end

  defp handle_agent_self_insert(state, cp, _mods) do
    char = <<cp::utf8>>
    {:handled, Commands.execute(state, {:agent_self_insert, char})}
  end

  # ── Tool approval sub-state ────────────────────────────────────────────────

  @spec handle_approval_key(EditorState.t(), non_neg_integer()) ::
          {:handled, EditorState.t()}
  defp handle_approval_key(state, ?y) do
    {:handled, Commands.execute(state, :agent_approve_tool)}
  end

  defp handle_approval_key(state, ?n) do
    {:handled, Commands.execute(state, :agent_deny_tool)}
  end

  defp handle_approval_key(state, ?Y) do
    # Y = approve all (auto-approve future calls of this type)
    {:handled, Commands.execute(state, :agent_approve_tool)}
  end

  defp handle_approval_key(state, _cp), do: {:handled, state}

  # ── Diff review sub-state ──────────────────────────────────────────────────

  @spec handle_diff_review_key(EditorState.t(), non_neg_integer()) ::
          {:handled, EditorState.t()}
  defp handle_diff_review_key(state, ?y) do
    {:handled, Commands.execute(state, :agent_accept_hunk)}
  end

  defp handle_diff_review_key(state, ?x) do
    {:handled, Commands.execute(state, :agent_reject_hunk)}
  end

  defp handle_diff_review_key(state, ?Y) do
    {:handled, Commands.execute(state, :agent_accept_all_hunks)}
  end

  defp handle_diff_review_key(state, ?X) do
    {:handled, Commands.execute(state, :agent_reject_all_hunks)}
  end

  # Navigation keys still work during diff review
  defp handle_diff_review_key(state, cp) do
    resolve_scope_key(state, :agent, :normal, {cp, 0}, cp, 0)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Agent side panel (editor scope, panel visible)
  # ══════════════════════════════════════════════════════════════════════════

  # The agent side panel (SPC a a) lives in the editor scope. When visible,
  # it has two modes:
  #
  # 1. Input focused: keys go to the chat input field. Same bindings as the
  #    agentic view's insert mode.
  # 2. Navigation: panel-specific keys (q/i/ESC) are handled directly.
  #    Everything else delegates to the mode FSM with the agent buffer
  #    swapped in as active, giving full vim navigation of chat content.

  @spec handle_panel_input(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          EditorState.t()

  # ── Mention completion active ──────────────────────────────────────────

  defp handle_panel_input(
         %{agent: %{panel: %{mention_completion: %{} = _comp}}} = state,
         cp,
         mods
       ) do
    AgentCommands.handle_mention_key(state, cp, mods)
  end

  # Non-insert modes (normal, visual, operator-pending): route through the
  # Vim grammar module. If Vim doesn't handle it, fall through to scope trie
  # for meta keys (Escape/unfocus, Ctrl+C/submit, etc.).
  defp handle_panel_input(%{agent: %{panel: panel}} = state, cp, mods) do
    mode = PanelState.input_mode(panel)

    if mode == :insert do
      handle_panel_insert(state, cp, mods)
    else
      dispatch_vim_key(state, cp, mods)
    end
  end

  # ── Regular input (insert mode) ────────────────────────────────────────

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

  # Escape: unfocus the input
  defp handle_panel_insert(state, 27, _mods) do
    AgentCommands.input_to_normal(state)
  end

  # Backspace
  defp handle_panel_insert(state, 127, _mods) do
    AgentCommands.input_backspace(state)
  end

  # Insert newline: all the ways Shift+Enter arrives across terminals.
  # See agent.ex keymap/1 comments for the full explanation.
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
  defp handle_panel_insert(state, cp, _mods) when cp == 0xF700 do
    case AgentState.move_cursor_up(state.agent) do
      :at_top -> update_agent(state, &AgentState.history_prev/1)
      agent -> %{state | agent: agent}
    end
  end

  # Down arrow: move cursor down or forward history
  defp handle_panel_insert(state, cp, _mods) when cp == 0xF701 do
    case AgentState.move_cursor_down(state.agent) do
      :at_bottom -> update_agent(state, &AgentState.history_next/1)
      agent -> %{state | agent: agent}
    end
  end

  # Legacy arrow encodings (escape sequences from Zig TUI)
  defp handle_panel_insert(state, 0x415B1B, _mods) do
    case AgentState.move_cursor_up(state.agent) do
      :at_top -> update_agent(state, &AgentState.history_prev/1)
      agent -> %{state | agent: agent}
    end
  end

  defp handle_panel_insert(state, 0x425B1B, _mods) do
    case AgentState.move_cursor_down(state.agent) do
      :at_bottom -> update_agent(state, &AgentState.history_next/1)
      agent -> %{state | agent: agent}
    end
  end

  # @ at start of line or after whitespace: trigger mention completion
  defp handle_panel_insert(state, ?@, mods)
       when band(mods, @ctrl) == 0 and band(mods, @alt) == 0 do
    AgentCommands.scope_trigger_mention(state)
  end

  # Printable characters (no Ctrl/Alt)
  defp handle_panel_insert(state, cp, mods)
       when cp >= 32 and band(mods, @ctrl) == 0 and band(mods, @alt) == 0 do
    AgentCommands.input_char(state, <<cp::utf8>>)
  end

  # Everything else: silently swallow
  defp handle_panel_insert(state, _cp, _mods), do: state

  # ── Panel navigation mode ─────────────────────────────────────────────────

  @spec handle_panel_nav(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

  # If a leader key sequence is in progress, pass through to mode FSM
  defp handle_panel_nav(state, _cp, _mods) when is_map(state.mode_state.leader_node) do
    {:handled, delegate_to_mode_fsm_with_agent_buffer(state, elem({0, 0}, 0), 0)}
  end

  # Override: when a leader sequence is pending, pass the actual key through
  defp handle_panel_nav(state, cp, mods) do
    if key_sequence_pending?(state) do
      {:handled, delegate_to_mode_fsm_with_agent_buffer(state, cp, mods)}
    else
      case panel_nav_key(state, cp, mods) do
        {:panel, new_state} -> {:handled, new_state}
        :delegate -> {:handled, delegate_to_mode_fsm_with_agent_buffer(state, cp, mods)}
      end
    end
  end

  @spec panel_nav_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:panel, EditorState.t()} | :delegate

  # q or Escape: close the panel
  defp panel_nav_key(state, cp, _mods) when cp in [?q, 27] do
    {:panel, AgentCommands.toggle_panel(state)}
  end

  # i: focus the input field
  defp panel_nav_key(state, ?i, _mods) do
    {:panel, update_agent(state, &AgentState.focus_input(&1, true))}
  end

  # Everything else: delegate to mode FSM for vim navigation
  defp panel_nav_key(_state, _cp, _mods), do: :delegate

  @spec delegate_to_mode_fsm_with_agent_buffer(
          EditorState.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: EditorState.t()
  defp delegate_to_mode_fsm_with_agent_buffer(
         %{agent: %{buffer: buf}} = state,
         cp,
         mods
       )
       when is_pid(buf) do
    # Swap active buffer to agent buffer
    real_active = state.buffers.active
    state = put_in(state.buffers.active, buf)

    # Run through the mode FSM
    state = Minga.Editor.do_handle_key(state, cp, mods)

    # Block mode transitions (buffer is read-only, navigation only)
    state =
      if state.mode != :normal do
        %{state | mode: :normal, mode_state: Minga.Mode.initial_state()}
      else
        state
      end

    # Restore the real active buffer
    put_in(state.buffers.active, real_active)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # File tree scope dispatch
  # ══════════════════════════════════════════════════════════════════════════

  @spec handle_file_tree_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

  defp handle_file_tree_key(state, cp, mods) do
    if key_sequence_pending?(state) do
      # Leader sequence or pending g/operator: delegate to mode FSM with
      # tree buffer so SPC w l, gg, etc. work.
      {:handled, delegate_to_mode_fsm_with_tree_buffer(state, cp, mods)}
    else
      key = {cp, mods}

      case Scope.resolve_key(:file_tree, :normal, key) do
        {:command, command} ->
          {:handled, Commands.execute(state, command)}

        {:prefix, _node} ->
          # File tree has no prefix sequences currently; swallow
          {:handled, state}

        :not_found ->
          # Delegate to mode FSM for vim navigation (j/k/gg/G/Ctrl-d/etc.)
          {:handled, delegate_to_mode_fsm_with_tree_buffer(state, cp, mods)}
      end
    end
  end

  @spec delegate_to_mode_fsm_with_tree_buffer(
          EditorState.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: EditorState.t()
  defp delegate_to_mode_fsm_with_tree_buffer(
         %{file_tree: %{buffer: buf}} = state,
         cp,
         mods
       )
       when is_pid(buf) do
    # Save the real active buffer, swap in the tree buffer
    real_active = state.buffers.active
    state = put_in(state.buffers.active, buf)

    # Run through the mode FSM (j, k, gg, G, Ctrl-d, Ctrl-u, /, etc.)
    state = Minga.Editor.do_handle_key(state, cp, mods)

    # Block mode transitions: force back to normal if mode FSM tried
    # to enter insert/visual/etc. (tree is read-only)
    state =
      if state.mode != :normal do
        %{state | mode: :normal, mode_state: Minga.Mode.initial_state()}
      else
        state
      end

    # Restore the real active buffer
    state = put_in(state.buffers.active, real_active)

    # If the tree was closed by the command (e.g. SPC o p toggle), skip sync
    if state.file_tree.tree == nil do
      state
    else
      sync_tree_cursor_from_buffer(state, buf)
    end
  end

  defp delegate_to_mode_fsm_with_tree_buffer(state, _cp, _mods), do: state

  # Read the buffer cursor line and update the tree cursor to match
  @spec sync_tree_cursor_from_buffer(EditorState.t(), pid()) :: EditorState.t()
  defp sync_tree_cursor_from_buffer(%{file_tree: %{tree: tree}} = state, buf) do
    {cursor_line, _col} = BufferServer.cursor(buf)
    entries = FileTree.visible_entries(tree)
    max_cursor = max(length(entries) - 1, 0)
    clamped = min(cursor_line, max_cursor)
    put_in(state.file_tree.tree, %{tree | cursor: clamped})
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Shared helpers
  # ══════════════════════════════════════════════════════════════════════════

  @spec key_sequence_pending?(EditorState.t()) :: boolean()
  defp key_sequence_pending?(%{mode_state: %{leader_node: node}}) when node != nil, do: true
  defp key_sequence_pending?(%{mode_state: %{pending_g: true}}), do: true
  defp key_sequence_pending?(%{mode: mode}) when mode in [:operator_pending, :command], do: true
  defp key_sequence_pending?(_state), do: false

  @spec update_agent(EditorState.t(), (AgentState.t() -> AgentState.t())) :: EditorState.t()
  defp update_agent(state, fun) do
    %{state | agent: fun.(state.agent)}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Mouse handling
  # ══════════════════════════════════════════════════════════════════════════

  @impl true
  @spec handle_mouse(
          EditorState.t(),
          integer(),
          integer(),
          atom(),
          non_neg_integer(),
          atom(),
          pos_integer()
        ) :: {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

  # Agentic view active: route to the agentic mouse handler.
  # It returns {:handled, state} for agent-owned regions (chat, input,
  # file viewer, separator) or {:passthrough, state} for shared chrome
  # (tab bar, modeline) so those flow to the editor mouse handler.
  def handle_mouse(%{agentic: %{active: true}} = state, row, col, button, mods, event_type, cc) do
    AgentViewMouse.handle(state, row, col, button, mods, event_type, cc)
  end

  # File tree: left click opens file/toggles dir, scroll wheel scrolls tree
  def handle_mouse(
        %{keymap_scope: :file_tree, file_tree: %{tree: %FileTree{} = tree}} = state,
        row,
        col,
        button,
        _mods,
        :press,
        click_count
      ) do
    layout = Layout.get(state)

    case layout.file_tree do
      nil ->
        {:passthrough, state}

      {ft_row, ft_col, ft_width, ft_height} ->
        if row >= ft_row and row < ft_row + ft_height and col >= ft_col and
             col < ft_col + ft_width do
          {:handled,
           handle_file_tree_click(state, tree, row, ft_row, ft_height, button, click_count)}
        else
          {:passthrough, state}
        end
    end
  end

  # All other scopes: pass through to the next handler
  def handle_mouse(state, _row, _col, _button, _mods, _event_type, _cc) do
    {:passthrough, state}
  end

  # ── File tree mouse helpers ──────────────────────────────────────────────

  @spec handle_file_tree_click(
          EditorState.t(),
          FileTree.t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          atom(),
          pos_integer()
        ) :: EditorState.t()
  defp handle_file_tree_click(state, tree, _row, _ft_row, _ft_height, button, _click_count)
       when button in [:wheel_up, :wheel_down] do
    # Scroll the tree cursor up/down by 3 entries
    delta = if button == :wheel_down, do: 3, else: -3
    entries = FileTree.visible_entries(tree)
    max_idx = max(length(entries) - 1, 0)
    new_cursor = (tree.cursor + delta) |> max(0) |> min(max_idx)
    new_tree = %{tree | cursor: new_cursor}

    put_in(state.file_tree.tree, new_tree)
  end

  defp handle_file_tree_click(state, tree, row, ft_row, ft_height, :left, click_count) do
    # Row 0 of the tree rect is the header. Entries start at row 1.
    content_rows = ft_height - 1
    screen_row = row - ft_row - 1

    if screen_row < 0 do
      state
    else
      # Compute scroll offset (same logic as TreeRenderer)
      scroll_offset = tree_scroll_offset(tree.cursor, content_rows)
      entry_idx = scroll_offset + screen_row
      entries = FileTree.visible_entries(tree)

      case Enum.at(entries, entry_idx) do
        nil ->
          state

        entry ->
          # Move tree cursor to clicked entry
          new_tree = %{tree | cursor: entry_idx}
          state = put_in(state.file_tree.tree, new_tree)

          # Single click: select. Double click (or single click on file): open
          handle_tree_entry_click(state, entry, click_count)
      end
    end
  end

  defp handle_file_tree_click(state, _tree, _row, _ft_row, _ft_height, _button, _cc), do: state

  @spec handle_tree_entry_click(EditorState.t(), FileTree.entry(), pos_integer()) ::
          EditorState.t()
  defp handle_tree_entry_click(state, %{dir?: true}, _click_count) do
    # Click on directory: toggle expand/collapse
    Commands.execute(state, :tree_toggle_directory)
  end

  defp handle_tree_entry_click(state, %{dir?: false}, _click_count) do
    # Click on file: open it (same as pressing Enter)
    Commands.execute(state, :tree_open_or_toggle)
  end

  @spec tree_scroll_offset(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp tree_scroll_offset(cursor, visible_rows) when visible_rows <= 0, do: cursor
  defp tree_scroll_offset(cursor, visible_rows) when cursor < visible_rows, do: 0
  defp tree_scroll_offset(cursor, visible_rows), do: cursor - visible_rows + 1

  # Checks if the cursor is within the lines of an expanded paste block.
  # Used to determine if Tab should trigger collapse.
  @spec cursor_on_expanded_block?(PanelState.t()) :: boolean()
  defp cursor_on_expanded_block?(%{
         input: %{cursor: {cursor_line, _}, lines: lines},
         pasted_blocks: blocks
       }) do
    blocks
    |> Enum.filter(& &1.expanded)
    |> Enum.any?(&expanded_block_spans_cursor?(&1, lines, cursor_line))
  end

  @spec expanded_block_spans_cursor?(PanelState.paste_block(), [String.t()], non_neg_integer()) ::
          boolean()
  defp expanded_block_spans_cursor?(block, lines, cursor_line) do
    text_lines = String.split(block.text, "\n")
    text_len = length(text_lines)
    max_start = length(lines) - text_len

    max_start >= 0 and
      Enum.any?(0..max_start//1, fn start ->
        Enum.slice(lines, start, text_len) == text_lines and
          cursor_line >= start and cursor_line < start + text_len
      end)
  end
end
