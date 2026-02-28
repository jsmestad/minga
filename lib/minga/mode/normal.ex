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
  | `d`      | Enter operator-pending (delete)        |
  | `c`      | Enter operator-pending (change)        |
  | `y`      | Enter operator-pending (yank)          |
  | `p`      | Paste after cursor                     |
  | `P`      | Paste before cursor                    |
  | `w`      | Word forward                           |
  | `b`      | Word backward                          |
  | `e`      | Word end                               |
  | `$`      | Line end                               |
  | `^`      | First non-blank                        |
  | `G`      | Document end                           |
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

  # ── Visual mode entry ─────────────────────────────────────────────────────

  # v → characterwise visual mode.
  # The editor injects the :visual_anchor after the transition.
  def handle_key({?v, 0}, state) do
    {:transition, :visual, Map.put(state, :visual_type, :char)}
  end

  # V → linewise visual mode.
  def handle_key({?V, 0}, state) do
    {:transition, :visual, Map.put(state, :visual_type, :line)}
  end

  # ── Word / line motions ───────────────────────────────────────────────────

  def handle_key({?w, 0}, state) do
    {:execute, :word_forward, state}
  end

  def handle_key({?b, 0}, state) do
    {:execute, :word_backward, state}
  end

  def handle_key({?e, 0}, state) do
    {:execute, :word_end, state}
  end

  def handle_key({?$, 0}, state) do
    {:execute, :move_to_line_end, state}
  end

  def handle_key({?^, 0}, state) do
    {:execute, :move_to_first_non_blank, state}
  end

  def handle_key({?G, 0}, state) do
    {:execute, :move_to_document_end, state}
  end

  # ── Operator entry (d / c / y) ────────────────────────────────────────────

  def handle_key({?d, 0}, %{count: count} = state) do
    op_state = state |> Map.put(:operator, :delete) |> Map.put(:op_count, count || 1)
    {:transition, :operator_pending, op_state}
  end

  def handle_key({?c, 0}, %{count: count} = state) do
    op_state = state |> Map.put(:operator, :change) |> Map.put(:op_count, count || 1)
    {:transition, :operator_pending, op_state}
  end

  def handle_key({?y, 0}, %{count: count} = state) do
    op_state = state |> Map.put(:operator, :yank) |> Map.put(:op_count, count || 1)
    {:transition, :operator_pending, op_state}
  end

  # ── Paste ─────────────────────────────────────────────────────────────────

  def handle_key({?p, 0}, state) do
    {:execute, :paste_after, state}
  end

  def handle_key({?P, 0}, state) do
    {:execute, :paste_before, state}
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
