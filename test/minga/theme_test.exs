defmodule Minga.ThemeTest do
  use ExUnit.Case, async: true

  alias Minga.Theme

  describe "available/0" do
    test "returns 7 built-in themes" do
      themes = Theme.available()
      assert length(themes) == 7
      assert :doom_one in themes
      assert :catppuccin_frappe in themes
      assert :catppuccin_latte in themes
      assert :catppuccin_macchiato in themes
      assert :catppuccin_mocha in themes
      assert :one_dark in themes
      assert :one_light in themes
    end
  end

  describe "default/0" do
    test "returns :doom_one" do
      assert Theme.default() == :doom_one
    end
  end

  describe "get/1" do
    test "returns {:ok, theme} for valid name" do
      assert {:ok, %Theme{name: :doom_one}} = Theme.get(:doom_one)
    end

    test "returns :error for invalid name" do
      assert :error = Theme.get(:nonexistent)
    end
  end

  describe "get!/1" do
    test "returns theme struct for valid name" do
      theme = Theme.get!(:doom_one)
      assert %Theme{name: :doom_one} = theme
    end

    test "raises for invalid name" do
      assert_raise ArgumentError, ~r/unknown theme/, fn ->
        Theme.get!(:nonexistent)
      end
    end
  end

  describe "style_for_capture/2" do
    test "exact match" do
      theme = Theme.get!(:doom_one)
      style = Theme.style_for_capture(theme, "keyword")
      assert Keyword.get(style, :bold) == true
      assert is_integer(Keyword.get(style, :fg))
    end

    test "suffix fallback" do
      theme = Theme.get!(:doom_one)
      style = Theme.style_for_capture(theme, "keyword.unknown.deep")
      assert Keyword.get(style, :bold) == true
    end

    test "returns empty list for unknown capture" do
      theme = Theme.get!(:doom_one)
      assert Theme.style_for_capture(theme, "nonexistent") == []
    end
  end

  describe "all themes are valid" do
    for theme_name <- [
          :doom_one,
          :catppuccin_frappe,
          :catppuccin_latte,
          :catppuccin_macchiato,
          :catppuccin_mocha,
          :one_dark,
          :one_light
        ] do
      test "#{theme_name} has all required fields" do
        theme = Theme.get!(unquote(theme_name))
        assert %Theme{} = theme
        assert theme.name == unquote(theme_name)

        # Editor colors
        assert is_integer(theme.editor.bg)
        assert is_integer(theme.editor.fg)
        assert is_integer(theme.editor.tilde_fg)
        assert is_integer(theme.editor.split_border_fg)

        # Gutter colors
        assert is_integer(theme.gutter.fg)
        assert is_integer(theme.gutter.current_fg)
        assert is_integer(theme.gutter.error_fg)
        assert is_integer(theme.gutter.warning_fg)
        assert is_integer(theme.gutter.info_fg)
        assert is_integer(theme.gutter.hint_fg)

        # Modeline colors
        assert is_integer(theme.modeline.bar_fg)
        assert is_integer(theme.modeline.bar_bg)
        assert is_integer(theme.modeline.info_fg)
        assert is_integer(theme.modeline.info_bg)
        assert is_integer(theme.modeline.filetype_fg)
        assert is_map(theme.modeline.mode_colors)
        assert map_size(theme.modeline.mode_colors) >= 7

        for {_mode, {fg, bg}} <- theme.modeline.mode_colors do
          assert is_integer(fg)
          assert is_integer(bg)
        end

        # Picker colors
        assert is_integer(theme.picker.bg)
        assert is_integer(theme.picker.sel_bg)
        assert is_integer(theme.picker.text_fg)
        assert is_integer(theme.picker.match_fg)

        # Minibuffer colors
        assert is_integer(theme.minibuffer.fg)
        assert is_integer(theme.minibuffer.bg)
        assert is_integer(theme.minibuffer.warning_fg)
        assert is_integer(theme.minibuffer.dim_fg)

        # Search colors
        assert is_integer(theme.search.highlight_fg)
        assert is_integer(theme.search.highlight_bg)
        assert is_integer(theme.search.current_bg)

        # Popup colors
        assert is_integer(theme.popup.fg)
        assert is_integer(theme.popup.bg)
        assert is_integer(theme.popup.border_fg)
      end

      test "#{theme_name} has syntax entries for common captures" do
        theme = Theme.get!(unquote(theme_name))

        common_captures = [
          "keyword",
          "string",
          "comment",
          "function",
          "type",
          "variable",
          "number",
          "operator"
        ]

        for capture <- common_captures do
          style = Theme.style_for_capture(theme, capture)
          assert is_list(style), "expected style list for #{capture} in #{unquote(theme_name)}"

          assert Keyword.has_key?(style, :fg),
                 "expected :fg in style for #{capture} in #{unquote(theme_name)}"
        end
      end

      test "#{theme_name} color groups are proper structs" do
        theme = Theme.get!(unquote(theme_name))
        assert %Theme.Editor{} = theme.editor
        assert %Theme.Gutter{} = theme.gutter
        assert %Theme.Modeline{} = theme.modeline
        assert %Theme.Picker{} = theme.picker
        assert %Theme.Minibuffer{} = theme.minibuffer
        assert %Theme.Search{} = theme.search
        assert %Theme.Popup{} = theme.popup
      end

      test "#{theme_name} all colors are non-negative integers" do
        theme = Theme.get!(unquote(theme_name))

        for {_key, color} <- Map.from_struct(theme.editor) do
          assert is_integer(color) and color >= 0
        end

        for {_key, color} <- Map.from_struct(theme.gutter) do
          assert is_integer(color) and color >= 0
        end
      end
    end
  end

  describe "light vs dark themes" do
    test "latte has a light background" do
      theme = Theme.get!(:catppuccin_latte)
      # Latte's base is 0xEFF1F5, a very light color
      assert theme.editor.bg > 0xC0C0C0
    end

    test "one_light has a light background" do
      theme = Theme.get!(:one_light)
      assert theme.editor.bg > 0xC0C0C0
    end

    test "doom_one has a dark background" do
      theme = Theme.get!(:doom_one)
      assert theme.editor.bg < 0x404040
    end

    test "catppuccin_mocha has a dark background" do
      theme = Theme.get!(:catppuccin_mocha)
      assert theme.editor.bg < 0x404040
    end
  end
end
