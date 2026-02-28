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
  @type mode :: :normal | :insert | :visual | :operator_pending | :command

  @typedoc """
  A command to execute. Either a bare atom (e.g. `:move_left`) or a
  tagged tuple carrying an argument (e.g. `{:insert_char, \"x\"}`).
  """
  @type command :: atom() | {atom(), term()} | {atom(), term(), term()}

  @typedoc """
  FSM-level state. Always contains `:count` (the accumulated digit prefix).
  Mode modules may add additional keys for their own bookkeeping.
  """
  @type state :: %{:count => non_neg_integer() | nil, optional(atom()) => term()}

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
  @spec initial_state() :: state()
  def initial_state, do: %{count: nil, leader_node: nil, leader_keys: []}

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

  @doc """
  Returns the status-line label for a mode, using the FSM state for
  additional context. Currently used to distinguish `-- VISUAL --` from
  `-- VISUAL LINE --` based on `:visual_type` in the state.
  """
  @spec display(mode(), state()) :: String.t()
  def display(:visual, %{visual_type: :line}), do: "-- VISUAL LINE --"
  def display(:command, %{input: input}) when is_binary(input), do: ":" <> input
  def display(mode, _state), do: display(mode)

  # ── Private ──────────────────────────────────────────────────────────────────

  @spec mode_module(mode()) :: module()
  defp mode_module(:normal), do: Minga.Mode.Normal
  defp mode_module(:insert), do: Minga.Mode.Insert
  defp mode_module(:visual), do: Minga.Mode.Visual
  defp mode_module(:operator_pending), do: Minga.Mode.OperatorPending
  defp mode_module(:command), do: Minga.Mode.Command

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
  defp reset_count(state), do: %{state | count: nil}
end
