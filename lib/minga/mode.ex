defmodule Minga.Mode do
  @moduledoc """
  Vim modal FSM behaviour and central dispatcher.

  Defines the `Mode` behaviour that each mode module must implement,
  and provides `process/3` as the entry point for the editor. It:

    1. Delegates key events to the appropriate mode module.
    2. Handles count-prefix accumulation (e.g. `3j` → move down 3 times).
    3. Returns `{new_mode, commands, new_fsm_state}` for the editor to act on.

  ## Count prefix

  In Normal mode, pressing digit keys accumulates a repeat count stored in
  the FSM state. The next `:execute` result's commands are repeated that many
  times before the count is reset. Count does **not** multiply
  `:execute_then_transition` commands, because mode-entry keys like `a` or `i`
  do not sensibly repeat in Vim.

  ## Result contract

  Each mode module's `handle_key/2` returns one of:

  * `{:continue, state}` — no-op; remain in the same mode.
  * `{:transition, mode, state}` — switch to `mode`, no commands.
  * `{:execute, command | [command], state}` — run commands, stay in same mode, and repeat them by the accumulated count.
  * `{:execute, command | [command], state, count_policy}` — run commands with explicit count handling.
  * `{:execute_then_transition, [command], mode, state}` — run commands, then switch mode.
  """

  @typedoc "Available editor modes."
  @type mode ::
          :normal
          | :insert
          | :visual
          | :visual_line
          | :visual_block
          | :operator_pending
          | :command
          | :eval
          | :replace
          | :search
          | :search_prompt
          | :substitute_confirm
          | :extension_confirm
          | :tool_confirm
          | :delete_confirm
          | :branch_delete_confirm

  @typedoc """
  A command to execute. Either a bare atom (e.g. `:move_left`) or a
  tagged tuple carrying an argument (e.g. `{:insert_char, \"x\"}`).
  """
  @type command ::
          atom() | {atom(), term()} | {atom(), term(), term()} | {atom(), term(), term(), term()}

  @typedoc """
  FSM-level state. The base `Mode.State` struct carries shared fields (count,
  leader). Mode-specific structs (`VisualState`, `CommandState`, etc.) extend
  this with their own fields.
  """
  @type state ::
          Minga.Mode.State.t()
          | Minga.Mode.OperatorPendingState.t()
          | Minga.Mode.VisualState.t()
          | Minga.Mode.CommandState.t()
          | Minga.Mode.EvalState.t()
          | Minga.Mode.ReplaceState.t()
          | Minga.Mode.SearchState.t()
          | Minga.Mode.SearchPromptState.t()
          | Minga.Mode.SubstituteConfirmState.t()
          | Minga.Mode.ExtensionConfirmState.t()
          | Minga.Mode.ToolConfirmState.t()
          | Minga.Mode.DeleteConfirmState.t()
          | Minga.Mode.BranchDeleteConfirmState.t()

  @typedoc """
  Result returned by a mode's `handle_key/2`.

  * `{:continue, state}` — no-op.
  * `{:transition, mode, state}` — switch mode.
  * `{:execute, command | [command], state}` — execute and stay, repeating by the accumulated count.
  * `{:execute, command | [command], state, count_policy}` — execute and stay with explicit count handling.
  * `{:execute_then_transition, [command], mode, state}` — execute then switch.
  """
  @type result ::
          {:continue, state()}
          | {:transition, mode(), state()}
          | {:execute, command() | [command()], state()}
          | {:execute, command() | [command()], state(), count_policy()}
          | {:execute_then_transition, [command()], mode(), state()}

  @typedoc "How an execute result handles an accumulated count prefix."
  @type count_policy :: :repeat_count | :discard_count

  @typedoc "A key event: `{codepoint, modifiers}`."
  @type key :: {non_neg_integer(), non_neg_integer()}

  # ── Behaviour ────────────────────────────────────────────────────────────────

  @doc """
  Handle a key event for this mode.

  `key` is a `{codepoint, modifiers}` tuple. `state` is the current FSM state.
  Returns a `t:result/0` describing what the editor should do next.
  """
  @callback handle_key(key(), state()) :: result()

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Returns a fresh FSM state with no accumulated count and no leader sequence.
  """
  @spec initial_state() :: Minga.Mode.State.t()
  def initial_state, do: %Minga.Mode.State{}

  @doc """
  Processes a key event for the given `mode`.

  Returns `{new_mode, commands, new_state}`. `commands` is the (possibly
  empty, possibly repeated) list of commands the editor should execute.
  """
  @spec process(mode(), key(), state()) :: {mode(), [command()], state()}
  def process(mode, key, state) do
    module = mode_module(mode)
    result = module.handle_key(key, state)
    apply_result(mode, result)
  end

  @doc """
  Returns the status-line label for the given mode.
  """
  @spec display(mode()) :: String.t()
  def display(:normal), do: "-- NORMAL --"
  def display(:insert), do: "-- INSERT --"
  def display(:visual), do: "-- VISUAL --"
  def display(:operator_pending), do: "-- OPERATOR --"
  def display(:command), do: "-- COMMAND --"
  def display(:replace), do: "-- REPLACE --"
  def display(:search), do: "-- SEARCH --"
  def display(:search_prompt), do: "-- SEARCH PROJECT --"
  def display(:eval), do: "-- EVAL --"
  def display(:substitute_confirm), do: "-- SUBSTITUTE --"
  def display(:extension_confirm), do: "-- UPDATE --"
  def display(:tool_confirm), do: "-- INSTALL? --"
  def display(:delete_confirm), do: "-- DELETE? --"
  def display(:branch_delete_confirm), do: "-- DELETE BRANCH? --"

  @doc """
  Returns the status-line label for a mode, using the FSM state for
  additional context. Currently used to distinguish `-- VISUAL --` from
  `-- VISUAL LINE --` based on `:visual_type` in the state.
  """
  @spec display(mode(), state()) :: String.t()
  def display(:visual, %Minga.Mode.VisualState{visual_type: :line}), do: "-- VISUAL LINE --"
  def display(:command, %Minga.Mode.CommandState{input: input}), do: ":" <> input
  def display(:eval, %Minga.Mode.EvalState{input: input}), do: "Eval: " <> input

  def display(:search, %Minga.Mode.SearchState{direction: dir, input: input}) do
    prefix = if dir == :forward, do: "/", else: "?"
    prefix <> input
  end

  def display(:search_prompt, %Minga.Mode.SearchPromptState{input: input}) do
    "Search: " <> input
  end

  def display(:substitute_confirm, %Minga.Mode.SubstituteConfirmState{} = s) do
    current = s.current + 1
    total = Enum.count(s.matches)
    "replace with #{s.replacement}? [y/n/a/q] (#{current} of #{total})"
  end

  def display(:extension_confirm, %Minga.Mode.ExtensionConfirmState{} = s) do
    current = s.current + 1
    total = Enum.count(s.updates)
    update = Enum.at(s.updates, s.current)
    label = format_update_label(update)
    "#{label} [Y/n/d] (#{current} of #{total})"
  end

  def display(:tool_confirm, %Minga.Mode.ToolConfirmState{} = s) do
    name = Enum.at(s.pending, s.current)
    label = tool_label(name)
    "#{label} not found. Install? [y/n]"
  end

  def display(:delete_confirm, %Minga.Mode.DeleteConfirmState{phase: :trash} = s) do
    if s.dir? do
      "Delete '#{s.name}/' and #{s.child_count} files? (y/n)"
    else
      "Delete '#{s.name}'? (y/n)"
    end
  end

  def display(:delete_confirm, %Minga.Mode.DeleteConfirmState{phase: :permanent} = s) do
    "Cannot trash. Permanently delete '#{s.name}'? (y/n)"
  end

  def display(:branch_delete_confirm, %Minga.Mode.BranchDeleteConfirmState{phase: :delete} = s) do
    "Delete branch #{s.name}? (y/n)"
  end

  def display(:branch_delete_confirm, %Minga.Mode.BranchDeleteConfirmState{phase: :force} = s) do
    "Force delete branch #{s.name}? (y/n)"
  end

  def display(mode, _state), do: display(mode)

  @doc """
  Returns the pending-key echo string (vim `showcmd`) for the current FSM state.

  This is the sequence of keys the user has typed that have not yet resolved
  into a command: an accumulated count, a pending single-key operation (`"`, `r`,
  `f`/`F`/`t`/`T`, `m`, `'`, `` ` ``, `q`, `@`), a normal-mode prefix (`g`, `z`,
  `[`, `]`), a leader sequence, or a pending operator (`d`, `c`, `y`, ...).
  Returns `""` when nothing is pending. Pure over `mode` and `mode_state`;
  callers layer on register and which-key state.
  """
  @spec pending_keys(mode(), state()) :: String.t()
  def pending_keys(:operator_pending, %Minga.Mode.OperatorPendingState{} = s) do
    op_count = if s.op_count > 1, do: Integer.to_string(s.op_count), else: ""
    count = if s.count, do: Integer.to_string(s.count), else: ""
    g = if s.pending_g, do: "g", else: ""
    # count precedes the g prefix in typed order: `d2g` (of `d2gg`) accumulates
    # count 2 before g sets pending_g, and no count can follow g (the next key
    # after g always resolves).
    op_count <> operator_key(s.operator) <> count <> g
  end

  def pending_keys(_mode, %Minga.Mode.State{} = s) do
    count = if s.count, do: Integer.to_string(s.count), else: ""
    prefix = s.prefix_keys |> Enum.reverse() |> Enum.join()
    leader = s.leader_keys |> Enum.reverse() |> Enum.join(" ")
    count <> prefix <> leader <> pending_key(s.pending)
  end

  # Visual, command, search, and the other mode-state structs intentionally
  # fall through with no echo: only base State and OperatorPendingState carry
  # showcmd-relevant keys today. A mode struct that later gains counts or
  # prefixes (VisualState already reserves a count field) needs its own clause.
  def pending_keys(_mode, _state), do: ""

  # ── Private ──────────────────────────────────────────────────────────────────

  @spec operator_key(Minga.Mode.OperatorPendingState.operator()) :: String.t()
  defp operator_key(:delete), do: "d"
  defp operator_key(:change), do: "c"
  defp operator_key(:yank), do: "y"
  defp operator_key(:indent), do: ">"
  defp operator_key(:dedent), do: "<"
  defp operator_key(:reindent), do: "="
  defp operator_key(:comment), do: "gc"
  defp operator_key(_operator), do: ""

  @spec pending_key(Minga.Mode.State.pending()) :: String.t()
  defp pending_key(:register), do: "\""
  defp pending_key(:replace), do: "r"
  defp pending_key({:find, dir}), do: Atom.to_string(dir)
  defp pending_key({:mark, :set}), do: "m"
  defp pending_key({:mark, :jump_line}), do: "'"
  defp pending_key({:mark, :jump_exact}), do: "`"
  defp pending_key(:macro_register), do: "q"
  defp pending_key(:macro_replay), do: "@"
  # Catch-all (covers nil) so a future pending variant degrades to no echo
  # instead of raising in status-bar construction, matching operator_key/1.
  defp pending_key(_pending), do: ""

  @spec mode_module(mode()) :: module()
  defp mode_module(:normal), do: Minga.Mode.Normal
  defp mode_module(:insert), do: Minga.Mode.Insert
  defp mode_module(:visual), do: Minga.Mode.Visual
  defp mode_module(:operator_pending), do: Minga.Mode.OperatorPending
  defp mode_module(:command), do: Minga.Mode.Command
  defp mode_module(:eval), do: Minga.Mode.Eval
  defp mode_module(:replace), do: Minga.Mode.Replace
  defp mode_module(:search), do: Minga.Mode.Search
  defp mode_module(:search_prompt), do: Minga.Mode.SearchPrompt
  defp mode_module(:substitute_confirm), do: Minga.Mode.SubstituteConfirm
  defp mode_module(:extension_confirm), do: Minga.Mode.ExtensionConfirm
  defp mode_module(:tool_confirm), do: Minga.Mode.ToolConfirm
  defp mode_module(:delete_confirm), do: Minga.Mode.DeleteConfirm
  defp mode_module(:branch_delete_confirm), do: Minga.Mode.BranchDeleteConfirm

  @spec apply_result(mode(), result()) :: {mode(), [command()], state()}
  defp apply_result(mode, {:continue, state}) do
    {mode, [], state}
  end

  defp apply_result(_mode, {:transition, new_mode, state}) do
    {new_mode, [], reset_count(state)}
  end

  defp apply_result(mode, {:execute, commands, state}) do
    apply_result(mode, {:execute, commands, state, :repeat_count})
  end

  defp apply_result(mode, {:execute, commands, state, :repeat_count}) when is_list(commands) do
    count = state.count || 1
    expanded = List.duplicate(commands, count) |> List.flatten()
    {mode, expanded, reset_count(state)}
  end

  defp apply_result(mode, {:execute, commands, state, :discard_count}) when is_list(commands) do
    {mode, commands, reset_count(state)}
  end

  defp apply_result(mode, {:execute, command, state, count_policy}) do
    apply_result(mode, {:execute, [command], state, count_policy})
  end

  defp apply_result(_mode, {:execute_then_transition, commands, new_mode, state}) do
    {new_mode, commands, reset_count(state)}
  end

  @spec reset_count(state()) :: state()
  defp reset_count(%_{} = state), do: %{state | count: nil}

  @spec tool_label(atom()) :: String.t()
  defp tool_label(name) do
    case Minga.Tool.Recipe.Registry.get(name) do
      nil -> Atom.to_string(name)
      recipe -> recipe.label
    end
  end

  @spec format_update_label(Minga.Mode.ExtensionConfirmState.update_entry()) :: String.t()
  defp format_update_label(%{pinned: true, name: name}) do
    "#{name}: pinned, skipped"
  end

  defp format_update_label(%{source_type: :git} = u) do
    "#{u.name}: #{u.old_ref} → #{u.new_ref} (#{u.commit_count} commits on #{u.branch})"
  end

  defp format_update_label(%{source_type: :hex} = u) do
    "#{u.name}: #{u.old_ref} → #{u.new_ref}"
  end
end
