defmodule Minga.ModeTest do
  use ExUnit.Case

  alias Minga.Mode

  describe "initial_state/0" do
    test "returns a map with nil count" do
      assert Mode.initial_state() == %{count: nil}
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

    test "A emits move_to_line_end then transitions to insert", %{state: state} do
      {new_mode, commands, _new_state} = Mode.process(:normal, {?A, 0}, state)
      assert new_mode == :insert
      assert commands == [:move_to_line_end]
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

    test "Escape transitions from insert to normal", %{state: state} do
      {new_mode, commands, _} = Mode.process(:insert, {27, 0}, state)
      assert new_mode == :normal
      assert commands == []
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
