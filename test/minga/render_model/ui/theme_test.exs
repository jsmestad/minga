defmodule Minga.RenderModel.UI.ThemeTest do
  use ExUnit.Case, async: true

  alias Minga.RenderModel.UI.Theme

  describe "%Theme{}" do
    test "requires name and color_slots" do
      theme = %Theme{name: :test_theme, color_slots: [{0x01, 0xFF0000}]}

      assert theme.name == :test_theme
      assert theme.color_slots == [{0x01, 0xFF0000}]
    end

    test "raises when enforce_keys are missing" do
      assert_raise ArgumentError, fn ->
        struct!(Theme, %{})
      end
    end

    test "color_slots can contain multiple entries" do
      slots = [{0x01, 0xFF0000}, {0x02, 0x00FF00}, {0x03, 0x0000FF}]
      theme = %Theme{name: :multi, color_slots: slots}

      assert length(theme.color_slots) == 3
    end

    test "color_slots can be empty" do
      theme = %Theme{name: :empty, color_slots: []}

      assert theme.color_slots == []
    end
  end
end
