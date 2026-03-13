defmodule Minga.Mode.ExtensionConfirmTest do
  use ExUnit.Case, async: true

  alias Minga.Mode.ExtensionConfirm
  alias Minga.Mode.ExtensionConfirmState

  @git_update %{
    name: :my_ext,
    source_type: :git,
    old_ref: "abc1234",
    new_ref: "def5678",
    commit_count: 3,
    branch: "main",
    pinned: false
  }

  @pinned_update %{
    name: :pinned_ext,
    source_type: :git,
    old_ref: "abc1234",
    new_ref: "abc1234",
    commit_count: 0,
    branch: nil,
    pinned: true
  }

  defp state(updates) do
    %ExtensionConfirmState{updates: updates}
  end

  describe "handle_key/2" do
    test "Y accepts current and advances" do
      s = state([@git_update, @pinned_update])
      assert {:continue, new_s} = ExtensionConfirm.handle_key({?Y, 0}, s)
      assert new_s.current == 1
      assert new_s.accepted == [0]
    end

    test "n skips current and advances" do
      s = state([@git_update, @pinned_update])
      assert {:continue, new_s} = ExtensionConfirm.handle_key({?n, 0}, s)
      assert new_s.current == 1
      assert new_s.accepted == []
    end

    test "Y on last update finishes" do
      s = state([@git_update])
      result = ExtensionConfirm.handle_key({?Y, 0}, s)
      assert {:execute_then_transition, [:apply_extension_updates], :normal, final_s} = result
      assert final_s.accepted == [0]
    end

    test "n on last update finishes without accepting" do
      s = state([@git_update])
      result = ExtensionConfirm.handle_key({?n, 0}, s)
      assert {:execute_then_transition, [:apply_extension_updates], :normal, final_s} = result
      assert final_s.accepted == []
    end

    test "q finishes early with current decisions" do
      s = %{state([@git_update, @pinned_update]) | accepted: [0], current: 1}
      result = ExtensionConfirm.handle_key({?q, 0}, s)
      assert {:execute_then_transition, [:apply_extension_updates], :normal, final_s} = result
      assert final_s.accepted == [0]
    end

    test "Escape finishes early" do
      s = state([@git_update])
      result = ExtensionConfirm.handle_key({27, 0}, s)
      assert {:execute_then_transition, [:apply_extension_updates], :normal, _} = result
    end

    test "d toggles show_details" do
      s = state([@git_update])

      assert {:execute, :extension_confirm_details, new_s} =
               ExtensionConfirm.handle_key({?d, 0}, s)

      assert new_s.show_details == true

      assert {:execute, :extension_confirm_details, toggled} =
               ExtensionConfirm.handle_key({?d, 0}, new_s)

      assert toggled.show_details == false
    end

    test "unknown keys are ignored" do
      s = state([@git_update])
      assert {:continue, ^s} = ExtensionConfirm.handle_key({?x, 0}, s)
    end
  end

  describe "display/2" do
    test "shows git update details" do
      s = state([@git_update])
      display = Minga.Mode.display(:extension_confirm, s)
      assert display =~ "my_ext"
      assert display =~ "abc1234"
      assert display =~ "def5678"
      assert display =~ "3 commits"
      assert display =~ "[Y/n/d]"
      assert display =~ "(1 of 1)"
    end

    test "shows pinned as skipped" do
      s = state([@pinned_update])
      display = Minga.Mode.display(:extension_confirm, s)
      assert display =~ "pinned, skipped"
    end

    test "shows progress through multiple updates" do
      s = %{state([@git_update, @pinned_update]) | current: 1}
      display = Minga.Mode.display(:extension_confirm, s)
      assert display =~ "(2 of 2)"
    end
  end
end
