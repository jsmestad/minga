defmodule Minga.Mode.OperatorPendingTest do
  use ExUnit.Case, async: true

  alias Minga.Mode
  alias Minga.Mode.OperatorPending
  alias Minga.Mode.OperatorPendingState

  # Build the FSM state as it would look after transitioning from Normal on `d`.
  defp op_state(operator, op_count \\ 1) do
    %OperatorPendingState{operator: operator, op_count: op_count}
  end

  # ── d + motion ─────────────────────────────────────────────────────────────

  describe "delete operator with motion" do
    test "d+w emits {:delete_motion, :word_forward} and transitions to :normal" do
      state = op_state(:delete)

      assert {:execute_then_transition, [{:delete_motion, :word_forward}], :normal, _} =
               OperatorPending.handle_key({?w, 0}, state)
    end

    test "d+b emits {:delete_motion, :word_backward} and transitions to :normal" do
      state = op_state(:delete)

      assert {:execute_then_transition, [{:delete_motion, :word_backward}], :normal, _} =
               OperatorPending.handle_key({?b, 0}, state)
    end

    test "d+e emits {:delete_motion, :word_end} and transitions to :normal" do
      state = op_state(:delete)

      assert {:execute_then_transition, [{:delete_motion, :word_end}], :normal, _} =
               OperatorPending.handle_key({?e, 0}, state)
    end

    test "d+0 emits {:delete_motion, :line_start} and transitions to :normal" do
      state = op_state(:delete)

      assert {:execute_then_transition, [{:delete_motion, :line_start}], :normal, _} =
               OperatorPending.handle_key({?0, 0}, state)
    end

    test "d+$ emits {:delete_motion, :line_end} and transitions to :normal" do
      state = op_state(:delete)

      assert {:execute_then_transition, [{:delete_motion, :line_end}], :normal, _} =
               OperatorPending.handle_key({?$, 0}, state)
    end

    test "d+G emits {:delete_motion, :document_end} and transitions to :normal" do
      state = op_state(:delete)

      assert {:execute_then_transition, [{:delete_motion, :document_end}], :normal, _} =
               OperatorPending.handle_key({?G, 0}, state)
    end

    test "d+g+g emits {:delete_motion, :document_start} and transitions to :normal" do
      state = op_state(:delete)
      {:continue, state2} = OperatorPending.handle_key({?g, 0}, state)

      assert {:execute_then_transition, [{:delete_motion, :document_start}], :normal, _} =
               OperatorPending.handle_key({?g, 0}, state2)
    end
  end

  # ── c + motion ─────────────────────────────────────────────────────────────

  describe "change operator with motion" do
    test "c+w emits {:change_motion, :word_forward} and transitions to :insert" do
      state = op_state(:change)

      assert {:execute_then_transition, [{:change_motion, :word_forward}], :insert, _} =
               OperatorPending.handle_key({?w, 0}, state)
    end

    test "c+e emits {:change_motion, :word_end} and transitions to :insert" do
      state = op_state(:change)

      assert {:execute_then_transition, [{:change_motion, :word_end}], :insert, _} =
               OperatorPending.handle_key({?e, 0}, state)
    end

    test "c+$ emits {:change_motion, :line_end} and transitions to :insert" do
      state = op_state(:change)

      assert {:execute_then_transition, [{:change_motion, :line_end}], :insert, _} =
               OperatorPending.handle_key({?$, 0}, state)
    end
  end

  # ── y + motion ─────────────────────────────────────────────────────────────

  describe "yank operator with motion" do
    test "y+w emits {:yank_motion, :word_forward} and transitions to :normal" do
      state = op_state(:yank)

      assert {:execute_then_transition, [{:yank_motion, :word_forward}], :normal, _} =
               OperatorPending.handle_key({?w, 0}, state)
    end

    test "y+b emits {:yank_motion, :word_backward} and transitions to :normal" do
      state = op_state(:yank)

      assert {:execute_then_transition, [{:yank_motion, :word_backward}], :normal, _} =
               OperatorPending.handle_key({?b, 0}, state)
    end
  end

  # ── Double-operator (line-wise) ────────────────────────────────────────────

  describe "dd (delete line)" do
    test "d+d emits :delete_line and transitions to :normal" do
      state = op_state(:delete)

      assert {:execute_then_transition, [:delete_line], :normal, _} =
               OperatorPending.handle_key({?d, 0}, state)
    end

    test "dd with op_count=3 emits 3 :delete_line commands" do
      state = op_state(:delete, 3)

      assert {:execute_then_transition, [:delete_line, :delete_line, :delete_line], :normal, _} =
               OperatorPending.handle_key({?d, 0}, state)
    end
  end

  describe "cc (change line)" do
    test "c+c emits :change_line and transitions to :insert" do
      state = op_state(:change)

      assert {:execute_then_transition, [:change_line], :insert, _} =
               OperatorPending.handle_key({?c, 0}, state)
    end
  end

  describe "yy (yank line)" do
    test "y+y emits :yank_line and transitions to :normal" do
      state = op_state(:yank)

      assert {:execute_then_transition, [:yank_line], :normal, _} =
               OperatorPending.handle_key({?y, 0}, state)
    end
  end

  # ── Escape cancels ─────────────────────────────────────────────────────────

  describe "Escape" do
    test "Escape transitions back to :normal" do
      state = op_state(:delete)
      assert {:transition, :normal, _} = OperatorPending.handle_key({27, 0}, state)
    end

    test "Escape returns base Mode.State without operator fields" do
      state = op_state(:delete)
      {:transition, :normal, new_state} = OperatorPending.handle_key({27, 0}, state)
      assert %Mode.State{} = new_state
    end
  end

  # ── Count accumulation ─────────────────────────────────────────────────────

  describe "count prefix inside operator-pending" do
    test "digit accumulates count" do
      state = op_state(:delete)
      {:continue, s2} = OperatorPending.handle_key({?3, 0}, state)
      assert s2.count == 3
    end

    test "two digits accumulate" do
      state = op_state(:delete)
      {:continue, s2} = OperatorPending.handle_key({?1, 0}, state)
      {:continue, s3} = OperatorPending.handle_key({?2, 0}, s2)
      assert s3.count == 12
    end

    test "0 after digit extends count" do
      state = op_state(:delete)
      {:continue, s2} = OperatorPending.handle_key({?1, 0}, state)
      {:continue, s3} = OperatorPending.handle_key({?0, 0}, s2)
      assert s3.count == 10
    end

    test "motion count multiplies op_count" do
      # op_count=2 (from `2d`), then press `3w` (motion count=3) → 6 commands
      state = %OperatorPendingState{operator: :delete, op_count: 2}
      {:continue, s2} = OperatorPending.handle_key({?3, 0}, state)

      assert {:execute_then_transition, cmds, :normal, _} =
               OperatorPending.handle_key({?w, 0}, s2)

      assert length(cmds) == 6
      assert Enum.all?(cmds, &(&1 == {:delete_motion, :word_forward}))
    end
  end

  # ── Mode.process integration ───────────────────────────────────────────────

  describe "integration via Mode.process/3" do
    test "d in normal transitions to operator_pending" do
      state = Mode.initial_state()
      {new_mode, _cmds, new_state} = Mode.process(:normal, {?d, 0}, state)
      assert new_mode == :operator_pending
      assert new_state.operator == :delete
    end

    test "c in normal transitions to operator_pending with :change" do
      state = Mode.initial_state()
      {new_mode, _cmds, new_state} = Mode.process(:normal, {?c, 0}, state)
      assert new_mode == :operator_pending
      assert new_state.operator == :change
    end

    test "y in normal transitions to operator_pending with :yank" do
      state = Mode.initial_state()
      {new_mode, _cmds, new_state} = Mode.process(:normal, {?y, 0}, state)
      assert new_mode == :operator_pending
      assert new_state.operator == :yank
    end

    test "d then w produces delete_motion command and normal mode" do
      state = Mode.initial_state()
      {op_mode, _, op_state} = Mode.process(:normal, {?d, 0}, state)
      assert op_mode == :operator_pending

      {new_mode, cmds, _} = Mode.process(:operator_pending, {?w, 0}, op_state)
      assert new_mode == :normal
      assert [{:delete_motion, :word_forward}] = cmds
    end

    test "d then d produces :delete_line command and normal mode" do
      state = Mode.initial_state()
      {_, _, op_state} = Mode.process(:normal, {?d, 0}, state)
      {new_mode, cmds, _} = Mode.process(:operator_pending, {?d, 0}, op_state)
      assert new_mode == :normal
      assert cmds == [:delete_line]
    end

    test "Escape from operator_pending returns to normal" do
      state = Mode.initial_state()
      {_, _, op_state} = Mode.process(:normal, {?d, 0}, state)
      {new_mode, cmds, _} = Mode.process(:operator_pending, {27, 0}, op_state)
      assert new_mode == :normal
      assert cmds == []
    end

    test "3d saves op_count and transitions" do
      state = Mode.initial_state()
      {_, _, s1} = Mode.process(:normal, {?3, 0}, state)
      {mode, _, op_state} = Mode.process(:normal, {?d, 0}, s1)
      assert mode == :operator_pending
      # op_count preserved (count was reset by reset_count, but op_count was saved first)
      assert op_state.op_count == 3
      assert op_state.count == nil
    end
  end

  # ── Unknown key ────────────────────────────────────────────────────────────

  describe "unknown key" do
    test "unknown key is a no-op continue" do
      state = op_state(:delete)
      assert {:continue, ^state} = OperatorPending.handle_key({?z, 0}, state)
    end
  end
end
