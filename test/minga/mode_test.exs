defmodule Minga.ModeTest do
  use ExUnit.Case, async: true

  alias Minga.Mode

  describe "initial_state/0" do
    test "returns a map with nil count and empty leader state" do
      state = Mode.initial_state()
      assert state.count == nil
      assert state.leader_node == nil
      assert state.leader_keys == []
    end
  end

  describe "display/1" do
    test "returns correct label for normal mode" do
      assert Mode.display(:normal) == "-- NORMAL --"
    end

    test "returns correct label for insert mode" do
      assert Mode.display(:insert) == "-- INSERT --"
    end

    test "returns correct label for visual mode" do
      assert Mode.display(:visual) == "-- VISUAL --"
    end

    test "returns correct label for operator_pending mode" do
      assert Mode.display(:operator_pending) == "-- OPERATOR --"
    end

    test "returns correct label for command mode" do
      assert Mode.display(:command) == "-- COMMAND --"
    end
  end

  describe "pending_keys/2 (showcmd)" do
    alias Minga.Mode.OperatorPendingState
    alias Minga.Mode.State

    test "returns empty string when nothing is pending" do
      assert Mode.pending_keys(:normal, %State{}) == ""
    end

    test "echoes an accumulated count" do
      assert Mode.pending_keys(:normal, %State{count: 12}) == "12"
    end

    test "echoes a pending register prefix" do
      assert Mode.pending_keys(:normal, %State{pending: :register}) == "\""
    end

    test "echoes pending single-key operations" do
      assert Mode.pending_keys(:normal, %State{pending: :replace}) == "r"
      assert Mode.pending_keys(:normal, %State{pending: {:find, :f}}) == "f"
      assert Mode.pending_keys(:normal, %State{pending: {:find, :T}}) == "T"
      assert Mode.pending_keys(:normal, %State{pending: {:mark, :set}}) == "m"
      assert Mode.pending_keys(:normal, %State{pending: :macro_register}) == "q"
      assert Mode.pending_keys(:normal, %State{pending: :macro_replay}) == "@"
    end

    test "echoes a normal-mode prefix (g/z/[/]) in typed order" do
      assert Mode.pending_keys(:normal, %State{prefix_keys: ["g"]}) == "g"
      assert Mode.pending_keys(:normal, %State{prefix_keys: ["r", "g"]}) == "gr"
    end

    test "echoes a leader sequence in typed order" do
      assert Mode.pending_keys(:normal, %State{leader_keys: ["f", "SPC"]}) == "SPC f"
    end

    test "combines a count with a pending operation" do
      assert Mode.pending_keys(:normal, %State{count: 2, pending: {:find, :f}}) == "2f"
    end

    test "echoes a pending operator in operator-pending mode" do
      state = %OperatorPendingState{operator: :delete}
      assert Mode.pending_keys(:operator_pending, state) == "d"
    end

    test "echoes operator count prefix and motion count" do
      state = %OperatorPendingState{operator: :change, op_count: 2, count: 3}
      assert Mode.pending_keys(:operator_pending, state) == "2c3"
    end

    test "maps each operator to its key" do
      for {op, key} <- [delete: "d", change: "c", yank: "y", indent: ">", dedent: "<"] do
        state = %OperatorPendingState{operator: op}
        assert Mode.pending_keys(:operator_pending, state) == key
      end
    end

    test "returns empty string for modes without base FSM state" do
      assert Mode.pending_keys(:insert, nil) == ""
    end
  end

  describe "process/3 — Normal mode transitions" do
    setup do
      {:ok, state: Mode.initial_state()}
    end

    test "i transitions to insert mode", %{state: state} do
      {new_mode, commands, _new_state} = Mode.process(:normal, {?i, 0}, state)
      assert new_mode == :insert
      assert commands == []
    end

    test "a emits move_right then transitions to insert", %{state: state} do
      {new_mode, commands, _new_state} = Mode.process(:normal, {?a, 0}, state)
      assert new_mode == :insert
      assert commands == [:move_right]
    end

    test "A moves after line end then transitions to insert", %{state: state} do
      {new_mode, commands, _new_state} = Mode.process(:normal, {?A, 0}, state)
      assert new_mode == :insert
      assert commands == [:move_to_line_end, :move_right]
    end

    test "I emits move_to_line_start then transitions to insert", %{state: state} do
      {new_mode, commands, _new_state} = Mode.process(:normal, {?I, 0}, state)
      assert new_mode == :insert
      assert commands == [:move_to_line_start]
    end

    test "o emits insert_line_below then transitions to insert", %{state: state} do
      {new_mode, commands, _new_state} = Mode.process(:normal, {?o, 0}, state)
      assert new_mode == :insert
      assert commands == [:insert_line_below]
    end

    test "O emits insert_line_above then transitions to insert", %{state: state} do
      {new_mode, commands, _new_state} = Mode.process(:normal, {?O, 0}, state)
      assert new_mode == :insert
      assert commands == [:insert_line_above]
    end
  end

  describe "process/3 — Normal mode movements" do
    setup do
      {:ok, state: Mode.initial_state()}
    end

    test "h emits move_left", %{state: state} do
      {new_mode, commands, _} = Mode.process(:normal, {?h, 0}, state)
      assert new_mode == :normal
      assert commands == [:move_left]
    end

    test "j emits move_down", %{state: state} do
      {new_mode, commands, _} = Mode.process(:normal, {?j, 0}, state)
      assert new_mode == :normal
      assert commands == [:move_down]
    end

    test "k emits move_up", %{state: state} do
      {new_mode, commands, _} = Mode.process(:normal, {?k, 0}, state)
      assert new_mode == :normal
      assert commands == [:move_up]
    end

    test "l emits move_right", %{state: state} do
      {new_mode, commands, _} = Mode.process(:normal, {?l, 0}, state)
      assert new_mode == :normal
      assert commands == [:move_right]
    end

    test "0 when no count emits move_to_line_start", %{state: state} do
      {new_mode, commands, _} = Mode.process(:normal, {?0, 0}, state)
      assert new_mode == :normal
      assert commands == [:move_to_line_start]
    end
  end

  describe "process/3 — count prefix" do
    setup do
      {:ok, state: Mode.initial_state()}
    end

    test "single digit accumulates count", %{state: state} do
      {new_mode, commands, new_state} = Mode.process(:normal, {?3, 0}, state)
      assert new_mode == :normal
      assert commands == []
      assert new_state.count == 3
    end

    test "two digits accumulate count", %{state: state} do
      {_, _, s1} = Mode.process(:normal, {?1, 0}, state)
      {_, _, s2} = Mode.process(:normal, {?2, 0}, s1)
      assert s2.count == 12
    end

    test "3j produces 3x :move_down commands", %{state: state} do
      {_, _, s1} = Mode.process(:normal, {?3, 0}, state)
      {new_mode, commands, new_state} = Mode.process(:normal, {?j, 0}, s1)
      assert new_mode == :normal
      assert commands == [:move_down, :move_down, :move_down]
      assert new_state.count == nil
    end

    test "count is reset after executing a motion", %{state: state} do
      {_, _, s1} = Mode.process(:normal, {?5, 0}, state)
      {_, _, new_state} = Mode.process(:normal, {?l, 0}, s1)
      assert new_state.count == nil
    end

    test "0 continues count when count already started", %{state: state} do
      {_, _, s1} = Mode.process(:normal, {?1, 0}, state)
      {_, _, s2} = Mode.process(:normal, {?0, 0}, s1)
      assert s2.count == 10
    end

    test "count does not multiply execute_then_transition (e.g. 3a)", %{state: state} do
      {_, _, s1} = Mode.process(:normal, {?3, 0}, state)
      {new_mode, commands, _} = Mode.process(:normal, {?a, 0}, s1)
      # a gives [:move_right], not repeated 3 times
      assert new_mode == :insert
      assert commands == [:move_right]
    end
  end

  describe "process/3 — Insert mode" do
    setup do
      {:ok, state: Mode.initial_state()}
    end

    test "Escape transitions from insert to normal without moving when nothing changed", %{
      state: state
    } do
      {new_mode, commands, _} = Mode.process(:insert, {27, 0}, state)
      assert new_mode == :normal
      assert commands == []
    end

    test "Escape transitions from insert to normal and moves cursor left after a change", %{
      state: state
    } do
      state = %{state | insert_changed: true}
      {new_mode, commands, _} = Mode.process(:insert, {27, 0}, state)
      assert new_mode == :normal
      assert commands == [:move_left]
    end

    test "printable character emits insert_char command", %{state: state} do
      {new_mode, commands, _} = Mode.process(:insert, {?x, 0}, state)
      assert new_mode == :insert
      assert commands == [{:insert_char, "x"}]
    end

    test "backspace (127) emits delete_before", %{state: state} do
      {new_mode, commands, _} = Mode.process(:insert, {127, 0}, state)
      assert new_mode == :insert
      assert commands == [:delete_before]
    end

    test "backspace (8) emits delete_before", %{state: state} do
      {new_mode, commands, _} = Mode.process(:insert, {8, 0}, state)
      assert new_mode == :insert
      assert commands == [:delete_before]
    end

    test "enter emits insert_newline", %{state: state} do
      {new_mode, commands, _} = Mode.process(:insert, {13, 0}, state)
      assert new_mode == :insert
      assert commands == [:insert_newline]
    end

    test "unicode character emits insert_char with UTF-8 string", %{state: state} do
      # '©' = codepoint 169
      {new_mode, commands, _} = Mode.process(:insert, {169, 0}, state)
      assert new_mode == :insert
      assert commands == [{:insert_char, "©"}]
    end

    test "control key is ignored in insert mode", %{state: state} do
      {new_mode, commands, _} = Mode.process(:insert, {?c, 2}, state)
      # Ctrl modifier, no insert
      assert new_mode == :insert
      assert commands == []
    end
  end

  describe "process/3 — Normal→Insert→Normal round-trip" do
    setup do
      {:ok, state: Mode.initial_state()}
    end

    test "i enters insert, Escape returns to normal", %{state: state} do
      {mode1, _, s1} = Mode.process(:normal, {?i, 0}, state)
      assert mode1 == :insert

      {mode2, _, _s2} = Mode.process(:insert, {27, 0}, s1)
      assert mode2 == :normal
    end
  end
end
