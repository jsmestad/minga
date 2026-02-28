defmodule Minga.PickerTest do
  @moduledoc "Unit tests for the generic Picker data structure."

  use ExUnit.Case, async: true

  alias Minga.Picker

  @items [
    {:a, "README.md", "/project/README.md"},
    {:b, "config.exs", "/project/config/config.exs"},
    {:c, "mix.exs", "/project/mix.exs"},
    {:d, "editor.ex", "/project/lib/minga/editor.ex"}
  ]

  describe "new/2" do
    test "creates a picker with all items visible" do
      picker = Picker.new(@items, title: "Test")
      assert Picker.count(picker) == 4
      assert Picker.total(picker) == 4
      assert picker.selected == 0
      assert picker.query == ""
      assert picker.title == "Test"
    end

    test "defaults title to empty string" do
      picker = Picker.new(@items)
      assert picker.title == ""
    end
  end

  describe "type_char/2 and filtering" do
    test "typing filters items by label" do
      picker = Picker.new(@items) |> Picker.type_char("readme")
      # Only README.md matches "readme"
      assert Picker.count(picker) == 1
      assert picker.query == "readme"
    end

    test "filtering is case-insensitive" do
      picker = Picker.new(@items) |> Picker.type_char("README")
      assert Picker.count(picker) == 1
    end

    test "filtering also matches description" do
      picker = Picker.new(@items) |> Picker.type_char("config")
      # "config.exs" label and "/project/config/config.exs" desc
      assert Picker.count(picker) >= 1
    end

    test "no match returns empty filtered list" do
      picker = Picker.new(@items) |> Picker.type_char("zzz")
      assert Picker.count(picker) == 0
      assert Picker.selected_item(picker) == nil
    end

    test "multi-char query narrows progressively" do
      picker =
        Picker.new(@items)
        |> Picker.type_char("m")
        |> Picker.type_char("i")
        |> Picker.type_char("x")
        |> Picker.type_char(".")

      assert Picker.count(picker) == 1
      assert {:c, "mix.exs", _} = Picker.selected_item(picker)
    end
  end

  describe "fuzzy/orderless matching" do
    test "orderless matching — segments match independently" do
      items = [
        {:a, "buffer-switch", "Switch to buffer"},
        {:b, "file-open", "Open a file"},
        {:c, "buffer-kill", "Kill buffer"}
      ]

      picker = Picker.new(items) |> Picker.filter("b sw")
      assert Picker.count(picker) == 1
      assert {:a, "buffer-switch", _} = Picker.selected_item(picker)
    end

    test "fuzzy character matching — characters in order but not contiguous" do
      items = [
        {:a, "editor.ex", "/project/lib/minga/editor.ex"},
        {:b, "readme.md", "/project/readme.md"}
      ]

      # "edr" matches e-d-itor (e, d, r are in order)
      picker = Picker.new(items) |> Picker.filter("edr")
      assert Picker.count(picker) >= 1
      assert {:a, "editor.ex", _} = Picker.selected_item(picker)
    end

    test "exact prefix match scores higher than substring" do
      items = [
        {:a, "xconfig.exs", ""},
        {:b, "config.exs", ""}
      ]

      picker = Picker.new(items) |> Picker.filter("config")
      # "config.exs" should be first (prefix match) over "xconfig.exs" (substring)
      assert {:b, "config.exs", _} = Picker.selected_item(picker)
    end

    test "substring match scores higher than fuzzy" do
      items = [
        {:a, "m_o_d_e.ex", ""},
        {:b, "mode.ex", ""}
      ]

      picker = Picker.new(items) |> Picker.filter("mode")
      # "mode.ex" (contiguous substring) should score higher than "m_o_d_e.ex" (fuzzy)
      assert {:b, "mode.ex", _} = Picker.selected_item(picker)
    end

    test "shorter labels score higher with same match type" do
      items = [
        {:a, "very_long_editor_name.ex", ""},
        {:b, "editor.ex", ""}
      ]

      picker = Picker.new(items) |> Picker.filter("editor")
      assert {:b, "editor.ex", _} = Picker.selected_item(picker)
    end

    test "all segments must match for a positive score" do
      items = [
        {:a, "buffer-switch", "Switch to buffer"},
        {:b, "file-open", "Open a file"}
      ]

      picker = Picker.new(items) |> Picker.filter("buffer zzz")
      assert Picker.count(picker) == 0
    end

    test "whitespace-only query shows all items" do
      picker = Picker.new(@items) |> Picker.filter("   ")
      assert Picker.count(picker) == 4
    end

    test "unicode characters match correctly" do
      items = [
        {:a, "café.txt", "A café file"},
        {:b, "resume.txt", "Plain text"}
      ]

      picker = Picker.new(items) |> Picker.filter("café")
      assert Picker.count(picker) == 1
      assert {:a, "café.txt", _} = Picker.selected_item(picker)
    end
  end

  describe "match_positions/2" do
    test "returns empty list for empty query" do
      assert Picker.match_positions("buffer-switch", "") == []
    end

    test "returns positions for contiguous substring match" do
      positions = Picker.match_positions("config.exs", "config")
      assert positions == [0, 1, 2, 3, 4, 5]
    end

    test "returns positions for fuzzy match" do
      positions = Picker.match_positions("editor.ex", "edr")
      # e(0), d(1), (skip i,t,o), r(5)... but actually "edr" as substring
      # e=0, d=2 (wait, "editor" -> e(0) d(1) i(2) t(3) o(4) r(5))
      # "edr" -> contiguous not found, fuzzy: e(0), d(1), r(5)
      assert 0 in positions
      assert 1 in positions
    end

    test "returns positions for orderless multi-segment query" do
      positions = Picker.match_positions("buffer-switch", "b sw")
      # "b" matches at 0, "sw" matches at 7,8
      assert 0 in positions
      assert 7 in positions
      assert 8 in positions
    end

    test "returns empty list for non-matching query" do
      assert Picker.match_positions("hello", "zzz") == []
    end

    test "is case-insensitive" do
      positions = Picker.match_positions("README.md", "read")
      assert positions == [0, 1, 2, 3]
    end
  end

  describe "backspace/1" do
    test "removes last character and widens filter" do
      picker =
        Picker.new(@items)
        |> Picker.type_char("m")
        |> Picker.type_char("i")
        |> Picker.type_char("x")
        |> Picker.type_char(".")

      assert Picker.count(picker) == 1

      picker = Picker.backspace(picker)
      assert picker.query == "mix"
      assert Picker.count(picker) >= 1
    end

    test "backspace on empty query is a no-op" do
      picker = Picker.new(@items)
      result = Picker.backspace(picker)
      assert result.query == ""
      assert Picker.count(result) == 4
    end
  end

  describe "filter/2" do
    test "sets query directly" do
      picker = Picker.new(@items) |> Picker.filter("editor")
      assert picker.query == "editor"
      assert Picker.count(picker) == 1
    end
  end

  describe "move_down/1 and move_up/1" do
    test "move_down advances selection" do
      picker = Picker.new(@items)
      assert picker.selected == 0

      picker = Picker.move_down(picker)
      assert picker.selected == 1
    end

    test "move_down wraps around" do
      picker = Picker.new(@items)
      picker = picker |> Picker.move_down() |> Picker.move_down() |> Picker.move_down()
      assert picker.selected == 3

      picker = Picker.move_down(picker)
      assert picker.selected == 0
    end

    test "move_up wraps around from 0" do
      picker = Picker.new(@items)
      picker = Picker.move_up(picker)
      assert picker.selected == 3
    end

    test "move_up decrements" do
      picker = Picker.new(@items) |> Picker.move_down() |> Picker.move_down()
      assert picker.selected == 2

      picker = Picker.move_up(picker)
      assert picker.selected == 1
    end

    test "move on empty filtered list is a no-op" do
      picker = Picker.new(@items) |> Picker.filter("zzz")
      assert Picker.move_down(picker).selected == 0
      assert Picker.move_up(picker).selected == 0
    end
  end

  describe "selected_item/1 and selected_id/1" do
    test "returns the item at the selected index" do
      picker = Picker.new(@items) |> Picker.move_down()
      item = Picker.selected_item(picker)
      assert item != nil
      assert Picker.selected_id(picker) != nil
    end

    test "returns nil when no items" do
      picker = Picker.new([])
      assert Picker.selected_item(picker) == nil
      assert Picker.selected_id(picker) == nil
    end
  end

  describe "visible_items/1" do
    test "returns all items when count <= max_visible" do
      picker = Picker.new(@items, max_visible: 10)
      {visible, offset} = Picker.visible_items(picker)
      assert length(visible) == 4
      assert offset == 0
    end

    test "scrolls to keep selection visible" do
      items = for i <- 1..20, do: {i, "item #{i}", "desc #{i}"}
      picker = Picker.new(items, max_visible: 5)

      # Move to item 10
      picker = Enum.reduce(1..9, picker, fn _, p -> Picker.move_down(p) end)
      assert picker.selected == 9

      {visible, offset} = Picker.visible_items(picker)
      assert length(visible) == 5
      # Selected item should be within the visible window
      assert offset >= 0 and offset < 5
    end

    test "empty filtered returns empty" do
      picker = Picker.new(@items) |> Picker.filter("zzz")
      {visible, offset} = Picker.visible_items(picker)
      assert visible == []
      assert offset == 0
    end
  end

  describe "selection clamping on filter" do
    test "selection is clamped when filter reduces results" do
      picker = Picker.new(@items)
      # Move to last item
      picker = picker |> Picker.move_down() |> Picker.move_down() |> Picker.move_down()
      assert picker.selected == 3

      # Filter to 1 item — selection must clamp to 0
      picker = Picker.filter(picker, "mix.exs")
      assert picker.selected == 0
    end
  end
end
