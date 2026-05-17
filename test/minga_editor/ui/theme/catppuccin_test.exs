defmodule MingaEditor.UI.Theme.CatppuccinTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Theme

  @official_palettes %{
    catppuccin_latte: %{
      source: "lib/minga_editor/ui/theme/catppuccin_latte.ex",
      values: %{
        rosewater: 0xDC8A78,
        flamingo: 0xDD7878,
        pink: 0xEA76CB,
        mauve: 0x8839EF,
        red: 0xD20F39,
        maroon: 0xE64553,
        peach: 0xFE640B,
        yellow: 0xDF8E1D,
        green: 0x40A02B,
        teal: 0x179299,
        sky: 0x04A5E5,
        sapphire: 0x209FB5,
        blue: 0x1E66F5,
        lavender: 0x7287FD,
        text: 0x4C4F69,
        subtext1: 0x5C5F77,
        subtext0: 0x6C6F85,
        overlay2: 0x7C7F93,
        overlay1: 0x8C8FA1,
        overlay0: 0x9CA0B0,
        surface2: 0xACB0BE,
        surface1: 0xBCC0CC,
        surface0: 0xCCD0DA,
        base: 0xEFF1F5,
        mantle: 0xE6E9EF,
        crust: 0xDCE0E8
      }
    },
    catppuccin_frappe: %{
      source: "lib/minga_editor/ui/theme/catppuccin_frappe.ex",
      values: %{
        rosewater: 0xF2D5CF,
        flamingo: 0xEEBEBE,
        pink: 0xF4B8E4,
        mauve: 0xCA9EE6,
        red: 0xE78284,
        maroon: 0xEA999C,
        peach: 0xEF9F76,
        yellow: 0xE5C890,
        green: 0xA6D189,
        teal: 0x81C8BE,
        sky: 0x99D1DB,
        sapphire: 0x85C1DC,
        blue: 0x8CAAEE,
        lavender: 0xBABBF1,
        text: 0xC6D0F5,
        subtext1: 0xB5BFE2,
        subtext0: 0xA5ADCE,
        overlay2: 0x949CBB,
        overlay1: 0x838BA7,
        overlay0: 0x737994,
        surface2: 0x626880,
        surface1: 0x51576D,
        surface0: 0x414559,
        base: 0x303446,
        mantle: 0x292C3C,
        crust: 0x232634
      }
    },
    catppuccin_macchiato: %{
      source: "lib/minga_editor/ui/theme/catppuccin_macchiato.ex",
      values: %{
        rosewater: 0xF4DBD6,
        flamingo: 0xF0C6C6,
        pink: 0xF5BDE6,
        mauve: 0xC6A0F6,
        red: 0xED8796,
        maroon: 0xEE99A0,
        peach: 0xF5A97F,
        yellow: 0xEED49F,
        green: 0xA6DA95,
        teal: 0x8BD5CA,
        sky: 0x91D7E3,
        sapphire: 0x7DC4E4,
        blue: 0x8AADF4,
        lavender: 0xB7BDF8,
        text: 0xCAD3F5,
        subtext1: 0xB8C0E0,
        subtext0: 0xA5ADCB,
        overlay2: 0x939AB7,
        overlay1: 0x8087A2,
        overlay0: 0x6E738D,
        surface2: 0x5B6078,
        surface1: 0x494D64,
        surface0: 0x363A4F,
        base: 0x24273A,
        mantle: 0x1E2030,
        crust: 0x181926
      }
    },
    catppuccin_mocha: %{
      source: "lib/minga_editor/ui/theme/catppuccin_mocha.ex",
      values: %{
        rosewater: 0xF5E0DC,
        flamingo: 0xF2CDCD,
        pink: 0xF5C2E7,
        mauve: 0xCBA6F7,
        red: 0xF38BA8,
        maroon: 0xEBA0AC,
        peach: 0xFAB387,
        yellow: 0xF9E2AF,
        green: 0xA6E3A1,
        teal: 0x94E2D5,
        sky: 0x89DCEB,
        sapphire: 0x74C7EC,
        blue: 0x89B4FA,
        lavender: 0xB4BEFE,
        text: 0xCDD6F4,
        subtext1: 0xBAC2DE,
        subtext0: 0xA6ADC8,
        overlay2: 0x9399B2,
        overlay1: 0x7F849C,
        overlay0: 0x6C7086,
        surface2: 0x585B70,
        surface1: 0x45475A,
        surface0: 0x313244,
        base: 0x1E1E2E,
        mantle: 0x181825,
        crust: 0x11111B
      }
    }
  }

  describe "official palette values" do
    for {theme_name, %{source: source, values: values}} <- @official_palettes do
      test "#{theme_name} palette constants match Catppuccin palette JSON" do
        assert source_palette(unquote(source)) == unquote(Macro.escape(values))
      end
    end
  end

  describe "style guide semantics" do
    for {theme_name, %{values: values}} <- @official_palettes do
      test "#{theme_name} maps syntax and UI colors through Catppuccin semantics" do
        theme = Theme.get!(unquote(theme_name))
        p = unquote(Macro.escape(values))

        assert theme.editor.bg == p.base
        assert theme.editor.fg == p.text
        assert theme.editor.selection_bg == p.surface2
        assert theme.gutter.fg == p.overlay1
        assert theme.gutter.current_fg == p.lavender
        assert theme.gutter.info_fg == p.teal
        assert theme.search.highlight_bg == p.teal
        assert theme.search.current_bg == p.red
        assert theme.popup.sel_bg == p.surface2
        assert theme.popup.title_fg == p.blue
        assert theme.agent.link_fg == p.blue
        assert theme.syntax["markup.link"] == [fg: p.blue]
        assert theme.syntax["function.builtin"] == [fg: p.red]
        assert theme.syntax["comment"] == [fg: p.overlay2, italic: true]
        assert theme.syntax["string.regex"] == [fg: p.pink]
        assert theme.syntax["string.escape"] == [fg: p.pink]
        assert theme.syntax["string.special.symbol"] == [fg: p.red]
        assert theme.syntax["character"] == [fg: p.red]
        assert theme.syntax["variable.parameter"] == [fg: p.maroon]
        assert theme.syntax["property"] == [fg: p.blue]
        assert theme.syntax["attribute"] == [fg: p.yellow]
      end
    end
  end

  defp source_palette(path) do
    path
    |> File.read!()
    |> then(&Regex.scan(~r/(\w+): 0x([0-9A-F]{6})/, &1))
    |> Map.new(fn [_match, key, value] ->
      {String.to_existing_atom(key), String.to_integer(value, 16)}
    end)
  end
end
