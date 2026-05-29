defmodule Minga.RenderModel.UI.CompletionTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Completion
  alias Minga.RenderModel.UI.Completion.Item

  describe "%Completion{}" do
    test "defaults to hidden" do
      model = %Completion{}

      refute model.visible?
      assert model.cursor_row == 0
      assert model.cursor_col == 0
      assert model.selected_offset == 0
      assert model.items == []
    end

    test "stores semantic completion items" do
      model = %Completion{
        visible?: true,
        cursor_row: 5,
        cursor_col: 10,
        selected_offset: 1,
        items: [
          %Item{kind: :function, label: "map", detail: "Enum.map/2"},
          %Item{kind: :variable, label: "mapper", detail: "fn"}
        ]
      }

      assert model.visible?
      assert model.cursor_row == 5
      assert model.cursor_col == 10
      assert model.selected_offset == 1
      assert [%Item{label: "map"}, %Item{kind: :variable}] = model.items
    end
  end
end
