defmodule Minga.Mode.OperatorPendingStructuralTest do
  use ExUnit.Case, async: true

  alias Minga.Mode.OperatorPending
  alias Minga.Mode.OperatorPendingState, as: OPState

  describe "structural text object keys" do
    test "dif emits delete_text_object for function inner" do
      state = %OPState{operator: :delete, text_object_modifier: :inner}

      assert {:execute_then_transition, [{:delete_text_object, :inner, {:structural, :function}}],
              :normal, _} = OperatorPending.handle_key({?f, 0}, state)
    end

    test "daf emits delete_text_object for function around" do
      state = %OPState{operator: :delete, text_object_modifier: :around}

      assert {:execute_then_transition,
              [{:delete_text_object, :around, {:structural, :function}}], :normal, _} =
               OperatorPending.handle_key({?f, 0}, state)
    end

    test "cif emits change_text_object for function inner and transitions to insert" do
      state = %OPState{operator: :change, text_object_modifier: :inner}

      assert {:execute_then_transition, [{:change_text_object, :inner, {:structural, :function}}],
              :insert, _} = OperatorPending.handle_key({?f, 0}, state)
    end

    test "yaf emits yank_text_object for function around" do
      state = %OPState{operator: :yank, text_object_modifier: :around}

      assert {:execute_then_transition, [{:yank_text_object, :around, {:structural, :function}}],
              :normal, _} = OperatorPending.handle_key({?f, 0}, state)
    end

    test "dic emits delete_text_object for class inner" do
      state = %OPState{operator: :delete, text_object_modifier: :inner}

      assert {:execute_then_transition, [{:delete_text_object, :inner, {:structural, :class}}],
              :normal, _} = OperatorPending.handle_key({?c, 0}, state)
    end

    test "dac emits delete_text_object for class around" do
      state = %OPState{operator: :delete, text_object_modifier: :around}

      assert {:execute_then_transition, [{:delete_text_object, :around, {:structural, :class}}],
              :normal, _} = OperatorPending.handle_key({?c, 0}, state)
    end

    test "dia emits delete_text_object for parameter inner" do
      state = %OPState{operator: :delete, text_object_modifier: :inner}

      assert {:execute_then_transition,
              [{:delete_text_object, :inner, {:structural, :parameter}}], :normal, _} =
               OperatorPending.handle_key({?a, 0}, state)
    end

    test "daa emits delete_text_object for parameter around" do
      state = %OPState{operator: :delete, text_object_modifier: :around}

      assert {:execute_then_transition,
              [{:delete_text_object, :around, {:structural, :parameter}}], :normal, _} =
               OperatorPending.handle_key({?a, 0}, state)
    end

    test "dib emits delete_text_object for block inner" do
      state = %OPState{operator: :delete, text_object_modifier: :inner}

      assert {:execute_then_transition, [{:delete_text_object, :inner, {:structural, :block}}],
              :normal, _} = OperatorPending.handle_key({?b, 0}, state)
    end

    test "dab emits delete_text_object for block around" do
      state = %OPState{operator: :delete, text_object_modifier: :around}

      assert {:execute_then_transition, [{:delete_text_object, :around, {:structural, :block}}],
              :normal, _} = OperatorPending.handle_key({?b, 0}, state)
    end

    test "i and a without modifier still set text_object_modifier" do
      state = %OPState{operator: :delete, text_object_modifier: nil}

      assert {:continue, %{text_object_modifier: :inner}} =
               OperatorPending.handle_key({?i, 0}, state)

      assert {:continue, %{text_object_modifier: :around}} =
               OperatorPending.handle_key({?a, 0}, state)
    end

    test "existing text objects still work (iw, i\", i()" do
      state = %OPState{operator: :delete, text_object_modifier: :inner}

      assert {:execute_then_transition, [{:delete_text_object, :inner, :word}], :normal, _} =
               OperatorPending.handle_key({?w, 0}, state)

      assert {:execute_then_transition, [{:delete_text_object, :inner, {:quote, "\""}}], :normal,
              _} = OperatorPending.handle_key({?", 0}, state)

      assert {:execute_then_transition, [{:delete_text_object, :inner, {:paren, "(", ")"}}],
              :normal, _} = OperatorPending.handle_key({?(, 0}, state)
    end
  end
end
