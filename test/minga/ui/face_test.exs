defmodule Minga.FaceTest do
  use ExUnit.Case, async: true

  alias Minga.UI.Face

  describe "default/0" do
    test "returns a fully populated face with no nil fields" do
      d = Face.default()
      assert d.name == "default"
      assert d.inherit == nil
      assert d.fg == 0xBBC2CF
      assert d.bg == 0x282C34
      assert d.bold == false
      assert d.italic == false
      assert d.underline == false
      assert d.underline_style == :line
      assert d.strikethrough == false
      assert d.blend == 100
      assert d.font_weight == :regular
      assert d.font_slant == :roman
    end
  end

  describe "infer_parent/1" do
    test "default has no parent" do
      assert Face.infer_parent("default") == nil
    end

    test "single-segment names inherit from default" do
      assert Face.infer_parent("keyword") == "default"
      assert Face.infer_parent("comment") == "default"
    end

    test "multi-segment names inherit from parent segment" do
      assert Face.infer_parent("keyword.function") == "keyword"
      assert Face.infer_parent("keyword.function.builtin") == "keyword.function"
      assert Face.infer_parent("string.special.symbol") == "string.special"
    end
  end

  describe "from_style/3" do
    test "converts a style keyword list to a face" do
      face = Face.from_style("keyword", fg: 0xC678DD, bold: true)
      assert face.name == "keyword"
      assert face.fg == 0xC678DD
      assert face.bold == true
      assert face.italic == nil
      assert face.inherit == nil
    end

    test "accepts inherit option" do
      face = Face.from_style("keyword.function", [fg: 0xC678DD], inherit: "keyword")
      assert face.inherit == "keyword"
    end

    test "maps all known style fields" do
      style = [
        fg: 0xFF0000,
        bg: 0x000000,
        bold: true,
        italic: true,
        underline: true,
        underline_style: :curl,
        underline_color: 0x00FF00,
        strikethrough: true,
        blend: 50
      ]

      face = Face.from_style("test", style)
      assert face.fg == 0xFF0000
      assert face.bg == 0x000000
      assert face.bold == true
      assert face.italic == true
      assert face.underline == true
      assert face.underline_style == :curl
      assert face.underline_color == 0x00FF00
      assert face.strikethrough == true
      assert face.blend == 50
    end
  end

  describe "resolve/2" do
    test "face with all fields set is returned as-is" do
      face = Face.default()
      resolved = Face.resolve(face, fn _ -> nil end)
      assert resolved.fg == face.fg
      assert resolved.bold == face.bold
    end

    test "nil fields inherit from parent" do
      parent = %Face{Face.default() | name: "keyword", fg: 0xC678DD, bold: true}

      child = %Face{
        name: "keyword.function",
        inherit: "keyword",
        fg: 0xFF0000
      }

      lookup = fn
        "keyword" -> parent
        _ -> nil
      end

      resolved = Face.resolve(child, lookup)
      assert resolved.fg == 0xFF0000
      assert resolved.bold == true
      assert resolved.italic == false
      assert resolved.bg == 0x282C34
    end

    test "multi-level inheritance" do
      grandparent = %Face{Face.default() | name: "keyword", fg: 0xC678DD, bold: true}

      parent = %Face{
        name: "keyword.function",
        inherit: "keyword",
        italic: true
      }

      child = %Face{
        name: "keyword.function.builtin",
        inherit: "keyword.function",
        fg: 0x4DB5BD
      }

      lookup = fn
        "keyword" -> grandparent
        "keyword.function" -> parent
        _ -> nil
      end

      resolved = Face.resolve(child, lookup)
      assert resolved.fg == 0x4DB5BD
      assert resolved.bold == true
      assert resolved.italic == true
    end

    test "missing parent falls back to default" do
      face = %Face{name: "orphan", inherit: "nonexistent", fg: 0xFF0000}
      resolved = Face.resolve(face, fn _ -> nil end)
      assert resolved.fg == 0xFF0000
      assert resolved.bg == Face.default().bg
    end

    test "circular inheritance raises" do
      face_a = %Face{name: "a", inherit: "b"}
      face_b = %Face{name: "b", inherit: "a"}

      lookup = fn
        "a" -> face_a
        "b" -> face_b
        _ -> nil
      end

      assert_raise ArgumentError, ~r/circular/, fn ->
        Face.resolve(face_a, lookup)
      end
    end
  end

  describe "to_style/2" do
    test "converts resolved face to keyword list, diffing against base" do
      face = %Face{
        Face.default()
        | name: "test",
          fg: 0xFF6C6B,
          bg: 0x111111,
          bold: true,
          italic: true,
          underline: true,
          strikethrough: true,
          underline_style: :curl,
          underline_color: 0xFF0000,
          blend: 50
      }

      style = Face.to_style(face)
      assert Keyword.get(style, :fg) == 0xFF6C6B
      assert Keyword.get(style, :bg) == 0x111111
      assert Keyword.get(style, :bold) == true
      assert Keyword.get(style, :italic) == true
      assert Keyword.get(style, :underline) == true
      assert Keyword.get(style, :strikethrough) == true
      assert Keyword.get(style, :underline_style) == :curl
      assert Keyword.get(style, :underline_color) == 0xFF0000
      assert Keyword.get(style, :blend) == 50
    end

    test "omits fg/bg that match the base face" do
      base = Face.default()

      face = %Face{
        base
        | name: "same_colors",
          bold: true
      }

      style = Face.to_style(face, base)
      refute Keyword.has_key?(style, :fg)
      refute Keyword.has_key?(style, :bg)
      assert Keyword.get(style, :bold) == true
    end

    test "omits false/default values" do
      face = %Face{
        Face.default()
        | name: "minimal",
          fg: 0xFFFFFF,
          bold: false,
          italic: false,
          underline: false,
          strikethrough: false,
          underline_style: :line,
          blend: 100
      }

      style = Face.to_style(face)
      assert Keyword.get(style, :fg) == 0xFFFFFF
      refute Keyword.has_key?(style, :bold)
      refute Keyword.has_key?(style, :italic)
      refute Keyword.has_key?(style, :strikethrough)
      refute Keyword.has_key?(style, :underline_style)
      refute Keyword.has_key?(style, :blend)
    end

    test "sparse style preserves cursorline bg blending contract" do
      # A face with only fg set (bg inherited from default) should NOT
      # emit :bg in the style, so buffer_line.ex's cursorline logic
      # can apply its own background.
      base = Face.default()

      face = %Face{
        base
        | name: "keyword",
          fg: 0xC678DD,
          bold: true
      }

      style = Face.to_style(face, base)
      assert Keyword.get(style, :fg) == 0xC678DD
      assert Keyword.get(style, :bold) == true
      refute Keyword.has_key?(style, :bg)
    end
  end
end
