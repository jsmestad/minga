defmodule Minga.Mode.NormalTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Defaults
  alias Minga.Mode
  alias Minga.Mode.Normal

  defp fresh_state do
    %{
      Mode.initial_state()
      | leader_trie: Defaults.leader_trie(),
        normal_bindings: Defaults.normal_bindings()
    }
  end

  defp handle(key, state \\ fresh_state()), do: Normal.handle_key(key, state)

  describe "mode transitions" do
    test "insert, command, visual, and replace transitions" do
      transition_cases = [
        {{?i, 0}, :insert},
        {{?:, 0}, :command},
        {{?R, 0}, :replace}
      ]

      # ⌥: is retired; eval opens from the leader with SPC ; (docs/design/keys.md).
      refute match?({:transition, :eval, _}, handle({?:, 0x04}))

      for {key, mode} <- transition_cases do
        assert {:transition, ^mode, _state} = handle(key)
      end

      execute_transition_cases = [
        {{?a, 0}, [:move_right], :insert},
        {{?A, 0}, [:move_to_line_end, :move_right], :insert},
        {{?I, 0}, [:move_to_line_start], :insert},
        {{?o, 0}, [:insert_line_below], :insert},
        {{?O, 0}, [:insert_line_above], :insert},
        {{?s, 0}, [{:delete_chars_at, 1}], :insert},
        {{?S, 0}, [:change_line], :insert},
        {{?C, 0}, [{:delete_motion, :line_end}], :insert}
      ]

      for {key, commands, mode} <- execute_transition_cases do
        assert {:execute_then_transition, ^commands, ^mode, _state} = handle(key)
      end

      assert {:transition, :visual, %{visual_type: :char}} = handle({?v, 0})
      assert {:transition, :visual, %{visual_type: :line}} = handle({?V, 0})

      assert {:transition, :replace, %Minga.Mode.ReplaceState{original_chars: []}} =
               handle({?R, 0})
    end
  end

  describe "normal commands" do
    test "movement, paste, scrolling, undo, redo, and dot-repeat keys execute commands" do
      cases = [
        {{?h, 0}, :move_left},
        {{?j, 0}, :move_down},
        {{?k, 0}, :move_up},
        {{?l, 0}, :move_right},
        {{?h, 0x04}, :selection_expand},
        {{?l, 0x04}, :selection_shrink},
        {{?j, 0x04}, :nav_next_sibling},
        {{?k, 0x04}, :nav_prev_sibling},
        {{?0, 0}, :move_to_line_start},
        {{?w, 0}, :word_forward},
        {{?b, 0}, :word_backward},
        {{?e, 0}, :word_end},
        {{?$, 0}, :move_to_line_end},
        {{?^, 0}, :move_to_first_non_blank},
        {{?G, 0}, :move_to_document_end},
        {{57_352, 0}, :move_up},
        {{57_353, 0}, :move_down},
        {{57_350, 0}, :move_left},
        {{57_351, 0}, :move_right},
        {{57_352, 0x02}, :move_up},
        {{57_353, 0x01}, :move_down},
        {{?p, 0}, :paste_after},
        {{?P, 0}, :paste_before},
        {{?d, 0x02}, :half_page_down},
        {{?u, 0x02}, :half_page_up},
        {{?f, 0x02}, :page_down},
        {{?b, 0x02}, :page_up},
        {{?u, 0}, :undo},
        {{?r, 0x02}, :redo},
        {{?o, 0x02}, :jump_back},
        {{?i, 0x02}, :jump_forward},
        {{9, 0}, :jump_forward},
        {{?D, 0}, {:delete_motion, :line_end}},
        {{?., 0}, {:dot_repeat, nil}}
      ]

      for {key, command} <- cases do
        assert {:execute, ^command, _state} = handle(key)
      end
    end

    test "count prefix accumulates and is passed to operators and dot repeat" do
      {:continue, s1} = handle({?1, 0})
      {:continue, s2} = handle({?2, 0}, s1)
      {:continue, s3} = handle({?3, 0}, s2)
      assert s3.count == 123

      {:continue, ten} = handle({?0, 0}, s1)
      assert ten.count == 10

      {:execute, :move_down, after_move} = handle({?j, 0}, s3)
      assert after_move.count == 123

      for digit <- ?1..?9 do
        {:continue, state} = handle({digit, 0})
        assert state.count == digit - ?0
      end

      {:transition, :operator_pending, %{operator: :delete, op_count: 3}} =
        handle({?d, 0}, handle_count(3))

      {:transition, :operator_pending, %{operator: :indent, op_count: 3}} =
        handle({?>, 0}, handle_count(3))

      {:transition, :operator_pending, %{operator: :dedent, op_count: 3}} =
        handle({?<, 0}, handle_count(3))

      {:execute, {:dot_repeat, 15}, %{count: nil}} = handle({?., 0}, handle_count(15))
    end

    test "operator entry records operator and default count" do
      for {key, operator} <- [
            {?d, :delete},
            {?c, :change},
            {?y, :yank},
            {?>, :indent},
            {?<, :dedent}
          ] do
        {:transition, :operator_pending, state} = handle({key, 0})
        assert state.operator == operator
        assert state.op_count == 1
      end

      refute Map.has_key?(fresh_state(), :pending_shift)
    end

    test "escape and unknown keys clear or preserve the right state" do
      {:continue, counted} = handle({?5, 0})
      {:execute, {:select_register, "\""}, cleared} = handle({27, 0}, counted)
      assert cleared.count == nil
      assert {:execute, {:select_register, "\""}, _} = handle({27, 0})

      assert {:continue, state} = handle({?z, 0})
      assert state.count == nil

      custom = %{count: 3}
      assert {:continue, ^custom} = handle({?z, 0}, custom)
    end
  end

  describe "leader key sequences" do
    test "space starts leader mode, progress advances, and invalid keys cancel" do
      {:execute, {:leader_start, node}, leader_state, :discard_count} = handle({32, 0})
      assert leader_state.leader_node == node
      assert leader_state.leader_keys == ["SPC"]

      case handle({?f, 0}, leader_state) do
        {:execute, {:leader_progress, sub_node}, progressed, :discard_count} ->
          assert progressed.leader_node == sub_node
          assert "f" in progressed.leader_keys

        {:execute, [_command, :leader_cancel], progressed, :discard_count} ->
          assert progressed.leader_node == nil
      end

      for {key, count, pending} <- [
            {{?z, 0}, nil, nil},
            {{?Z, 0}, 5, nil},
            {{27, 0}, 3, nil},
            {{27, 0}, nil, :replace}
          ] do
        state = leader_state |> Map.put(:count, count) |> Map.put(:pending, pending)
        {:execute, :leader_cancel, cancelled, :discard_count} = handle(key, state)
        assert cancelled.leader_node == nil
        assert cancelled.leader_keys == []
        assert cancelled.count == nil
      end
    end

    test "SPC SPC executes :project_find_file" do
      {:execute, {:leader_start, _node}, leader_state, :discard_count} = handle({32, 0})
      {:execute, commands, finished_state, :discard_count} = handle({32, 0}, leader_state)
      assert is_list(commands)
      assert :project_find_file in commands
      assert :leader_cancel in commands
      assert finished_state.leader_node == nil
      assert finished_state.leader_keys == []
    end

    test "repeated space restarts leader when space is not bound at the current node" do
      {:execute, {:leader_start, _node}, leader_state, :discard_count} = handle({32, 0})

      {:execute, {:leader_progress, p_node}, p_state, :discard_count} =
        handle({?p, 0}, leader_state)

      assert p_state.leader_node == p_node

      {:execute, result, restarted, :discard_count} = handle({32, 0}, p_state)
      assert is_list(result)
      assert :leader_cancel in result
      assert restarted.leader_keys == ["SPC"]
      assert restarted.leader_node == leader_state.leader_node
    end

    test "backspace goes up one leader level, and closes which-key at SPC" do
      {:execute, {:leader_start, root}, at_root, :discard_count} = handle({32, 0})
      {:execute, {:leader_progress, minga}, at_a, :discard_count} = handle({?a, 0}, at_root)
      {:execute, {:leader_progress, queue}, at_q, :discard_count} = handle({?q, 0}, at_a)

      assert at_q.leader_node == queue
      assert at_q.leader_keys == ["q", "a", "SPC"]

      {:execute, {:leader_progress, ^minga}, back_to_a, :discard_count} = handle({127, 0}, at_q)
      assert back_to_a.leader_keys == ["a", "SPC"]

      {:execute, {:leader_progress, ^root}, back_to_root, :discard_count} =
        handle({127, 0}, back_to_a)

      assert back_to_root.leader_keys == ["SPC"]
      assert back_to_root.leader_stack == []

      # The way back down again works from the parent.
      assert {:execute, {:leader_progress, ^minga}, _state, :discard_count} =
               handle({?a, 0}, back_to_root)

      {:execute, :leader_cancel, closed, :discard_count} = handle({127, 0}, back_to_root)
      assert closed.leader_node == nil
      assert closed.leader_keys == []
    end
  end

  describe "describe-key" do
    test "normal, unbound, escape, and leader describe-key paths" do
      state = %{fresh_state() | describe_key: %Minga.Mode.DescribeKey{}}

      assert {:execute, {:describe_key_result, "j", :move_down, "Move cursor down"},
              %{describe_key: nil}} = handle({?j, 0}, state)

      assert {:execute, {:describe_key_not_found, "Z"}, %{describe_key: nil}} =
               handle({?Z, 0}, state)

      assert {:continue, %{describe_key: nil}} = handle({27, 0}, state)

      {:continue, s1} = handle({32, 0}, state)
      assert s1.describe_key.leader_node != nil
      assert s1.describe_key.keys == ["SPC"]

      {:continue, s2} = handle({?f, 0}, s1)
      assert s2.describe_key.keys == ["f", "SPC"]

      assert {:execute, {:describe_key_result, "SPC f f", :find_file, "Find file"},
              %{describe_key: nil}} = handle({?f, 0}, s2)

      {:continue, leader} = handle({32, 0}, state)

      assert {:execute, {:describe_key_not_found, "SPC z"}, %{describe_key: nil}} =
               handle({?z, 0}, leader)
    end
  end

  defp handle_count(count) do
    count
    |> Integer.to_string()
    |> String.to_charlist()
    |> Enum.reduce(fresh_state(), fn digit, state ->
      {:continue, next_state} = handle({digit, 0}, state)
      next_state
    end)
  end
end
