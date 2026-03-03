defmodule Minga.Highlight.ThemeTest do
  use ExUnit.Case, async: true

  alias Minga.Highlight.Theme

  describe "doom_one/0" do
    test "returns a non-empty map" do
      theme = Theme.doom_one()
      assert is_map(theme)
      assert map_size(theme) > 20
    end

    test "all values are keyword lists with fg color" do
      for {_name, style} <- Theme.doom_one() do
        assert is_list(style)
        assert Keyword.has_key?(style, :fg)
      end
    end
  end

  describe "style_for_capture/2" do
    setup do
      %{theme: Theme.doom_one()}
    end

    test "exact match", %{theme: theme} do
      assert [fg: _, bold: true] = Theme.style_for_capture(theme, "keyword")
    end

    test "exact match for dotted name", %{theme: theme} do
      style = Theme.style_for_capture(theme, "keyword.function")
      # keyword.function = magenta (Helix/Neovim consensus)
      assert Keyword.get(style, :fg) == 0xC678DD
    end

    test "falls back to parent when dotted name not found", %{theme: theme} do
      # "keyword.unknown" isn't in the theme, should fall back to "keyword"
      style = Theme.style_for_capture(theme, "keyword.unknown")
      assert style == Theme.style_for_capture(theme, "keyword")
    end

    test "deep fallback strips multiple segments", %{theme: theme} do
      style = Theme.style_for_capture(theme, "keyword.unknown.deep.nested")
      assert style == Theme.style_for_capture(theme, "keyword")
    end

    test "unknown capture returns empty list", %{theme: theme} do
      assert Theme.style_for_capture(theme, "nonexistent") == []
    end

    test "empty string returns empty list", %{theme: theme} do
      assert Theme.style_for_capture(theme, "") == []
    end

    test "covers all Elixir query captures", %{theme: theme} do
      elixir_captures = [
        "attribute",
        "comment",
        "comment.doc",
        "comment.unused",
        "constant",
        "constant.builtin",
        "embedded",
        "function",
        "keyword",
        "module",
        "number",
        "operator",
        "property",
        "punctuation",
        "punctuation.bracket",
        "punctuation.delimiter",
        "punctuation.special",
        "string",
        "string.escape",
        "string.regex",
        "string.special",
        "string.special.symbol",
        "variable"
      ]

      for capture <- elixir_captures do
        style = Theme.style_for_capture(theme, capture)
        assert style != [], "Expected style for #{inspect(capture)}, got []"
        assert Keyword.has_key?(style, :fg), "Expected :fg in style for #{inspect(capture)}"
      end
    end
  end
end
