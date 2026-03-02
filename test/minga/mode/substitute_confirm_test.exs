defmodule Minga.Mode.SubstituteConfirmTest do
  use ExUnit.Case, async: true

  alias Minga.Mode.SubstituteConfirm
  alias Minga.Mode.SubstituteConfirmState

  defp state(opts \\ []) do
    matches = Keyword.get(opts, :matches, [{0, 0, 3}, {0, 8, 3}, {1, 4, 3}])
    current = Keyword.get(opts, :current, 0)
    accepted = Keyword.get(opts, :accepted, [])

    %SubstituteConfirmState{
      matches: matches,
      current: current,
      pattern: "foo",
      replacement: "bar",
      original_content: "foo test foo\nblah foo end",
      accepted: accepted
    }
  end

  describe "handle_key/2" do
    test "y accepts current match and advances" do
      result = SubstituteConfirm.handle_key({?y, 0}, state())
      assert {:execute, :substitute_confirm_advance, %{current: 1, accepted: [0]}} = result
    end

    test "n skips current match and advances" do
      result = SubstituteConfirm.handle_key({?n, 0}, state())
      assert {:execute, :substitute_confirm_advance, %{current: 1, accepted: []}} = result
    end

    test "y on last match finishes with apply command" do
      s = state(current: 2)
      result = SubstituteConfirm.handle_key({?y, 0}, s)

      assert {:execute_then_transition, [:apply_substitute_confirm], :normal, %{accepted: [2]}} =
               result
    end

    test "n on last match finishes" do
      s = state(current: 2)
      result = SubstituteConfirm.handle_key({?n, 0}, s)

      assert {:execute_then_transition, [:apply_substitute_confirm], :normal, %{accepted: []}} =
               result
    end

    test "a accepts all remaining matches and finishes" do
      s = state(current: 1, accepted: [0])
      result = SubstituteConfirm.handle_key({?a, 0}, s)

      assert {:execute_then_transition, [:apply_substitute_confirm], :normal, ms} = result
      assert Enum.sort(ms.accepted) == [0, 1, 2]
    end

    test "q finishes with current decisions" do
      s = state(current: 1, accepted: [0])
      result = SubstituteConfirm.handle_key({?q, 0}, s)

      assert {:execute_then_transition, [:apply_substitute_confirm], :normal, %{accepted: [0]}} =
               result
    end

    test "Escape finishes like q" do
      s = state(current: 1, accepted: [0])
      result = SubstituteConfirm.handle_key({27, 0}, s)

      assert {:execute_then_transition, [:apply_substitute_confirm], :normal, %{accepted: [0]}} =
               result
    end

    test "other keys are ignored" do
      assert {:continue, _} = SubstituteConfirm.handle_key({?x, 0}, state())
      assert {:continue, _} = SubstituteConfirm.handle_key({?1, 0}, state())
    end

    test "single match with y finishes immediately" do
      s = state(matches: [{0, 0, 3}])
      result = SubstituteConfirm.handle_key({?y, 0}, s)

      assert {:execute_then_transition, [:apply_substitute_confirm], :normal, %{accepted: [0]}} =
               result
    end

    test "a on first match of many accepts all" do
      result = SubstituteConfirm.handle_key({?a, 0}, state())

      assert {:execute_then_transition, [:apply_substitute_confirm], :normal, ms} = result
      assert Enum.sort(ms.accepted) == [0, 1, 2]
    end
  end
end
