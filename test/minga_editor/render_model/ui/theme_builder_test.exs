defmodule MingaEditor.RenderModel.UI.ThemeBuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.RenderModel.UI.ThemeBuilder
  alias Minga.RenderModel.UI.Theme

  describe "build/1" do
    test "produces a Theme model from a built-in theme" do
      editor_theme = MingaEditor.UI.Theme.get!(:doom_one)
      model = ThemeBuilder.build(editor_theme)

      assert %Theme{} = model
      assert model.name == :doom_one
      assert is_list(model.color_slots)
      assert length(model.color_slots) > 20
    end

    test "rejects nil color slots" do
      editor_theme = MingaEditor.UI.Theme.get!(:doom_one)
      model = ThemeBuilder.build(editor_theme)

      # Every slot in the model should have a non-nil color
      Enum.each(model.color_slots, fn {_slot_id, rgb} ->
        assert is_integer(rgb), "expected integer RGB, got: #{inspect(rgb)}"
      end)
    end

    test "slot IDs are non-negative integers" do
      editor_theme = MingaEditor.UI.Theme.get!(:doom_one)
      model = ThemeBuilder.build(editor_theme)

      Enum.each(model.color_slots, fn {slot_id, _rgb} ->
        assert is_integer(slot_id) and slot_id >= 0
      end)
    end

    test "produces consistent output for the same theme" do
      editor_theme = MingaEditor.UI.Theme.get!(:doom_one)
      model1 = ThemeBuilder.build(editor_theme)
      model2 = ThemeBuilder.build(editor_theme)

      assert model1.color_slots == model2.color_slots
    end

    test "works with all available built-in themes" do
      for theme_name <- MingaEditor.UI.Theme.available() do
        editor_theme = MingaEditor.UI.Theme.get!(theme_name)
        model = ThemeBuilder.build(editor_theme)

        assert %Theme{} = model
        assert model.name == theme_name

        assert length(model.color_slots) > 0,
               "Theme #{theme_name} should have at least one color slot"
      end
    end
  end
end
