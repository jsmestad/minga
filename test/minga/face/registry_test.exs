defmodule Minga.Face.RegistryTest do
  use ExUnit.Case, async: true

  alias Minga.Face
  alias Minga.Face.Registry

  describe "new/0" do
    test "creates a registry with only the default face" do
      reg = Registry.new()
      assert Registry.names(reg) == ["default"]
      face = Registry.resolve(reg, "default")
      assert face.fg == Face.default().fg
    end
  end

  describe "from_syntax/1" do
    test "converts a syntax map into faces with inferred inheritance" do
      syntax = %{
        "keyword" => [fg: 0xC678DD, bold: true],
        "keyword.function" => [fg: 0xC678DD],
        "comment" => [fg: 0x5B6268, italic: true]
      }

      reg = Registry.from_syntax(syntax)

      keyword = Registry.resolve(reg, "keyword")
      assert keyword.fg == 0xC678DD
      assert keyword.bold == true

      kw_func = Registry.resolve(reg, "keyword.function")
      assert kw_func.fg == 0xC678DD
      # inherits bold from keyword
      assert kw_func.bold == true

      comment = Registry.resolve(reg, "comment")
      assert comment.fg == 0x5B6268
      assert comment.italic == true
      assert comment.bold == false
    end

    test "multi-level inheritance resolves correctly" do
      syntax = %{
        "string" => [fg: 0x98BE65],
        "string.special" => [bold: true],
        "string.special.symbol" => [fg: 0xA9A1E1]
      }

      reg = Registry.from_syntax(syntax)

      symbol = Registry.resolve(reg, "string.special.symbol")
      assert symbol.fg == 0xA9A1E1
      assert symbol.bold == true
    end
  end

  describe "from_theme/1" do
    test "uses editor fg/bg for default face" do
      theme = Minga.Theme.get!(:doom_one)
      reg = Registry.from_theme(theme)

      default = Registry.resolve(reg, "default")
      assert default.fg == theme.editor.fg
      assert default.bg == theme.editor.bg
    end

    test "all syntax entries become resolvable faces" do
      theme = Minga.Theme.get!(:doom_one)
      reg = Registry.from_theme(theme)

      keyword = Registry.resolve(reg, "keyword")
      assert keyword.fg != nil
      assert keyword.bold == true
    end
  end

  describe "resolve/2 with fallback" do
    test "unknown face falls back through dotted name hierarchy" do
      syntax = %{
        "keyword" => [fg: 0xC678DD, bold: true]
      }

      reg = Registry.from_syntax(syntax)

      # keyword.function.builtin doesn't exist, falls back to keyword
      face = Registry.resolve(reg, "keyword.function.builtin")
      assert face.fg == 0xC678DD
      assert face.bold == true
    end

    test "completely unknown face falls back to default" do
      reg = Registry.from_syntax(%{})
      face = Registry.resolve(reg, "nonexistent.thing")
      assert face.fg == Face.default().fg
    end
  end

  describe "style_for/2" do
    test "returns keyword list compatible with Protocol.style()" do
      syntax = %{
        "keyword" => [fg: 0xC678DD, bold: true]
      }

      reg = Registry.from_syntax(syntax)
      style = Registry.style_for(reg, "keyword")

      assert Keyword.get(style, :fg) == 0xC678DD
      assert Keyword.get(style, :bold) == true
    end
  end

  describe "put/2" do
    test "adds a face and invalidates affected cache entries" do
      syntax = %{
        "keyword" => [fg: 0xC678DD, bold: true],
        "keyword.function" => [fg: 0xC678DD]
      }

      reg = Registry.from_syntax(syntax)

      # change keyword's color
      new_face = Face.from_style("keyword", [fg: 0xFF0000, bold: true], inherit: "default")
      reg = Registry.put(reg, new_face)

      # cache is invalidated, need resolve_all
      reg = Registry.resolve_all(reg)

      keyword = Registry.resolve(reg, "keyword")
      assert keyword.fg == 0xFF0000
    end
  end

  describe "with_overrides/2" do
    test "merges buffer-local overrides attribute-by-attribute" do
      syntax = %{
        "keyword" => [fg: 0xC678DD, bold: true]
      }

      reg = Registry.from_syntax(syntax)
      reg = Registry.with_overrides(reg, %{"keyword" => [fg: 0xFF0000]})

      keyword = Registry.resolve(reg, "keyword")
      assert keyword.fg == 0xFF0000
      # bold is preserved from original
      assert keyword.bold == true
    end

    test "override for nonexistent face creates it" do
      reg = Registry.from_syntax(%{})
      reg = Registry.with_overrides(reg, %{"custom" => [fg: 0xFF0000, bold: true]})

      custom = Registry.resolve(reg, "custom")
      assert custom.fg == 0xFF0000
      assert custom.bold == true
    end

    test "rejects unknown fields in overrides" do
      reg = Registry.from_syntax(%{"keyword" => [fg: 0xC678DD]})

      assert_raise ArgumentError, ~r/unknown face field/, fn ->
        Registry.with_overrides(reg, %{"keyword" => [typo_field: 123]})
      end
    end
  end

  describe "with_lsp_defaults/1" do
    test "adds LSP type faces that inherit from tree-sitter equivalents" do
      syntax = %{"function" => [fg: 0x51AFEF], "type" => [fg: 0xECBE7B]}
      reg = Registry.from_syntax(syntax) |> Registry.with_lsp_defaults()

      # @lsp.type.function inherits from function
      face = Registry.resolve(reg, "@lsp.type.function")
      assert face.fg == 0x51AFEF

      # @lsp.type.class inherits from type
      face = Registry.resolve(reg, "@lsp.type.class")
      assert face.fg == 0xECBE7B
    end

    test "adds deprecated modifier face with strikethrough" do
      reg = Registry.from_syntax(%{}) |> Registry.with_lsp_defaults()

      face = Registry.resolve(reg, "@lsp.mod.deprecated")
      assert face.strikethrough == true
    end

    test "LSP faces can be overridden by themes" do
      syntax = %{
        "function" => [fg: 0x51AFEF],
        "@lsp.type.function" => [fg: 0xFF0000, bold: true]
      }

      reg = Registry.from_syntax(syntax) |> Registry.with_lsp_defaults()

      # Theme override wins over the LSP default
      face = Registry.resolve(reg, "@lsp.type.function")
      assert face.fg == 0xFF0000
      assert face.bold == true
    end
  end
end
