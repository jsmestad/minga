defmodule Minga.Mode.NormalTest do
  use ExUnit.Case, async: true

  alias Minga.Keymap.Defaults
  alias Minga.Mode
  alias Minga.Mode.Normal

  # Shorthand: call Normal.handle_key directly with a fresh state.
  defp fresh_state, do: Mode.initial_state()

  describe "mode transitions" do
    test "i produces {:transition, :insert, state}" do
      assert {:transition, :insert, _} = Normal.handle_key({?i, 0}, fresh_state())
    end

    test "a produces {:execute_then_transition, [:move_right], :insert, state}" do
      assert {:execute_then_transition, [:move_right], :insert, _} =
               Normal.handle_key({?a, 0}, fresh_state())
    end

    test "A produces {:execute_then_transition, [:move_to_line_end], :insert, state}" do
      assert {:execute_then_transition, [:move_to_line_end], :insert, _} =
               Normal.handle_key({?A, 0}, fresh_state())
    end

    test "I produces {:execute_then_transition, [:move_to_line_start], :insert, state}" do
      assert {:execute_then_transition, [:move_to_line_start], :insert, _} =
               Normal.handle_key({?I, 0}, fresh_state())
    end

    test "o produces {:execute_then_transition, [:insert_line_below], :insert, state}" do
      assert {:execute_then_transition, [:insert_line_below], :insert, _} =
               Normal.handle_key({?o, 0}, fresh_state())
    end

    test "O produces {:execute_then_transition, [:insert_line_above], :insert, state}" do
      assert {:execute_then_transition, [:insert_line_above], :insert, _} =
               Normal.handle_key({?O, 0}, fresh_state())
    end

    test ": enters command mode" do
      assert {:transition, :command, _} = Normal.handle_key({?:, 0}, fresh_state())
    end

    test "v enters characterwise visual mode" do
      {:transition, :visual, state} = Normal.handle_key({?v, 0}, fresh_state())
      assert state.visual_type == :char
    end

    test "V enters linewise visual mode" do
      {:transition, :visual, state} = Normal.handle_key({?V, 0}, fresh_state())
      assert state.visual_type == :line
    end
  end

  describe "movement keys" do
    test "h produces {:execute, :move_left, state}" do
      assert {:execute, :move_left, _} = Normal.handle_key({?h, 0}, fresh_state())
    end

    test "j produces {:execute, :move_down, state}" do
      assert {:execute, :move_down, _} = Normal.handle_key({?j, 0}, fresh_state())
    end

    test "k produces {:execute, :move_up, state}" do
      assert {:execute, :move_up, _} = Normal.handle_key({?k, 0}, fresh_state())
    end

    test "l produces {:execute, :move_right, state}" do
      assert {:execute, :move_right, _} = Normal.handle_key({?l, 0}, fresh_state())
    end

    test "0 with no count produces {:execute, :move_to_line_start, state}" do
      assert {:execute, :move_to_line_start, _} =
               Normal.handle_key({?0, 0}, fresh_state())
    end

    test "w produces word_forward" do
      assert {:execute, :word_forward, _} = Normal.handle_key({?w, 0}, fresh_state())
    end

    test "b produces word_backward" do
      assert {:execute, :word_backward, _} = Normal.handle_key({?b, 0}, fresh_state())
    end

    test "e produces word_end" do
      assert {:execute, :word_end, _} = Normal.handle_key({?e, 0}, fresh_state())
    end

    test "$ produces move_to_line_end" do
      assert {:execute, :move_to_line_end, _} = Normal.handle_key({?$, 0}, fresh_state())
    end

    test "^ produces move_to_first_non_blank" do
      assert {:execute, :move_to_first_non_blank, _} =
               Normal.handle_key({?^, 0}, fresh_state())
    end

    test "G produces move_to_document_end" do
      assert {:execute, :move_to_document_end, _} =
               Normal.handle_key({?G, 0}, fresh_state())
    end
  end

  describe "arrow keys" do
    test "up arrow (57_416) produces :move_up" do
      assert {:execute, :move_up, _} = Normal.handle_key({57_416, 0}, fresh_state())
    end

    test "down arrow (57_424) produces :move_down" do
      assert {:execute, :move_down, _} = Normal.handle_key({57_424, 0}, fresh_state())
    end

    test "left arrow (57_419) produces :move_left" do
      assert {:execute, :move_left, _} = Normal.handle_key({57_419, 0}, fresh_state())
    end

    test "right arrow (57_421) produces :move_right" do
      assert {:execute, :move_right, _} = Normal.handle_key({57_421, 0}, fresh_state())
    end

    test "arrow keys work with modifiers" do
      assert {:execute, :move_up, _} = Normal.handle_key({57_416, 0x02}, fresh_state())
      assert {:execute, :move_down, _} = Normal.handle_key({57_424, 0x01}, fresh_state())
    end
  end

  describe "operator entry" do
    test "d enters operator_pending with :delete operator" do
      {:transition, :operator_pending, state} = Normal.handle_key({?d, 0}, fresh_state())
      assert state.operator == :delete
      assert state.op_count == 1
    end

    test "c enters operator_pending with :change operator" do
      {:transition, :operator_pending, state} = Normal.handle_key({?c, 0}, fresh_state())
      assert state.operator == :change
      assert state.op_count == 1
    end

    test "y enters operator_pending with :yank operator" do
      {:transition, :operator_pending, state} = Normal.handle_key({?y, 0}, fresh_state())
      assert state.operator == :yank
      assert state.op_count == 1
    end

    test "count prefix is passed as op_count to operator_pending" do
      {:continue, s1} = Normal.handle_key({?3, 0}, fresh_state())
      {:transition, :operator_pending, state} = Normal.handle_key({?d, 0}, s1)
      assert state.operator == :delete
      assert state.op_count == 3
    end
  end

  describe "paste" do
    test "p produces :paste_after" do
      assert {:execute, :paste_after, _} = Normal.handle_key({?p, 0}, fresh_state())
    end

    test "P produces :paste_before" do
      assert {:execute, :paste_before, _} = Normal.handle_key({?P, 0}, fresh_state())
    end
  end

  describe "page / half-page scrolling" do
    test "Ctrl+d produces :half_page_down" do
      assert {:execute, :half_page_down, _} = Normal.handle_key({?d, 0x02}, fresh_state())
    end

    test "Ctrl+u produces :half_page_up" do
      assert {:execute, :half_page_up, _} = Normal.handle_key({?u, 0x02}, fresh_state())
    end

    test "Ctrl+f produces :page_down" do
      assert {:execute, :page_down, _} = Normal.handle_key({?f, 0x02}, fresh_state())
    end

    test "Ctrl+b produces :page_up" do
      assert {:execute, :page_up, _} = Normal.handle_key({?b, 0x02}, fresh_state())
    end
  end

  describe "undo / redo" do
    test "u produces :undo" do
      assert {:execute, :undo, _} = Normal.handle_key({?u, 0}, fresh_state())
    end

    test "Ctrl+r produces :redo" do
      assert {:execute, :redo, _} = Normal.handle_key({?r, 0x02}, fresh_state())
    end
  end

  describe "count prefix accumulation" do
    test "digit 3 sets count to 3 and continues" do
      {:continue, new_state} = Normal.handle_key({?3, 0}, fresh_state())
      assert new_state.count == 3
    end

    test "digits 1 then 2 accumulate to 12" do
      {:continue, s1} = Normal.handle_key({?1, 0}, fresh_state())
      {:continue, s2} = Normal.handle_key({?2, 0}, s1)
      assert s2.count == 12
    end

    test "0 after digit continues count (e.g. 10)" do
      {:continue, s1} = Normal.handle_key({?1, 0}, fresh_state())
      {:continue, s2} = Normal.handle_key({?0, 0}, s1)
      assert s2.count == 10
    end

    test "0 with no prior count is :move_to_line_start (not a count digit)" do
      assert {:execute, :move_to_line_start, _} =
               Normal.handle_key({?0, 0}, fresh_state())
    end

    test "count is preserved in state after digit key" do
      {:continue, state_with_count} = Normal.handle_key({?5, 0}, fresh_state())
      {:execute, :move_down, state_after} = Normal.handle_key({?j, 0}, state_with_count)
      assert state_after.count == 5
    end

    test "all digits 1-9 start a count" do
      for digit <- ?1..?9 do
        {:continue, state} = Normal.handle_key({digit, 0}, fresh_state())
        assert state.count == digit - ?0
      end
    end

    test "multi-digit count like 123" do
      {:continue, s1} = Normal.handle_key({?1, 0}, fresh_state())
      {:continue, s2} = Normal.handle_key({?2, 0}, s1)
      {:continue, s3} = Normal.handle_key({?3, 0}, s2)
      assert s3.count == 123
    end
  end

  describe "Escape key" do
    test "Escape clears any accumulated count" do
      {:continue, s1} = Normal.handle_key({?5, 0}, fresh_state())
      {:continue, s2} = Normal.handle_key({27, 0}, s1)
      assert s2.count == nil
    end

    test "Escape with no count is a no-op continue" do
      assert {:continue, _} = Normal.handle_key({27, 0}, fresh_state())
    end

    test "Escape cancels leader mode" do
      # Simulate being in leader mode
      leader_trie = Defaults.leader_trie()

      state =
        fresh_state()
        |> Map.put(:leader_node, leader_trie)
        |> Map.put(:leader_keys, ["SPC"])

      {:execute, :leader_cancel, new_state} = Normal.handle_key({27, 0}, state)
      assert new_state.leader_node == nil
      assert new_state.leader_keys == []
      assert new_state.count == nil
    end
  end

  describe "leader key sequences" do
    test "SPC starts leader mode" do
      {:execute, {:leader_start, node}, state} = Normal.handle_key({32, 0}, fresh_state())
      assert state.leader_node == node
      assert state.leader_keys == ["SPC"]
    end

    test "SPC while already in leader mode cancels and restarts" do
      # First SPC to enter leader mode
      {:execute, {:leader_start, _node}, state} = Normal.handle_key({32, 0}, fresh_state())

      # Second SPC should cancel and restart
      {:execute, commands, new_state} = Normal.handle_key({32, 0}, state)
      assert is_list(commands)
      assert :leader_cancel in commands
      assert new_state.leader_keys == ["SPC"]
    end

    test "unknown key during leader mode cancels leader" do
      leader_trie = Defaults.leader_trie()

      state =
        fresh_state()
        |> Map.put(:leader_node, leader_trie)
        |> Map.put(:leader_keys, ["SPC"])

      # Press a key that's not in the leader trie (e.g., 'z')
      {:execute, :leader_cancel, new_state} = Normal.handle_key({?z, 0}, state)
      assert new_state.leader_node == nil
      assert new_state.leader_keys == []
    end

    test "valid leader prefix key advances trie" do
      # SPC f should be a prefix (file commands)
      {:execute, {:leader_start, _node}, state} = Normal.handle_key({32, 0}, fresh_state())
      result = Normal.handle_key({?f, 0}, state)

      case result do
        {:execute, {:leader_progress, sub_node}, new_state} ->
          assert new_state.leader_node == sub_node
          assert "f" in new_state.leader_keys

        {:execute, [_cmd, :leader_cancel], new_state} ->
          # If 'f' is a direct command rather than prefix, that's also valid
          assert new_state.leader_node == nil
      end
    end
  end

  describe "unknown keys" do
    test "unknown key produces {:continue, state}" do
      assert {:continue, state} = Normal.handle_key({?z, 0}, fresh_state())
      assert state.count == nil
    end

    test "unknown key does not change state" do
      s = %{count: 3}
      {:continue, s2} = Normal.handle_key({?z, 0}, s)
      assert s2 == s
    end
  end
end
