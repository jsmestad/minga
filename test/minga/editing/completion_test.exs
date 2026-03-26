defmodule Minga.Editing.CompletionTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Completion

  @sample_items [
    %{
      label: "append",
      kind: :function,
      insert_text: "append",
      filter_text: "append",
      detail: "List.append/2",
      sort_text: "append",
      text_edit: nil
    },
    %{
      label: "apply",
      kind: :function,
      insert_text: "apply",
      filter_text: "apply",
      detail: "Kernel.apply/3",
      sort_text: "apply",
      text_edit: nil
    },
    %{
      label: "abs",
      kind: :function,
      insert_text: "abs",
      filter_text: "abs",
      detail: "Kernel.abs/1",
      sort_text: "abs",
      text_edit: nil
    },
    %{
      label: "binary_to_term",
      kind: :function,
      insert_text: "binary_to_term",
      filter_text: "binary_to_term",
      detail: ":erlang.binary_to_term/1",
      sort_text: "binary_to_term",
      text_edit: nil
    }
  ]

  describe "new/2" do
    test "creates completion with sorted items" do
      comp = Completion.new(@sample_items, {0, 5})
      assert Completion.count(comp) == 4
      assert comp.trigger_position == {0, 5}
      assert comp.selected == 0
    end

    test "sorts items by sort_text" do
      comp = Completion.new(@sample_items, {0, 0})
      labels = Enum.map(comp.filtered, & &1.label)
      assert labels == ["abs", "append", "apply", "binary_to_term"]
    end

    test "handles empty items" do
      comp = Completion.new([], {0, 0})
      assert Completion.count(comp) == 0
      refute Completion.active?(comp)
    end
  end

  describe "filter/2" do
    test "filters by prefix (case-insensitive)" do
      comp = Completion.new(@sample_items, {0, 0})
      filtered = Completion.filter(comp, "ap")
      assert Completion.count(filtered) == 2
      labels = Enum.map(filtered.filtered, & &1.label)
      assert "append" in labels
      assert "apply" in labels
    end

    test "empty prefix shows all items" do
      comp = Completion.new(@sample_items, {0, 0})
      filtered = Completion.filter(comp, "")
      assert Completion.count(filtered) == 4
    end

    test "no matches returns empty" do
      comp = Completion.new(@sample_items, {0, 0})
      filtered = Completion.filter(comp, "xyz")
      assert Completion.count(filtered) == 0
      refute Completion.active?(filtered)
    end

    test "resets selection to 0" do
      comp = Completion.new(@sample_items, {0, 0})
      comp = Completion.move_down(comp)
      assert comp.selected == 1
      filtered = Completion.filter(comp, "a")
      assert filtered.selected == 0
    end

    test "case-insensitive matching" do
      comp = Completion.new(@sample_items, {0, 0})
      filtered = Completion.filter(comp, "AP")
      assert Completion.count(filtered) == 2
    end
  end

  describe "navigation" do
    test "move_down advances selection" do
      comp = Completion.new(@sample_items, {0, 0})
      comp = Completion.move_down(comp)
      assert comp.selected == 1
    end

    test "move_down wraps at bottom" do
      comp = Completion.new(@sample_items, {0, 0})

      comp =
        comp
        |> Completion.move_down()
        |> Completion.move_down()
        |> Completion.move_down()
        |> Completion.move_down()

      assert comp.selected == 0
    end

    test "move_up wraps at top" do
      comp = Completion.new(@sample_items, {0, 0})
      comp = Completion.move_up(comp)
      assert comp.selected == 3
    end

    test "move_down on empty is no-op" do
      comp = Completion.new([], {0, 0})
      assert Completion.move_down(comp) == comp
    end

    test "move_up on empty is no-op" do
      comp = Completion.new([], {0, 0})
      assert Completion.move_up(comp) == comp
    end
  end

  describe "selected_item/1" do
    test "returns the selected item" do
      comp = Completion.new(@sample_items, {0, 0})
      item = Completion.selected_item(comp)
      assert item.label == "abs"
    end

    test "returns nil when empty" do
      comp = Completion.new([], {0, 0})
      assert Completion.selected_item(comp) == nil
    end

    test "returns correct item after navigation" do
      comp = Completion.new(@sample_items, {0, 0})
      comp = Completion.move_down(comp)
      item = Completion.selected_item(comp)
      assert item.label == "append"
    end
  end

  describe "accept/1" do
    test "returns insert_text for item without text_edit" do
      comp = Completion.new(@sample_items, {0, 0})
      assert {:insert_text, "abs"} = Completion.accept(comp)
    end

    test "returns text_edit when item has one" do
      items = [
        %{
          label: "test",
          kind: :function,
          insert_text: "test",
          filter_text: "test",
          detail: "",
          sort_text: "test",
          text_edit: %{
            range: %{start_line: 0, start_col: 0, end_line: 0, end_col: 3},
            new_text: "testing"
          }
        }
      ]

      comp = Completion.new(items, {0, 0})
      assert {:text_edit, %{new_text: "testing"}} = Completion.accept(comp)
    end

    test "returns nil when no items" do
      comp = Completion.new([], {0, 0})
      assert Completion.accept(comp) == nil
    end
  end

  describe "visible_items/1" do
    test "returns all items when fewer than max_visible" do
      comp = Completion.new(@sample_items, {0, 0})
      {visible, selected_offset} = Completion.visible_items(comp)
      assert length(visible) == 4
      assert selected_offset == 0
    end

    test "returns empty for no items" do
      comp = Completion.new([], {0, 0})
      assert {[], 0} = Completion.visible_items(comp)
    end

    test "selected_offset tracks selection within visible window" do
      comp = Completion.new(@sample_items, {0, 0})
      comp = Completion.move_down(comp)
      {_visible, selected_offset} = Completion.visible_items(comp)
      assert selected_offset == 1
    end
  end

  describe "parse_response/1" do
    test "parses CompletionList format" do
      response = %{
        "items" => [
          %{"label" => "foo", "kind" => 3, "insertText" => "foo()"},
          %{"label" => "bar", "kind" => 6}
        ]
      }

      items = Completion.parse_response(response)
      assert length(items) == 2
      assert hd(items).label == "foo"
      assert hd(items).kind == :function
      assert hd(items).insert_text == "foo()"
    end

    test "parses bare CompletionItem array" do
      response = [
        %{"label" => "baz", "kind" => 9}
      ]

      items = Completion.parse_response(response)
      assert length(items) == 1
      assert hd(items).label == "baz"
      assert hd(items).kind == :module
    end

    test "handles nil response" do
      assert Completion.parse_response(nil) == []
    end

    test "strips snippet markers from insertText" do
      response = [
        %{"label" => "func", "kind" => 3, "insertText" => "func(${1:arg1}, ${2:arg2})$0"}
      ]

      items = Completion.parse_response(response)
      assert hd(items).insert_text == "func(arg1, arg2)"
    end

    test "uses label as fallback for missing fields" do
      response = [%{"label" => "something"}]
      items = Completion.parse_response(response)
      item = hd(items)
      assert item.insert_text == "something"
      assert item.filter_text == "something"
      assert item.sort_text == "something"
      assert item.detail == ""
    end

    test "parses textEdit with range" do
      response = [
        %{
          "label" => "test",
          "textEdit" => %{
            "range" => %{
              "start" => %{"line" => 1, "character" => 5},
              "end" => %{"line" => 1, "character" => 8}
            },
            "newText" => "testing"
          }
        }
      ]

      items = Completion.parse_response(response)
      edit = hd(items).text_edit
      assert edit.range.start_line == 1
      assert edit.range.start_col == 5
      assert edit.range.end_line == 1
      assert edit.range.end_col == 8
      assert edit.new_text == "testing"
    end

    test "parses InsertReplaceEdit format" do
      response = [
        %{
          "label" => "test",
          "textEdit" => %{
            "insert" => %{
              "start" => %{"line" => 0, "character" => 0},
              "end" => %{"line" => 0, "character" => 3}
            },
            "replace" => %{
              "start" => %{"line" => 0, "character" => 0},
              "end" => %{"line" => 0, "character" => 5}
            },
            "newText" => "test_func"
          }
        }
      ]

      items = Completion.parse_response(response)
      edit = hd(items).text_edit
      # Should use the insert range
      assert edit.range.end_col == 3
      assert edit.new_text == "test_func"
    end
  end

  describe "kind_label/1" do
    test "returns single character for each kind" do
      assert Completion.kind_label(:function) == "f"
      assert Completion.kind_label(:variable) == "v"
      assert Completion.kind_label(:module) == "M"
      assert Completion.kind_label(:struct) == "S"
      assert Completion.kind_label(:keyword) == "k"
    end
  end

  describe "active?/1" do
    test "true when filtered items exist" do
      comp = Completion.new(@sample_items, {0, 0})
      assert Completion.active?(comp)
    end

    test "false when no filtered items" do
      comp = Completion.new([], {0, 0})
      refute Completion.active?(comp)
    end

    test "false after filtering removes all items" do
      comp = Completion.new(@sample_items, {0, 0})
      filtered = Completion.filter(comp, "zzzzz")
      refute Completion.active?(filtered)
    end
  end
end
