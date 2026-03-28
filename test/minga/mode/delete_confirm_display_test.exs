defmodule Minga.Mode.DeleteConfirmDisplayTest do
  use ExUnit.Case, async: true

  alias Minga.Mode
  alias Minga.Mode.DeleteConfirmState

  describe "display/2 for :delete_confirm" do
    test "file trash prompt" do
      state = DeleteConfirmState.new("/tmp/foo.ex", "foo.ex", false)
      assert Mode.display(:delete_confirm, state) == "Delete 'foo.ex'? (y/n)"
    end

    test "directory trash prompt includes child count" do
      state = DeleteConfirmState.new("/tmp/mydir", "mydir", true, 12)
      assert Mode.display(:delete_confirm, state) == "Delete 'mydir/' and 12 files? (y/n)"
    end

    test "permanent delete fallback prompt" do
      state =
        DeleteConfirmState.new("/tmp/foo.ex", "foo.ex", false)
        |> DeleteConfirmState.to_permanent()

      assert Mode.display(:delete_confirm, state) ==
               "Cannot trash. Permanently delete 'foo.ex'? (y/n)"
    end
  end

  describe "display/1 for :delete_confirm" do
    test "returns simple label" do
      assert Mode.display(:delete_confirm) == "-- DELETE? --"
    end
  end
end
