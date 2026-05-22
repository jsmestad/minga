defmodule Minga.Mode.BranchDeleteConfirmTest do
  @moduledoc "Tests for git branch delete confirmation mode."
  use ExUnit.Case, async: true

  alias Minga.Mode.BranchDeleteConfirm
  alias Minga.Mode.BranchDeleteConfirmState

  describe "handle_key/2" do
    test "y confirms safe branch deletion" do
      state = BranchDeleteConfirmState.new("/repo", "feature")

      assert {:execute_then_transition, [{:branch_delete_confirm, "/repo", "feature", false}],
              :normal, ^state} = BranchDeleteConfirm.handle_key({?y, 0}, state)
    end

    test "y confirms force branch deletion in force phase" do
      state =
        "/repo"
        |> BranchDeleteConfirmState.new("feature")
        |> BranchDeleteConfirmState.to_force("not fully merged")

      assert {:execute_then_transition, [{:branch_delete_confirm, "/repo", "feature", true}],
              :normal, ^state} = BranchDeleteConfirm.handle_key({?y, 0}, state)
    end

    test "n and escape cancel" do
      state = BranchDeleteConfirmState.new("/repo", "feature")

      assert {:execute_then_transition, [:branch_delete_cancel], :normal, ^state} =
               BranchDeleteConfirm.handle_key({?n, 0}, state)

      assert {:execute_then_transition, [:branch_delete_cancel], :normal, ^state} =
               BranchDeleteConfirm.handle_key({27, 0}, state)
    end

    test "other keys are ignored" do
      state = BranchDeleteConfirmState.new("/repo", "feature")

      assert {:continue, ^state} = BranchDeleteConfirm.handle_key({?x, 0}, state)
    end
  end
end
