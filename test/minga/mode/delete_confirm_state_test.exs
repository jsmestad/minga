defmodule Minga.Mode.DeleteConfirmStateTest do
  use ExUnit.Case, async: true

  alias Minga.Mode.DeleteConfirmState

  describe "new/4" do
    test "creates state for a file" do
      state = DeleteConfirmState.new("/tmp/foo.ex", "foo.ex", false)
      assert state.path == "/tmp/foo.ex"
      assert state.name == "foo.ex"
      assert state.dir? == false
      assert state.child_count == 0
      assert state.phase == :trash
    end

    test "creates state for a directory with child count" do
      state = DeleteConfirmState.new("/tmp/mydir", "mydir", true, 42)
      assert state.path == "/tmp/mydir"
      assert state.name == "mydir"
      assert state.dir? == true
      assert state.child_count == 42
      assert state.phase == :trash
    end
  end

  describe "to_permanent/1" do
    test "transitions phase from trash to permanent" do
      state = DeleteConfirmState.new("/tmp/foo.ex", "foo.ex", false)
      assert state.phase == :trash

      permanent = DeleteConfirmState.to_permanent(state)
      assert permanent.phase == :permanent
      assert permanent.path == "/tmp/foo.ex"
      assert permanent.name == "foo.ex"
    end
  end
end
