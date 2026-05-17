defmodule MingaEditor.UI.Theme.BuilderTest do
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Theme
  alias MingaEditor.UI.Theme.Builder
  alias MingaEditor.UI.Theme.Palette

  describe "from_palette/3" do
    test "builds a complete theme from semantic colors" do
      theme = Builder.from_palette(:palette_test, sample_palette())

      assert %Theme{name: :palette_test} = theme
      assert %Theme.Editor{} = theme.editor
      assert %Theme.Gutter{} = theme.gutter
      assert %Theme.Git{} = theme.git
      assert %Theme.Modeline{} = theme.modeline
      assert %Theme.Picker{} = theme.picker
      assert %Theme.Minibuffer{} = theme.minibuffer
      assert %Theme.Search{} = theme.search
      assert %Theme.Popup{} = theme.popup
      assert %Theme.Tree{} = theme.tree
      assert %Theme.Agent{} = theme.agent
      assert %Theme.TabBar{} = theme.tab_bar
      assert %Theme.Dashboard{} = theme.dashboard
      assert theme.popup.title_fg == 0x89B4FA
      assert theme.syntax["keyword"] == [fg: 0xCBA6F7, bold: true]
      assert theme.modeline.mode_colors.normal == {0x1E1E2E, 0x89B4FA}
    end

    test "applies nested overrides without requiring a hand-wired theme" do
      theme =
        Builder.from_palette(:palette_test, sample_palette(), %{
          popup: %{title_fg: 0x123456},
          git: %{modified_fg: 0x654321},
          modeline: %{mode_colors: %{normal: {0x000000, 0xFFFFFF}}},
          syntax: %{"keyword" => [fg: 0xABCDEF]}
        })

      assert theme.popup.title_fg == 0x123456
      assert theme.git.modified_fg == 0x654321
      assert theme.modeline.mode_colors.normal == {0x000000, 0xFFFFFF}
      assert theme.modeline.mode_colors.insert == {0x1E1E2E, 0xA6E3A1}
      assert theme.syntax["keyword"] == [fg: 0xABCDEF]
      assert theme.syntax["string"] == [fg: 0xA6E3A1]
    end

    test "rejects unknown modeline mode keys" do
      assert_raise ArgumentError,
                   ~r/unknown theme override modeline\.mode_colors key: norml/,
                   fn ->
                     Builder.from_palette(:palette_test, sample_palette(), %{
                       modeline: %{mode_colors: %{norml: {0x000000, 0xFFFFFF}}}
                     })
                   end
    end

    test "rejects invalid override value shapes" do
      assert_raise ArgumentError, ~r/theme override popup\.title_fg must be a color/, fn ->
        Builder.from_palette(:palette_test, sample_palette(), %{popup: %{title_fg: :oops}})
      end

      assert_raise ArgumentError,
                   ~r/theme override modeline\.mode_colors\.normal must be a \{fg, bg\} color tuple/,
                   fn ->
                     Builder.from_palette(:palette_test, sample_palette(), %{
                       modeline: %{mode_colors: %{normal: :oops}}
                     })
                   end
    end

    test "rejects unknown override sections and fields" do
      assert_raise ArgumentError, ~r/unknown theme override section: :popop/, fn ->
        Builder.from_palette(:palette_test, sample_palette(), %{popop: %{title_fg: 0x123456}})
      end

      assert_raise ArgumentError, ~r/unknown theme override field :popup.:titel_fg/, fn ->
        Builder.from_palette(:palette_test, sample_palette(), %{popup: %{titel_fg: 0x123456}})
      end
    end
  end

  describe "Catppuccin migration" do
    for theme_name <- [
          :catppuccin_mocha,
          :catppuccin_latte,
          :catppuccin_frappe,
          :catppuccin_macchiato
        ] do
      test "#{theme_name} matches the legacy hand-wired theme byte-for-byte" do
        legacy =
          "test/fixtures/theme/#{unquote(theme_name)}.term"
          |> File.read!()
          |> :erlang.binary_to_term()

        assert Theme.get!(unquote(theme_name)) == legacy
      end
    end
  end

  @spec sample_palette() :: Palette.t()
  defp sample_palette do
    Palette.new(%{
      variant: :dark,
      bg: 0x1E1E2E,
      fg: 0xCDD6F4,
      surface: 0x313244,
      overlay: 0x181825,
      muted: 0x6C7086,
      subtle: 0x45475A,
      highlight: 0x89B4FA,
      selection_bg: 0x585B70,
      error: 0xF38BA8,
      warning: 0xF9E2AF,
      info: 0x89B4FA,
      success: 0xA6E3A1,
      match: 0xF9E2AF,
      link: 0x89B4FA,
      border: 0x7F849C,
      contrast_fg: 0x1E1E2E,
      builtin: 0x94E2D5,
      functions: 0x89B4FA,
      keywords: 0xCBA6F7,
      methods: 0x89B4FA,
      operators: 0x89DCEB,
      constants: 0xFAB387,
      strings: 0xA6E3A1,
      numbers: 0xFAB387,
      type: 0xF9E2AF,
      variables: 0xCDD6F4,
      comments: 0x6C7086
    })
  end
end
