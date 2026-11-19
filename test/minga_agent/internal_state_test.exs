defmodule MingaAgent.InternalStateTest do
  use ExUnit.Case, async: true

  alias MingaAgent.InternalState

  describe "todo operations" do
    test "write_todos replaces the task list" do
      state = InternalState.new()

      items = [
        %{"description" => "read the file", "status" => "done"},
        %{"description" => "edit the module", "status" => "in_progress"},
        %{"description" => "run tests", "status" => "pending"}
      ]

      state = InternalState.write_todos(state, items)
      assert Enum.count(state.todos) == 3
      assert Enum.at(state.todos, 0).status == :done
      assert Enum.at(state.todos, 1).status == :in_progress
      assert Enum.at(state.todos, 2).status == :pending
    end

    test "write_todos defaults missing status to pending" do
      state = InternalState.new()
      items = [%{"description" => "no status given"}]

      state = InternalState.write_todos(state, items)
      assert Enum.at(state.todos, 0).status == :pending
    end

    test "read_todos returns formatted list" do
      state = InternalState.new()

      items = [
        %{"description" => "first task", "status" => "done", "id" => "t1"},
        %{"description" => "second task", "status" => "pending", "id" => "t2"}
      ]

      state = InternalState.write_todos(state, items)
      result = InternalState.read_todos(state)

      assert result =~ "✅"
      assert result =~ "first task"
      assert result =~ "⬜"
      assert result =~ "second task"
    end

    test "read_todos on empty state shows help message" do
      state = InternalState.new()
      assert InternalState.read_todos(state) =~ "No tasks"
    end
  end
end
