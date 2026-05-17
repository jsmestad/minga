defmodule MingaEditor.UI.Theme.PaletteTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Theme.Palette

  describe "new/1" do
    test "fills defaults for a minimal dark palette" do
      palette = Palette.new(minimal_attrs(:dark))

      assert %Palette{} = palette
      assert %Palette.Base{} = palette.base
      assert %Palette.Semantic{} = palette.semantic
      assert %Palette.Syntax{} = palette.syntax
      assert palette.semantic.contrast_fg == palette.base.bg
      assert palette.semantic.highlight == palette.semantic.accent
      assert palette.semantic.selection_bg == palette.base.surface
      assert palette.syntax.functions == palette.semantic.info
      assert palette.syntax.comments == palette.base.muted
    end

    test "fills defaults for a minimal light palette" do
      palette = Palette.new(minimal_attrs(:light))

      assert palette.semantic.contrast_fg == 0xFFFFFF
      assert palette.semantic.error == 0xE45649
      assert palette.semantic.warning == 0xDA8548
      assert palette.semantic.success == 0x50A14F
    end

    test "rejects invalid optional color values" do
      assert_raise ArgumentError, ~r/theme palette highlight must be a color/, fn ->
        Palette.new(Map.put(minimal_attrs(:dark), :highlight, :oops))
      end

      assert_raise ArgumentError, ~r/theme palette keywords must be a color/, fn ->
        Palette.new(Map.put(minimal_attrs(:dark), :keywords, "oops"))
      end
    end

    test "rejects invalid variants" do
      assert_raise ArgumentError, ~r/must be :dark or :light/, fn ->
        Palette.new(Map.put(minimal_attrs(:dark), :variant, :solarized))
      end
    end

    test "rejects manually constructed invalid palette structs" do
      palette = Palette.new(minimal_attrs(:dark))
      invalid_palette = %{palette | base: %{palette.base | bg: nil}}

      assert_raise ArgumentError, ~r/theme palette base\.bg must be a color, got: nil/, fn ->
        Palette.from_map(invalid_palette)
      end
    end
  end

  defp minimal_attrs(variant) do
    %{
      variant: variant,
      bg: 0x101010,
      fg: 0xEEEEEE,
      surface: 0x202020,
      overlay: 0x181818,
      muted: 0x777777,
      subtle: 0x303030
    }
  end
end
