defmodule Minga.RenderModel.UI.PickerTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Picker
  alias Minga.RenderModel.UI.Picker.ActionMenu
  alias Minga.RenderModel.UI.Picker.Item

  describe "%Picker{}" do
    test "defaults to closed" do
      picker = %Picker{}

      refute picker.visible?
      assert picker.items == []
      assert picker.preview_lines == nil
    end

    test "carries open picker data" do
      item = %Item{id: "one", label: "One", marked?: true}
      menu = %ActionMenu{actions: ["open"], selected_index: 0}

      picker = %Picker{
        visible?: true,
        title: "Pick",
        items: [item],
        action_menu: menu,
        preview_lines: [[{"line", 0xFFFFFF, false}]]
      }

      assert picker.visible?
      assert picker.items == [item]
      assert picker.action_menu == menu
    end
  end
end
