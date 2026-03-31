defmodule MingaEditor.UI.Picker.OverhaulTest do
  @moduledoc "Tests for picker overhaul features: multi-select, match positions on items, two_line flag."

  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker
  alias MingaEditor.UI.Picker.Item

  @items [
    %Item{id: :a, label: "README.md", description: "/project/README.md"},
    %Item{id: :b, label: "config.exs", description: "/project/config/config.exs", two_line: true},
    %Item{id: :c, label: "mix.exs", description: "/project/mix.exs", two_line: true},
    %Item{
      id: :d,
      label: "editor.ex",
      description: "/project/lib/minga/editor.ex",
      annotation: "SPC f f"
    }
  ]

  describe "multi-select (toggle_mark)" do
    test "toggling mark on selected item adds it to marked set" do
      picker = Picker.new(@items, title: "Test")
      assert map_size(picker.marked) == 0

      picker = Picker.toggle_mark(picker)
      assert Map.has_key?(picker.marked, :a)
    end

    test "toggling mark twice removes the mark" do
      picker = Picker.new(@items, title: "Test")
      picker = picker |> Picker.toggle_mark() |> Picker.toggle_mark()
      assert map_size(picker.marked) == 0
    end

    test "can mark multiple items" do
      picker = Picker.new(@items, title: "Test")

      picker =
        picker
        |> Picker.toggle_mark()
        |> Picker.move_down()
        |> Picker.toggle_mark()
        |> Picker.move_down()
        |> Picker.toggle_mark()

      assert map_size(picker.marked) == 3
      assert Map.has_key?(picker.marked, :a)
      assert Map.has_key?(picker.marked, :b)
      assert Map.has_key?(picker.marked, :c)
    end

    test "marked_items returns marked items when marks exist" do
      picker = Picker.new(@items, title: "Test")

      picker =
        picker
        |> Picker.toggle_mark()
        |> Picker.move_down()
        |> Picker.move_down()
        |> Picker.toggle_mark()

      items = Picker.marked_items(picker)
      assert length(items) == 2
      ids = Enum.map(items, & &1.id)
      assert :a in ids
      assert :c in ids
    end

    test "marked_items returns selected item when nothing is marked" do
      picker = Picker.new(@items, title: "Test")
      items = Picker.marked_items(picker)
      assert length(items) == 1
      assert hd(items).id == :a
    end

    test "marked_items returns empty list when nothing selected and nothing marked" do
      picker = Picker.new([], title: "Test")
      assert Picker.marked_items(picker) == []
    end

    test "marked? returns correct status" do
      picker = Picker.new(@items, title: "Test")
      item = hd(@items)
      refute Picker.marked?(picker, item)

      picker = Picker.toggle_mark(picker)
      assert Picker.marked?(picker, item)
    end

    test "toggle_mark on empty picker is a no-op" do
      picker = Picker.new([], title: "Test")
      assert Picker.toggle_mark(picker) == picker
    end
  end

  describe "match positions on filtered items" do
    test "filtering stores match_positions on items" do
      picker = Picker.new(@items, title: "Test") |> Picker.filter("config")

      assert Picker.count(picker) >= 1
      item = Picker.selected_item(picker)
      assert item.match_positions != []
    end

    test "empty query clears match_positions" do
      picker =
        Picker.new(@items, title: "Test")
        |> Picker.filter("config")
        |> Picker.filter("")

      Enum.each(picker.filtered, fn item ->
        assert item.match_positions == []
      end)
    end

    test "match_positions are 0-based character indices" do
      items = [%Item{id: :a, label: "config.exs", description: ""}]
      picker = Picker.new(items, title: "Test") |> Picker.filter("config")

      item = Picker.selected_item(picker)
      # "config" matches at positions 0,1,2,3,4,5 in "config.exs"
      assert item.match_positions == [0, 1, 2, 3, 4, 5]
    end
  end

  describe "Item struct fields" do
    test "two_line defaults to false" do
      item = %Item{id: :test, label: "test"}
      refute item.two_line
    end

    test "two_line can be set to true" do
      item = %Item{id: :test, label: "test", two_line: true}
      assert item.two_line
    end

    test "annotation defaults to nil" do
      item = %Item{id: :test, label: "test"}
      assert item.annotation == nil
    end

    test "match_positions defaults to empty list" do
      item = %Item{id: :test, label: "test"}
      assert item.match_positions == []
    end
  end
end
