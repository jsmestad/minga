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
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.Commands
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Input.AgentPanel
  alias Minga.Input.Vim
  alias Minga.Keymap.Scope
  alias Minga.Port.Protocol
  alias Minga.Surface.AgentView

  @ctrl Protocol.mod_ctrl()
  @alt Protocol.mod_alt()
  @tab 9
  @space 32

  # ── Handler callback ───────────────────────────────────────────────────────

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

  # ── Editor scope ─────────────────────────────────────────────────────────

  # Editor scope with agent side panel: handled by Input.AgentPanel.
  # Editor scope (no panel): always passthrough to mode FSM.
  def handle_key(%{keymap_scope: :editor} = state, _cp, _mods) do
    {:passthrough, state}
  end

  # ── Agent scope ──────────────────────────────────────────────────────────

  # Agent scope: dispatch through scope resolution
  def handle_key(%{keymap_scope: :agent, surface_module: AgentView} = state, cp, mods) do
    handle_agent_key(state, cp, mods)
  end

  # Agent scope but surface not AgentView (race condition guard): passthrough
  def handle_key(%{keymap_scope: :agent} = state, _cp, _mods) do
    {:passthrough, state}
  end

  # File tree scope: handled by Input.FileTreeHandler.

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

  # Sub-state handlers (search, mention, approval, diff review) are now
  # separate Input.Handler modules in the surface handler list. They run
  # before Scoped in the focus stack walk. See Input.surface_handlers/0.

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
    # Try Vim first for ALL modes (handles arrow keys in insert, all keys
    # in normal/visual/operator-pending). Falls through to scope trie for
    # surface-specific keys (self-insert, Enter, Backspace, Ctrl combos).
    case Vim.handle_key(panel.vim, panel.input, cp, mods) do
      {:handled, new_vim, new_tf} ->
        new_panel = %{panel | vim: new_vim, input: new_tf}
        {:handled, %{state | agent: %{state.agent | panel: new_panel}}}

      :not_handled ->
        if PanelState.input_mode(panel) == :insert do
          resolve_agent_key(state, :insert, cp, mods)
        else
          {:handled, AgentPanel.dispatch_vim_key(state, cp, mods)}
        end
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

  # dispatch_vim_key extracted to Minga.Input.AgentPanel.dispatch_vim_key/3.

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

  # Tool approval and diff review sub-state handlers moved to
  # Minga.Input.ToolApproval and Minga.Input.DiffReview modules.

  # Agent side panel (editor scope) extracted to Minga.Input.AgentPanel.

  # File tree scope dispatch extracted to Minga.Input.FileTreeHandler.

  # ══════════════════════════════════════════════════════════════════════════
  # Shared helpers
  # ══════════════════════════════════════════════════════════════════════════

  # key_sequence_pending? and update_agent extracted to their respective
  # handler modules (AgentPanel, FileTreeHandler).

  # Mouse handling and file tree mouse helpers extracted to
  # Minga.Input.FileTreeHandler.

  # Checks if the cursor is within the lines of an expanded paste block.
  # Used by handle_agent_key for Tab handling on paste placeholder lines.
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
