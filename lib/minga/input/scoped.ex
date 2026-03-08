defmodule Minga.Input.Scoped do
  @moduledoc """
  Scope-aware input handler that replaces per-view focus stack entries.

  Sits in the focus stack between modal overlays (picker, completion, conflict
  prompt) and the vim mode FSM fallback. Resolves keys through the active
  keymap scope, handling scope-specific bindings, prefix sequences, and
  sub-state dispatch (search input, mention completion).

  For the `:editor` scope, all keys pass through to the mode FSM (the scope
  returns `:not_found` for every key).

  For the `:agent` scope, keys are resolved against the agent scope trie.
  Context-dependent sub-states (search input, mention completion, tool
  approval, diff review) are handled before trie lookup. The leader key
  (SPC) always passes through to the mode FSM for which-key integration.

  For the `:file_tree` scope, tree-specific keys are handled and unmatched
  keys pass through to the mode FSM for vim navigation.
  """

  @behaviour Minga.Input.Handler

  import Bitwise

  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.Commands
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.State, as: EditorState
  alias Minga.Keymap.Scope
  alias Minga.Port.Protocol

  @ctrl Protocol.mod_ctrl()
  @space 32

  # ── Handler callback ───────────────────────────────────────────────────────

  @impl true
  @spec handle_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

  # Editor scope: always passthrough (let ModeFSM handle everything)
  def handle_key(%{keymap_scope: :editor} = state, _cp, _mods) do
    {:passthrough, state}
  end

  # Agent scope: dispatch through scope resolution
  def handle_key(%{keymap_scope: :agent, agentic: %{active: true}} = state, cp, mods) do
    handle_agent_key(state, cp, mods)
  end

  # Agent scope but not active (race condition guard): passthrough
  def handle_key(%{keymap_scope: :agent} = state, _cp, _mods) do
    {:passthrough, state}
  end

  # File tree scope: dispatch through scope resolution
  def handle_key(%{keymap_scope: :file_tree, file_tree: %{focused: true}} = state, cp, mods) do
    handle_file_tree_key(state, cp, mods)
  end

  # File tree scope but not focused: passthrough
  def handle_key(%{keymap_scope: :file_tree} = state, _cp, _mods) do
    {:passthrough, state}
  end

  # Unknown scope: passthrough
  def handle_key(state, _cp, _mods), do: {:passthrough, state}

  # ── Agent scope dispatch ───────────────────────────────────────────────────

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
  defp handle_agent_key(%{agent: %{panel: %{input_focused: true}}} = state, cp, mods) do
    resolve_agent_key(state, :insert, cp, mods)
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
             band(mods, 0x04) == 0 do
          handle_agent_self_insert(state, cp, mods)
        else
          # Not handled by scope, pass through to mode FSM / next handler
          {:handled, state}
        end
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

  # ── File tree scope dispatch ───────────────────────────────────────────────

  @spec handle_file_tree_key(EditorState.t(), non_neg_integer(), non_neg_integer()) ::
          {:handled, EditorState.t()} | {:passthrough, EditorState.t()}

  # Leader sequence in progress: delegate to mode FSM
  defp handle_file_tree_key(state, cp, mods) do
    if key_sequence_pending?(state) do
      {:passthrough, state}
    else
      key = {cp, mods}

      case Scope.resolve_key(:file_tree, :normal, key) do
        {:command, command} ->
          {:handled, Commands.execute(state, command)}

        {:prefix, _node} ->
          # File tree has no prefix sequences currently
          {:handled, state}

        :not_found ->
          # Delegate to mode FSM for vim navigation (j/k/gg/G/etc.)
          {:passthrough, state}
      end
    end
  end

  @spec key_sequence_pending?(EditorState.t()) :: boolean()
  defp key_sequence_pending?(%{mode_state: %{leader_node: node}}) when node != nil, do: true
  defp key_sequence_pending?(%{mode_state: %{pending_g: true}}), do: true
  defp key_sequence_pending?(%{mode: mode}) when mode in [:operator_pending, :command], do: true
  defp key_sequence_pending?(_state), do: false
end
