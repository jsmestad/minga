defmodule Minga.Mode.OperatorPendingTest do
  use ExUnit.Case, async: true

  alias Minga.Mode
  alias Minga.Mode.OperatorPending
  alias Minga.Mode.OperatorPendingState

  defp op_state(operator, op_count \\ 1),
    do: %OperatorPendingState{operator: operator, op_count: op_count}

  describe "motion operators" do
    test "delete, change, and yank map motions to operator commands and target modes" do
      cases = [
        {:delete, ?w, 0, {:delete_motion, :word_forward}, :normal},
        {:delete, ?b, 0, {:delete_motion, :word_backward}, :normal},
        {:delete, ?e, 0, {:delete_motion, :word_end}, :normal},
        {:delete, ?0, 0, {:delete_motion, :line_start}, :normal},
        {:delete, ?$, 0, {:delete_motion, :line_end}, :normal},
        {:delete, ?G, 0, {:delete_motion, :document_end}, :normal},
        {:change, ?w, 0, {:change_motion, :word_forward}, :insert},
        {:change, ?e, 0, {:change_motion, :word_end}, :insert},
        {:change, ?$, 0, {:change_motion, :line_end}, :insert},
        {:yank, ?w, 0, {:yank_motion, :word_forward}, :normal},
        {:yank, ?b, 0, {:yank_motion, :word_backward}, :normal},
        {:delete, ?d, 0x02, {:delete_motion, :half_page_down}, :normal},
        {:delete, ?u, 0x02, {:delete_motion, :half_page_up}, :normal},
        {:yank, ?f, 0x02, {:yank_motion, :page_down}, :normal},
        {:change, ?b, 0x02, {:change_motion, :page_up}, :insert}
      ]

      for {operator, key, mods, command, mode} <- cases do
        assert {:execute_then_transition, [^command], ^mode, _state} =
                 OperatorPending.handle_key({key, mods}, op_state(operator))
      end

      {:continue, pending_g} = OperatorPending.handle_key({?g, 0}, op_state(:delete))

      assert {:execute_then_transition, [{:delete_motion, :document_start}], :normal, _state} =
               OperatorPending.handle_key({?g, 0}, pending_g)
    end

    test "counts accumulate inside operator-pending and multiply pre-operator counts" do
      {:continue, s1} = OperatorPending.handle_key({?1, 0}, op_state(:delete))
      {:continue, s2} = OperatorPending.handle_key({?2, 0}, s1)
      {:continue, s3} = OperatorPending.handle_key({?0, 0}, s2)
      assert s3.count == 120

      {:continue, counted_motion} = OperatorPending.handle_key({?3, 0}, op_state(:delete, 2))

      assert {:execute_then_transition, commands, :normal, _state} =
               OperatorPending.handle_key({?w, 0}, counted_motion)

      assert length(commands) == 6
      assert Enum.all?(commands, &(&1 == {:delete_motion, :word_forward}))
    end
  end

  describe "linewise operators and cancellation" do
    test "repeating operators emits counted linewise commands with the right target mode" do
      cases = [
        {:delete, ?d, 1, {:delete_lines_counted, 1}, :normal},
        {:delete, ?d, 3, {:delete_lines_counted, 3}, :normal},
        {:change, ?c, 1, {:change_lines_counted, 1}, :insert},
        {:yank, ?y, 1, {:yank_lines_counted, 1}, :normal},
        {:indent, ?>, 1, {:indent_lines, 1}, :normal},
        {:indent, ?>, 3, {:indent_lines, 3}, :normal},
        {:dedent, ?<, 1, {:dedent_lines, 1}, :normal},
        {:dedent, ?<, 3, {:dedent_lines, 3}, :normal},
        {:reindent, ?=, 1, {:reindent_lines, 1}, :normal},
        {:reindent, ?=, 3, {:reindent_lines, 3}, :normal}
      ]

      for {operator, key, count, command, mode} <- cases do
        assert {:execute_then_transition, [^command], ^mode, _state} =
                 OperatorPending.handle_key({key, 0}, op_state(operator, count))
      end
    end

    test "escape returns base mode state and unknown keys continue unchanged" do
      state = op_state(:delete)
      assert {:transition, :normal, %Mode.State{}} = OperatorPending.handle_key({27, 0}, state)
      assert {:continue, ^state} = OperatorPending.handle_key({?z, 0}, state)
    end
  end

  describe "Mode.process integration" do
    test "normal mode enters operator-pending with operators and counts, then resolves commands" do
      for {key, operator} <- [
            {?d, :delete},
            {?c, :change},
            {?y, :yank},
            {?>, :indent},
            {?<, :dedent}
          ] do
        assert {:operator_pending, _commands, %{operator: ^operator, op_count: 1}} =
                 Mode.process(:normal, {key, 0}, Mode.initial_state())
      end

      {_, _, counted} = Mode.process(:normal, {?3, 0}, Mode.initial_state())

      assert {:operator_pending, _commands, %{operator: :delete, op_count: 3, count: nil}} =
               Mode.process(:normal, {?d, 0}, counted)

      {_, _, op_state} = Mode.process(:normal, {?d, 0}, Mode.initial_state())

      assert {:normal, [{:delete_motion, :word_forward}], _state} =
               Mode.process(:operator_pending, {?w, 0}, op_state)

      assert {:normal, [{:delete_lines_counted, 1}], _state} =
               Mode.process(:operator_pending, {?d, 0}, op_state)

      assert {:normal, [], _state} = Mode.process(:operator_pending, {27, 0}, op_state)
    end
  end

  describe "indent, dedent, and reindent motions" do
    test "formatting operators support line motions, paragraph/document motions, and gg" do
      cases = [
        {:indent, ?w, 0, {:indent_motion, :word_forward}},
        {:indent, ?}, 0, {:indent_motion, :paragraph_forward}},
        {:indent, ?G, 0, {:indent_motion, :document_end}},
        {:dedent, ?w, 0, {:dedent_motion, :word_forward}},
        {:reindent, ?w, 0, {:reindent_motion, :word_forward}},
        {:reindent, ?G, 0, {:reindent_motion, :document_end}}
      ]

      for {operator, key, mods, command} <- cases do
        assert {:execute_then_transition, [^command], :normal, _state} =
                 OperatorPending.handle_key({key, mods}, op_state(operator))
      end

      for {operator, command} <- [
            dedent: {:dedent_motion, :document_start},
            reindent: {:reindent_motion, :document_start}
          ] do
        state = %OperatorPendingState{operator: operator, op_count: 1, pending_g: true}

        assert {:execute_then_transition, [^command], :normal, _state} =
                 OperatorPending.handle_key({?g, 0}, state)
      end
    end

    test "reindent text objects emit structural object commands for inner and around modifiers" do
      cases = [
        {:inner, {:reindent_text_object, :inner, {:structural, :function}}},
        {:around, {:reindent_text_object, :around, {:structural, :function}}}
      ]

      for {modifier, command} <- cases do
        state = %OperatorPendingState{
          operator: :reindent,
          op_count: 1,
          text_object_modifier: modifier
        }

        assert {:execute_then_transition, [^command], :normal, _state} =
                 OperatorPending.handle_key({?f, 0}, state)
      end
    end
  end
end
