defmodule Minga.Mode.NormalTest do
  use ExUnit.Case, async: true

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
  end

  describe "arrow keys" do
    test "up arrow (57416) produces :move_up" do
      assert {:execute, :move_up, _} = Normal.handle_key({57416, 0}, fresh_state())
    end

    test "down arrow (57424) produces :move_down" do
      assert {:execute, :move_down, _} = Normal.handle_key({57424, 0}, fresh_state())
    end

    test "left arrow (57419) produces :move_left" do
      assert {:execute, :move_left, _} = Normal.handle_key({57419, 0}, fresh_state())
    end

    test "right arrow (57421) produces :move_right" do
      assert {:execute, :move_right, _} = Normal.handle_key({57421, 0}, fresh_state())
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
      # Count is consumed; Mode dispatcher resets it, but here we test raw handle_key
      # The state returned from handle_key still has the same count (dispatcher resets it)
      assert state_after.count == 5
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
