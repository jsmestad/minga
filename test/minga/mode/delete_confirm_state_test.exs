defmodule Minga.Mode.DeleteConfirmStateTest do
  use ExUnit.Case, async: true

  alias Minga.Mode.DeleteConfirmState

  describe "new/4" do
    test "creates state for a file" do
      state = DeleteConfirmState.new("/tmp/foo.ex", "foo.ex", false, {1, 0, 123, :regular})
      assert state.path == "/tmp/foo.ex"
      assert state.name == "foo.ex"
      assert state.dir? == false
      assert state.phase == :trash
    end

    test "creates state for a directory" do
      state = DeleteConfirmState.new("/tmp/mydir", "mydir", true, {1, 0, 123, :directory})
      assert state.path == "/tmp/mydir"
      assert state.name == "mydir"
      assert state.dir? == true
      assert state.phase == :trash
    end
  end

  describe "to_permanent/1" do
    test "transitions phase from trash to permanent" do
      identity = {1, 0, 123, :regular}
      state = DeleteConfirmState.new("/tmp/foo.ex", "foo.ex", false, identity)
      assert state.phase == :trash

      permanent = DeleteConfirmState.to_permanent(state)
      assert permanent.phase == :permanent
      assert permanent.path == "/tmp/foo.ex"
      assert permanent.name == "foo.ex"
      assert permanent.identity == identity
    end
  end
end
