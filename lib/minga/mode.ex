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
  * `{:execute, command | [command], state}` — run commands, stay in same mode.
  * `{:execute_then_transition, [command], mode, state}` — run commands, then switch mode.
  """

  @typedoc "Available editor modes."
  @type mode ::
          :normal
          | :insert
          | :visual
          | :operator_pending
          | :command
          | :eval
          | :replace
          | :search
          | :search_prompt
          | :substitute_confirm

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

  @typedoc """
  Result returned by a mode's `handle_key/2`.

  * `{:continue, state}` — no-op.
  * `{:transition, mode, state}` — switch mode.
  * `{:execute, command | [command], state}` — execute and stay.
  * `{:execute_then_transition, [command], mode, state}` — execute then switch.
  """
  @type result ::
          {:continue, state()}
          | {:transition, mode(), state()}
          | {:execute, command() | [command()], state()}
          | {:execute_then_transition, [command()], mode(), state()}

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
    total = length(s.matches)
    "replace with #{s.replacement}? [y/n/a/q] (#{current} of #{total})"
  end

  def display(mode, _state), do: display(mode)

  # ── Private ──────────────────────────────────────────────────────────────────

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

  @spec apply_result(mode(), result()) :: {mode(), [command()], state()}
  defp apply_result(mode, {:continue, state}) do
    {mode, [], state}
  end

  defp apply_result(_mode, {:transition, new_mode, state}) do
    {new_mode, [], reset_count(state)}
  end

  defp apply_result(mode, {:execute, commands, state}) when is_list(commands) do
    count = state.count || 1
    expanded = List.duplicate(commands, count) |> List.flatten()
    {mode, expanded, reset_count(state)}
  end

  defp apply_result(mode, {:execute, command, state}) do
    apply_result(mode, {:execute, [command], state})
  end

  defp apply_result(_mode, {:execute_then_transition, commands, new_mode, state}) do
    {new_mode, commands, reset_count(state)}
  end

  @spec reset_count(state()) :: state()
  defp reset_count(%_{} = state), do: %{state | count: nil}
end
