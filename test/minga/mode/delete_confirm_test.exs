defmodule Minga.Mode.DeleteConfirmTest do
  use ExUnit.Case, async: true

  alias Minga.Mode.DeleteConfirm
  alias Minga.Mode.DeleteConfirmState

  describe "handle_key/2 in :trash phase" do
    setup do
      state = DeleteConfirmState.new("/tmp/foo.ex", "foo.ex", false)
      %{state: state}
    end

    test "y confirms trash deletion", %{state: state} do
      assert {:execute_then_transition, [{:delete_confirm_trash, "/tmp/foo.ex"}], :normal, ^state} =
               DeleteConfirm.handle_key({?y, 0}, state)
    end

    test "n cancels deletion", %{state: state} do
      assert {:execute_then_transition, [:delete_confirm_cancel], :normal, ^state} =
               DeleteConfirm.handle_key({?n, 0}, state)
    end

    test "Escape cancels deletion", %{state: state} do
      assert {:execute_then_transition, [:delete_confirm_cancel], :normal, ^state} =
               DeleteConfirm.handle_key({27, 0}, state)
    end

    test "other keys are ignored", %{state: state} do
      assert {:continue, ^state} = DeleteConfirm.handle_key({?x, 0}, state)
      assert {:continue, ^state} = DeleteConfirm.handle_key({?a, 0}, state)
      assert {:continue, ^state} = DeleteConfirm.handle_key({13, 0}, state)
    end
  end

  describe "handle_key/2 in :permanent phase" do
    setup do
      state =
        DeleteConfirmState.new("/tmp/bar.ex", "bar.ex", false)
        |> DeleteConfirmState.to_permanent()

      %{state: state}
    end

    test "y confirms permanent deletion", %{state: state} do
      assert {:execute_then_transition, [{:delete_confirm_permanent, "/tmp/bar.ex"}], :normal,
              ^state} = DeleteConfirm.handle_key({?y, 0}, state)
    end

    test "n cancels", %{state: state} do
      assert {:execute_then_transition, [:delete_confirm_cancel], :normal, ^state} =
               DeleteConfirm.handle_key({?n, 0}, state)
    end
  end
end
