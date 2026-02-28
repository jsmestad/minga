defmodule Minga.Mode.OperatorPending do
  @moduledoc """
  Operator-Pending mode — entered when `d`, `c`, or `y` is pressed in Normal mode.

  The mode waits for a **motion key** (or the operator repeated for a
  line-wise variant) and then emits the appropriate command tuple that the
  editor can execute via `Minga.Operator`.

  ## State keys added by this mode

  In addition to the standard `:count` key from `Minga.Mode.state/0`, the
  FSM state carries:

  * `:operator` — `:delete | :change | :yank` — the pending operator.
  * `:op_count` — `pos_integer()` — count accumulated *before* the operator
    key was pressed (e.g. the `3` in `3dw`).  Defaults to `1`.
  * `:pending_g` — `boolean()` — `true` while waiting for the second `g` of a
    `gg` (document-start) sequence.

  ## Emitted commands

  | Key sequence | Command(s)                               |
  |--------------|------------------------------------------|
  | `dw`         | `{:delete_motion, :word_forward}`        |
  | `db`         | `{:delete_motion, :word_backward}`       |
  | `de`         | `{:delete_motion, :word_end}`            |
  | `d0`         | `{:delete_motion, :line_start}`          |
  | `d$`         | `{:delete_motion, :line_end}`            |
  | `dgg`        | `{:delete_motion, :document_start}`      |
  | `dG`         | `{:delete_motion, :document_end}`        |
  | `dd`         | `:delete_line`                           |
  | `cw`         | `{:change_motion, :word_forward}`        |
  | `cc`         | `:change_line`                           |
  | `yw`         | `{:yank_motion, :word_forward}`          |
  | `yy`         | `:yank_line`                             |

  The `c*` variants transition to `:insert` mode; all others return to `:normal`.

  ## Count semantics

  `3dw` — the count `3` is saved as `:op_count` when Normal mode transitions
  here; after the motion `w` is pressed, the total repeat count is
  `op_count × (motion count || 1)`, and that many command copies are emitted.

  `d3w` — the `3` is accumulated as the ordinary `:count` in this mode;
  the same multiplication applies.
  """

  @behaviour Minga.Mode

  alias Minga.Mode

  @typedoc "The pending operator."
  @type operator :: :delete | :change | :yank

  @escape 27

  @impl Mode
  @doc """
  Handles a key in Operator-Pending mode.

  Returns a `t:Minga.Mode.result/0`.
  """
  @spec handle_key(Mode.key(), Mode.state()) :: Mode.result()

  # ── Count accumulation ───────────────────────────────────────────────────

  def handle_key({digit, 0}, %{count: count} = state) when digit in ?1..?9 do
    digit_val = digit - ?0
    new_count = if count, do: count * 10 + digit_val, else: digit_val
    {:continue, %{state | count: new_count}}
  end

  # `0` with an in-progress count extends it; otherwise it's the line-start motion.
  def handle_key({?0, 0}, %{count: count} = state) when is_integer(count) do
    {:continue, %{state | count: count * 10}}
  end

  def handle_key({?0, 0}, state) do
    execute_with_motion(state, :line_start)
  end

  # ── Two-key g prefix (gg = document start) ───────────────────────────────

  def handle_key({?g, 0}, %{pending_g: true} = state) do
    execute_with_motion(%{state | pending_g: false}, :document_start)
  end

  def handle_key({?g, 0}, state) do
    {:continue, Map.put(state, :pending_g, true)}
  end

  # ── Word motions ─────────────────────────────────────────────────────────

  def handle_key({?w, 0}, state) do
    execute_with_motion(state, :word_forward)
  end

  def handle_key({?b, 0}, state) do
    execute_with_motion(state, :word_backward)
  end

  def handle_key({?e, 0}, state) do
    execute_with_motion(state, :word_end)
  end

  # ── Line / document motions ───────────────────────────────────────────────

  def handle_key({?$, 0}, state) do
    execute_with_motion(state, :line_end)
  end

  def handle_key({?G, 0}, state) do
    execute_with_motion(state, :document_end)
  end

  # ── Double-operator: line-wise variants (dd / cc / yy) ───────────────────

  def handle_key({?d, 0}, %{operator: :delete} = state) do
    cmds = List.duplicate(:delete_line, total_count(state))
    {:execute_then_transition, cmds, :normal, clear_op_state(state)}
  end

  def handle_key({?c, 0}, %{operator: :change} = state) do
    cmds = List.duplicate(:change_line, total_count(state))
    {:execute_then_transition, cmds, :insert, clear_op_state(state)}
  end

  def handle_key({?y, 0}, %{operator: :yank} = state) do
    cmds = List.duplicate(:yank_line, total_count(state))
    {:execute_then_transition, cmds, :normal, clear_op_state(state)}
  end

  # ── Escape: cancel back to Normal ────────────────────────────────────────

  def handle_key({@escape, _mods}, state) do
    {:transition, :normal, clear_op_state(state)}
  end

  # ── Unknown key: no-op ───────────────────────────────────────────────────

  def handle_key(_key, state) do
    {:continue, state}
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  # Build and emit the motion command, with correct repetition.
  @spec execute_with_motion(Mode.state(), atom()) :: Mode.result()
  defp execute_with_motion(%{operator: operator} = state, motion) do
    cmd = motion_command(operator, motion)
    cmds = List.duplicate(cmd, total_count(state))
    target_mode = if operator == :change, do: :insert, else: :normal

    # We compute count ourselves — set count to nil so the dispatcher doesn't
    # double-multiply when processing {:execute_then_transition, ...}.
    {:execute_then_transition, cmds, target_mode, clear_op_state(state)}
  end

  # Maps (operator, motion) → the command atom/tuple the editor expects.
  @spec motion_command(operator(), atom()) :: Mode.command()
  defp motion_command(:delete, motion), do: {:delete_motion, motion}
  defp motion_command(:change, motion), do: {:change_motion, motion}
  defp motion_command(:yank, motion), do: {:yank_motion, motion}

  # Total repeat count: op_count (from before the operator key) × motion count.
  @spec total_count(Mode.state()) :: pos_integer()
  defp total_count(state) do
    op_count = Map.get(state, :op_count, 1)
    motion_count = state.count || 1
    op_count * motion_count
  end

  # Strips operator-specific keys from the FSM state and resets count.
  @spec clear_op_state(Mode.state()) :: Mode.state()
  defp clear_op_state(state) do
    state
    |> Map.delete(:operator)
    |> Map.delete(:op_count)
    |> Map.delete(:pending_g)
    |> Map.put(:count, nil)
  end
end
