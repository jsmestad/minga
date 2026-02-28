defmodule Minga.Mode.Normal do
  @moduledoc """
  Vim Normal mode key handler.

  In Normal mode, keys are interpreted as commands — motions, operators, or
  keys that enter other modes. Digit keys `1`–`9` (and `0` after a count has
  started) accumulate a repeat count stored in the FSM state. The accumulated
  count is applied by the `Minga.Mode` dispatcher when an `:execute` result
  is returned.

  ## Supported keys

  | Key      | Action                                 |
  |----------|----------------------------------------|
  | `i`      | Transition to Insert mode              |
  | `a`      | Move right, transition to Insert       |
  | `A`      | Move to line end, transition to Insert |
  | `I`      | Move to line start, transition to Insert |
  | `o`      | Insert line below, transition to Insert |
  | `O`      | Insert line above, transition to Insert |
  | `h`      | Move left                              |
  | `j`      | Move down                              |
  | `k`      | Move up                                |
  | `l`      | Move right                             |
  | `0`      | Move to line start (when no count) or continue count |
  | `1`–`9`  | Accumulate count prefix                |
  | `Escape` | Clear count prefix (already normal)    |
  | Arrow keys | Move in corresponding direction     |
  """

  @behaviour Minga.Mode

  alias Minga.Mode

  # Special codepoints
  @escape 27

  # Arrow key codepoints sent by libvaxis
  @arrow_up 57416
  @arrow_down 57424
  @arrow_left 57419
  @arrow_right 57421

  @impl Mode
  @doc """
  Handles a key event in Normal mode.

  Returns a `t:Minga.Mode.result/0` indicating the FSM transition and
  any commands to execute.
  """
  @spec handle_key(Mode.key(), Mode.state()) :: Mode.result()

  # ── Count prefix accumulation ─────────────────────────────────────────────

  # Digits 1-9 always start or extend the count.
  def handle_key({digit, 0}, %{count: count} = state)
      when digit in ?1..?9 do
    digit_value = digit - ?0
    new_count = if count, do: count * 10 + digit_value, else: digit_value
    {:continue, %{state | count: new_count}}
  end

  # `0` continues an in-progress count; otherwise it's the "go to line start" motion.
  def handle_key({?0, 0}, %{count: count} = state) when is_integer(count) do
    {:continue, %{state | count: count * 10}}
  end

  def handle_key({?0, 0}, state) do
    {:execute, :move_to_line_start, state}
  end

  # ── Mode transitions ──────────────────────────────────────────────────────

  def handle_key({?i, 0}, state) do
    {:transition, :insert, state}
  end

  def handle_key({?a, 0}, state) do
    {:execute_then_transition, [:move_right], :insert, state}
  end

  def handle_key({?A, 0}, state) do
    {:execute_then_transition, [:move_to_line_end], :insert, state}
  end

  def handle_key({?I, 0}, state) do
    {:execute_then_transition, [:move_to_line_start], :insert, state}
  end

  def handle_key({?o, 0}, state) do
    {:execute_then_transition, [:insert_line_below], :insert, state}
  end

  def handle_key({?O, 0}, state) do
    {:execute_then_transition, [:insert_line_above], :insert, state}
  end

  # ── Movements ─────────────────────────────────────────────────────────────

  def handle_key({?h, 0}, state) do
    {:execute, :move_left, state}
  end

  def handle_key({?j, 0}, state) do
    {:execute, :move_down, state}
  end

  def handle_key({?k, 0}, state) do
    {:execute, :move_up, state}
  end

  def handle_key({?l, 0}, state) do
    {:execute, :move_right, state}
  end

  # Arrow keys
  def handle_key({@arrow_up, _mods}, state) do
    {:execute, :move_up, state}
  end

  def handle_key({@arrow_down, _mods}, state) do
    {:execute, :move_down, state}
  end

  def handle_key({@arrow_left, _mods}, state) do
    {:execute, :move_left, state}
  end

  def handle_key({@arrow_right, _mods}, state) do
    {:execute, :move_right, state}
  end

  # ── Escape: already in Normal, just clear any pending count ──────────────

  def handle_key({@escape, _mods}, state) do
    {:continue, %{state | count: nil}}
  end

  # ── Unknown key: no-op ───────────────────────────────────────────────────

  def handle_key(_key, state) do
    {:continue, state}
  end
end
