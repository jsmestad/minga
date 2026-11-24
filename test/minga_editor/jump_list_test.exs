defmodule MingaEditor.JumpListTest do
  use ExUnit.Case, async: true

  alias MingaEditor.JumpList

  # The list is a pure value; any two distinct pids stand in for buffers.
  setup do
    %{a: self(), b: spawn(fn -> :ok end)}
  end

  describe "record/3" do
    test "appends a place and returns to the newest end", %{a: a} do
      list = JumpList.new() |> JumpList.record(a, {1, 0}) |> JumpList.record(a, {9, 2})
      assert JumpList.entries(list) == {[{a, {1, 0}}, {a, {9, 2}}], 2}
    end

    test "forgets an older entry on the same line of the same buffer", %{a: a, b: b} do
      list =
        JumpList.new()
        |> JumpList.record(a, {3, 0})
        |> JumpList.record(b, {3, 0})
        |> JumpList.record(a, {3, 7})

      assert {[{^b, {3, 0}}, {^a, {3, 7}}], 2} = JumpList.entries(list)
    end

    test "keeps the newest 100 entries", %{a: a} do
      list = Enum.reduce(0..149, JumpList.new(), &JumpList.record(&2, a, {&1, 0}))
      {entries, index} = JumpList.entries(list)

      assert Enum.count(entries) == 100
      assert index == 100
      assert hd(entries) == {a, {50, 0}}
    end
  end

  describe "walking the list" do
    test "back from the newest end records the current place so forward returns to it", %{
      a: a,
      b: b
    } do
      list = JumpList.new() |> JumpList.record(a, {1, 0}) |> JumpList.record(b, {5, 0})

      assert {:ok, {^b, {5, 0}}, list} = JumpList.back(list, a, {20, 4})
      assert {:ok, {^a, {1, 0}}, list} = JumpList.back(list, b, {5, 0})
      assert :none = JumpList.back(list, a, {1, 0})
      assert {:ok, {^b, {5, 0}}, list} = JumpList.forward(list)
      assert {:ok, {^a, {20, 4}}, list} = JumpList.forward(list)
      assert :none = JumpList.forward(list)
    end

    test "back from the newest end on the line of the newest entry skips that entry", %{a: a} do
      list = JumpList.new() |> JumpList.record(a, {1, 0}) |> JumpList.record(a, {5, 0})
      assert {:ok, {_, {1, 0}}, _list} = JumpList.back(list, a, {5, 3})
    end

    test "an empty list has nowhere to go", %{a: a} do
      assert :none = JumpList.back(JumpList.new(), a, {0, 0})
      assert :none = JumpList.forward(JumpList.new())
    end

    test "recording a jump mid-walk returns to the newest end", %{a: a} do
      list = JumpList.new() |> JumpList.record(a, {1, 0}) |> JumpList.record(a, {2, 0})
      {:ok, _entry, list} = JumpList.back(list, a, {3, 0})
      list = JumpList.record(list, a, {7, 0})

      assert {_entries, index} = JumpList.entries(list)
      assert index == length(elem(JumpList.entries(list), 0))
      assert :none = JumpList.forward(list)
    end

    test "go_to/2 moves the walk to one entry", %{a: a, b: b} do
      list = JumpList.new() |> JumpList.record(a, {1, 0}) |> JumpList.record(b, {2, 0})

      assert {:ok, {^a, {1, 0}}, list} = JumpList.go_to(list, 0)
      assert {:ok, {^b, {2, 0}}, _list} = JumpList.forward(list)
      assert :none = JumpList.go_to(list, 5)
    end
  end

  describe "forget_buffer/2" do
    test "drops the buffer's entries and keeps the walk on the same remaining place", %{
      a: a,
      b: b
    } do
      list =
        JumpList.new()
        |> JumpList.record(a, {1, 0})
        |> JumpList.record(b, {2, 0})
        |> JumpList.record(a, {3, 0})

      {:ok, {^a, {3, 0}}, list} = JumpList.go_to(list, 2)
      list = JumpList.forget_buffer(list, b)

      assert {[{^a, {1, 0}}, {^a, {3, 0}}], 1} = JumpList.entries(list)
    end
  end
end
