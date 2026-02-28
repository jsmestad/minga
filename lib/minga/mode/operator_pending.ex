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

  ## Text object keys

  After the operator, pressing `i` or `a` enters **text-object mode**:

  * `i` → inner (`:inner`) — stored in `:text_object_modifier`
  * `a` → around (`:around`) — stored in `:text_object_modifier`

  The next key then selects the text object:

  | Key | Object                              |
  |-----|-------------------------------------|
  | `w` | word (`iw` / `aw`)                  |
  | `"` | double-quoted string (`i"` / `a"`)  |
  | `'` | single-quoted string (`i'` / `a'`)  |
  | `(` or `)` | parentheses (`i(` / `a(`) |
  | `[` or `]` | brackets (`i[` / `a[`)   |
  | `{` or `}` | braces (`i{` / `a{`)     |

  The emitted command is `{:delete_text_object, modifier, spec}` (or
  `:change_text_object` / `:yank_text_object`), which the editor executes by
  calling the appropriate `Minga.TextObject` function.
  """

  @behaviour Minga.Mode

  import Bitwise

  alias Minga.Mode
  alias Minga.Mode.OperatorPendingState, as: OPState

  @escape 27
  @ctrl 0x02

  @impl Mode
  @doc """
  Handles a key in Operator-Pending mode.

  Returns a `t:Minga.Mode.result/0`.
  """
  @spec handle_key(Mode.key(), Mode.state()) :: Mode.result()

  # ── Text object modifier (i / a) ─────────────────────────────────────────

  # `i` enters "inner" text object mode — only when no modifier already set.
  def handle_key({?i, 0}, %OPState{text_object_modifier: nil} = state) do
    {:continue, %{state | text_object_modifier: :inner}}
  end

  # `a` enters "around" text object mode — only when no modifier already set.
  def handle_key({?a, 0}, %OPState{text_object_modifier: nil} = state) do
    {:continue, %{state | text_object_modifier: :around}}
  end

  # ── Text object completion ─────────────────────────────────────────────────
  #
  # These clauses match only when a text_object_modifier is pending.

  # `w` — word text object.
  def handle_key({?w, 0}, %OPState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] do
    execute_text_object(state, modifier, :word)
  end

  # `"` — double-quoted string.
  def handle_key({?", 0}, %OPState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] do
    execute_text_object(state, modifier, {:quote, "\""})
  end

  # `'` — single-quoted string.
  def handle_key({?', 0}, %OPState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] do
    execute_text_object(state, modifier, {:quote, "'"})
  end

  # `(` or `)` — parentheses.
  def handle_key({paren, 0}, %OPState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] and paren in [?(, ?)] do
    execute_text_object(state, modifier, {:paren, "(", ")"})
  end

  # `[` or `]` — square brackets.
  def handle_key({bracket, 0}, %OPState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] and bracket in [?[, ?]] do
    execute_text_object(state, modifier, {:paren, "[", "]"})
  end

  # `{` or `}` — curly braces.
  def handle_key({brace, 0}, %OPState{text_object_modifier: modifier} = state)
      when modifier in [:inner, :around] and brace in [?{, ?}] do
    execute_text_object(state, modifier, {:paren, "{", "}"})
  end

  # ── Count accumulation ───────────────────────────────────────────────────

  def handle_key({digit, 0}, %OPState{count: count} = state) when digit in ?1..?9 do
    digit_val = digit - ?0
    new_count = if count, do: count * 10 + digit_val, else: digit_val
    {:continue, %{state | count: new_count}}
  end

  # `0` with an in-progress count extends it; otherwise it's the line-start motion.
  def handle_key({?0, 0}, %OPState{count: count} = state) when is_integer(count) do
    {:continue, %{state | count: count * 10}}
  end

  def handle_key({?0, 0}, %OPState{} = state) do
    execute_with_motion(state, :line_start)
  end

  # ── Two-key g prefix (gg = document start) ───────────────────────────────

  def handle_key({?g, 0}, %OPState{pending_g: true} = state) do
    execute_with_motion(%{state | pending_g: false}, :document_start)
  end

  def handle_key({?g, 0}, %OPState{} = state) do
    {:continue, %{state | pending_g: true}}
  end

  # ── Word motions ─────────────────────────────────────────────────────────

  def handle_key({?w, 0}, %OPState{} = state) do
    execute_with_motion(state, :word_forward)
  end

  def handle_key({?b, 0}, %OPState{} = state) do
    execute_with_motion(state, :word_backward)
  end

  def handle_key({?e, 0}, %OPState{} = state) do
    execute_with_motion(state, :word_end)
  end

  # ── Line / document motions ───────────────────────────────────────────────

  def handle_key({?$, 0}, %OPState{} = state) do
    execute_with_motion(state, :line_end)
  end

  def handle_key({?^, 0}, %OPState{} = state) do
    execute_with_motion(state, :first_non_blank)
  end

  def handle_key({?G, 0}, %OPState{} = state) do
    execute_with_motion(state, :document_end)
  end

  # ── WORD motions ──────────────────────────────────────────────────────────

  def handle_key({?W, 0}, %OPState{} = state) do
    execute_with_motion(state, :word_forward_big)
  end

  def handle_key({?B, 0}, %OPState{} = state) do
    execute_with_motion(state, :word_backward_big)
  end

  def handle_key({?E, 0}, %OPState{} = state) do
    execute_with_motion(state, :word_end_big)
  end

  # ── Paragraph motions ─────────────────────────────────────────────────────

  def handle_key({?{, 0}, %OPState{} = state) do
    execute_with_motion(state, :paragraph_backward)
  end

  def handle_key({?}, 0}, %OPState{} = state) do
    execute_with_motion(state, :paragraph_forward)
  end

  # ── Bracket matching ──────────────────────────────────────────────────────

  def handle_key({?%, 0}, %OPState{} = state) do
    execute_with_motion(state, :match_bracket)
  end

  # ── Double-operator: line-wise variants (dd / cc / yy / >> / <<) ─────────

  def handle_key({?d, 0}, %OPState{operator: :delete} = state) do
    cmds = List.duplicate(:delete_line, OPState.total_count(state))
    {:execute_then_transition, cmds, :normal, OPState.to_base_state(state)}
  end

  def handle_key({?c, 0}, %OPState{operator: :change} = state) do
    cmds = List.duplicate(:change_line, OPState.total_count(state))
    {:execute_then_transition, cmds, :insert, OPState.to_base_state(state)}
  end

  def handle_key({?y, 0}, %OPState{operator: :yank} = state) do
    cmds = List.duplicate(:yank_line, OPState.total_count(state))
    {:execute_then_transition, cmds, :normal, OPState.to_base_state(state)}
  end

  # >> — indent current line(s): the count before > is the number of lines
  def handle_key({?>, 0}, %OPState{operator: :indent} = state) do
    {:execute_then_transition, [{:indent_lines, OPState.total_count(state)}], :normal,
     OPState.to_base_state(state)}
  end

  # << — dedent current line(s)
  def handle_key({?<, 0}, %OPState{operator: :dedent} = state) do
    {:execute_then_transition, [{:dedent_lines, OPState.total_count(state)}], :normal,
     OPState.to_base_state(state)}
  end

  # ── Page / half-page motions ───────────────────────────────────────────────

  def handle_key({?d, mods}, %OPState{} = state) when band(mods, @ctrl) != 0 do
    execute_with_motion(state, :half_page_down)
  end

  def handle_key({?u, mods}, %OPState{} = state) when band(mods, @ctrl) != 0 do
    execute_with_motion(state, :half_page_up)
  end

  def handle_key({?f, mods}, %OPState{} = state) when band(mods, @ctrl) != 0 do
    execute_with_motion(state, :page_down)
  end

  def handle_key({?b, mods}, %OPState{} = state) when band(mods, @ctrl) != 0 do
    execute_with_motion(state, :page_up)
  end

  # ── Escape: cancel back to Normal ────────────────────────────────────────

  def handle_key({@escape, _mods}, %OPState{} = state) do
    {:transition, :normal, OPState.to_base_state(state)}
  end

  # ── Unknown key: no-op ───────────────────────────────────────────────────

  def handle_key(_key, state) do
    {:continue, state}
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  # Emits a text-object command and transitions to the appropriate mode.
  @spec execute_text_object(OPState.t(), OPState.text_object_modifier(), term()) :: Mode.result()
  defp execute_text_object(%OPState{operator: operator} = state, modifier, object_spec) do
    cmd = text_object_command(operator, modifier, object_spec)
    target_mode = if operator == :change, do: :insert, else: :normal
    {:execute_then_transition, [cmd], target_mode, OPState.to_base_state(state)}
  end

  # Maps (operator, modifier, object_spec) → command tuple.
  @spec text_object_command(OPState.operator(), OPState.text_object_modifier(), term()) ::
          Mode.command()
  defp text_object_command(:delete, modifier, spec), do: {:delete_text_object, modifier, spec}
  defp text_object_command(:change, modifier, spec), do: {:change_text_object, modifier, spec}
  defp text_object_command(:yank, modifier, spec), do: {:yank_text_object, modifier, spec}

  # Build and emit the motion command, with correct repetition.
  @spec execute_with_motion(OPState.t(), atom()) :: Mode.result()
  defp execute_with_motion(%OPState{operator: operator} = state, motion) do
    cmd = motion_command(operator, motion)
    cmds = List.duplicate(cmd, OPState.total_count(state))
    target_mode = if operator == :change, do: :insert, else: :normal

    # We compute count ourselves — set count to nil so the dispatcher doesn't
    # double-multiply when processing {:execute_then_transition, ...}.
    {:execute_then_transition, cmds, target_mode, OPState.to_base_state(state)}
  end

  # Maps (operator, motion) → the command atom/tuple the editor expects.
  @spec motion_command(OPState.operator(), atom()) :: Mode.command()
  defp motion_command(:delete, motion), do: {:delete_motion, motion}
  defp motion_command(:change, motion), do: {:change_motion, motion}
  defp motion_command(:yank, motion), do: {:yank_motion, motion}
  defp motion_command(:indent, motion), do: {:indent_motion, motion}
  defp motion_command(:dedent, motion), do: {:dedent_motion, motion}
end
