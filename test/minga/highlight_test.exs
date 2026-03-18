defmodule Minga.HighlightTest do
  use ExUnit.Case, async: true

  alias Minga.Face
  alias Minga.Highlight

  # Helper: builds a %Highlight{} with a face registry from a theme map.
  # Replaces manual struct construction in tests that need styles_for_line.
  defp highlight_with(attrs) do
    theme = Keyword.get(attrs, :theme, %{})

    %Highlight{
      version: Keyword.get(attrs, :version, 1),
      spans: Keyword.get(attrs, :spans, {}),
      capture_names: Keyword.get(attrs, :capture_names, []),
      theme: theme,
      face_registry: Face.Registry.from_syntax(theme)
    }
  end

  describe "new/0" do
    test "creates empty state with default theme" do
      hl = Highlight.new()
      assert hl.version == 0
      assert hl.spans == {}
      assert hl.capture_names == []
      assert is_map(hl.theme)
      assert map_size(hl.theme) > 0
    end
  end

  describe "new/1" do
    test "creates empty state with custom theme" do
      theme = %{"keyword" => [fg: 0xFF0000]}
      hl = Highlight.new(theme)
      assert hl.theme == theme
    end
  end

  describe "put_names/2" do
    test "stores capture names" do
      hl = Highlight.new() |> Highlight.put_names(["keyword", "string"])
      assert hl.capture_names == ["keyword", "string"]
    end
  end

  describe "put_spans/3" do
    test "stores spans with matching version" do
      spans = [%{start_byte: 0, end_byte: 5, capture_id: 0}]
      hl = Highlight.new() |> Highlight.put_spans(1, spans)
      assert hl.version == 1
      assert hl.spans == List.to_tuple(spans)
    end

    test "rejects spans with older version" do
      spans1 = [%{start_byte: 0, end_byte: 5, capture_id: 0}]
      spans2 = [%{start_byte: 0, end_byte: 3, capture_id: 1}]

      hl =
        Highlight.new()
        |> Highlight.put_spans(5, spans1)
        |> Highlight.put_spans(3, spans2)

      assert hl.version == 5
      assert hl.spans == List.to_tuple(spans1)
    end

    test "accepts spans with equal version" do
      spans1 = [%{start_byte: 0, end_byte: 5, capture_id: 0}]
      spans2 = [%{start_byte: 0, end_byte: 3, capture_id: 1}]

      hl =
        Highlight.new()
        |> Highlight.put_spans(5, spans1)
        |> Highlight.put_spans(5, spans2)

      assert hl.spans == List.to_tuple(spans2)
    end
  end

  describe "byte_offset_for_line/2" do
    test "first line starts at 0" do
      assert Highlight.byte_offset_for_line(["hello", "world"], 0) == 0
    end

    test "second line accounts for first line + newline" do
      assert Highlight.byte_offset_for_line(["hello", "world"], 1) == 6
    end

    test "third line" do
      assert Highlight.byte_offset_for_line(["ab", "cde", "f"], 2) == 7
    end

    test "unicode lines use byte_size not string length" do
      # "café" is 5 bytes (é = 2 bytes)
      assert Highlight.byte_offset_for_line(["café", "x"], 1) == 6
    end
  end

  describe "styles_for_line/3" do
    test "empty spans returns whole line unstyled" do
      hl = Highlight.new()
      assert Highlight.styles_for_line(hl, "hello world", 0) == [{"hello world", []}]
    end

    test "single span covering part of line" do
      hl =
        highlight_with(
          spans: [%{start_byte: 0, end_byte: 3, capture_id: 0}],
          capture_names: ["keyword"],
          theme: %{"keyword" => [fg: 0xFF0000]}
        )

      result = Highlight.styles_for_line(hl, "def foo", 0)
      assert [{"def", [fg: 0xFF0000]}, {" foo", []}] = result
    end

    test "span in middle of line" do
      hl =
        highlight_with(
          spans: [%{start_byte: 4, end_byte: 7, capture_id: 0}],
          capture_names: ["string"],
          theme: %{"string" => [fg: 0x00FF00]}
        )

      result = Highlight.styles_for_line(hl, "x = :foo + 1", 0)
      assert [{"x = ", []}, {":fo", [fg: 0x00FF00]}, {"o + 1", []}] = result
    end

    test "multiple spans on one line" do
      hl =
        highlight_with(
          spans: [
            %{start_byte: 0, end_byte: 3, capture_id: 0},
            %{start_byte: 4, end_byte: 7, capture_id: 1}
          ],
          capture_names: ["keyword", "function"],
          theme: %{"keyword" => [fg: 0xFF0000], "function" => [fg: 0x00FF00]}
        )

      result = Highlight.styles_for_line(hl, "def foo()", 0)
      assert [{"def", [fg: 0xFF0000]}, {" ", []}, {"foo", [fg: 0x00FF00]}, {"()", []}] = result
    end

    test "span crossing line boundary is clamped" do
      hl =
        highlight_with(
          spans: [%{start_byte: 0, end_byte: 20, capture_id: 0}],
          capture_names: ["comment"],
          theme: %{"comment" => [fg: 0x888888, italic: true]}
        )

      result = Highlight.styles_for_line(hl, "hello", 5)
      assert [{text, style}] = result
      assert text == "hello"
      assert Keyword.get(style, :fg) == 0x888888
      assert Keyword.get(style, :italic) == true
    end

    test "span not overlapping this line is excluded" do
      hl =
        highlight_with(
          spans: [%{start_byte: 100, end_byte: 110, capture_id: 0}],
          capture_names: ["keyword"],
          theme: %{"keyword" => [fg: 0xFF0000]}
        )

      result = Highlight.styles_for_line(hl, "hello", 0)
      assert [{"hello", []}] = result
    end

    test "unknown capture_id returns empty style" do
      hl =
        highlight_with(
          spans: [%{start_byte: 0, end_byte: 3, capture_id: 99}],
          capture_names: ["keyword"],
          theme: %{"keyword" => [fg: 0xFF0000]}
        )

      result = Highlight.styles_for_line(hl, "def foo", 0)
      assert [{"def", []}, {" foo", []}] = result
    end

    test "same-width spans: higher pattern_index wins" do
      # Two captures on the same node. Higher pattern_index = later in query = more specific.
      hl =
        highlight_with(
          spans: [
            %{start_byte: 0, end_byte: 9, capture_id: 0, pattern_index: 3},
            %{start_byte: 0, end_byte: 9, capture_id: 1, pattern_index: 10}
          ],
          capture_names: ["keyword", "keyword.function"],
          theme: %{
            "keyword" => [fg: 0xFF0000],
            "keyword.function" => [fg: 0x00FF00]
          }
        )

      result = Highlight.styles_for_line(hl, "defmodule Foo do", 0)
      all_text = Enum.map_join(result, fn {text, _} -> text end)
      assert all_text == "defmodule Foo do"

      # Higher pattern_index wins
      assert [{"defmodule", [fg: 0x00FF00]}, {" Foo do", []}] = result
    end

    test "partially overlapping spans don't duplicate text" do
      hl =
        highlight_with(
          spans: [
            %{start_byte: 0, end_byte: 5, capture_id: 0},
            %{start_byte: 3, end_byte: 8, capture_id: 1}
          ],
          capture_names: ["keyword", "string"],
          theme: %{"keyword" => [fg: 0xFF0000], "string" => [fg: 0x00FF00]}
        )

      result = Highlight.styles_for_line(hl, "hello world", 0)
      all_text = Enum.map_join(result, fn {text, _} -> text end)
      assert all_text == "hello world"
    end

    test "innermost-wins: child spans override parent spans" do
      # String interpolation: #{content}
      # Outer "embedded" span covers everything, inner "punctuation.special" covers #{ and }
      hl =
        highlight_with(
          spans: [
            %{start_byte: 0, end_byte: 2, capture_id: 1, pattern_index: 10},
            %{start_byte: 0, end_byte: 10, capture_id: 0, pattern_index: 5},
            %{start_byte: 9, end_byte: 10, capture_id: 1, pattern_index: 10}
          ],
          capture_names: ["embedded", "punctuation.special"],
          theme: %{
            "embedded" => [fg: 0xAAAAAA],
            "punctuation.special" => [fg: 0xFF0000]
          }
        )

      result = Highlight.styles_for_line(hl, "\#{content}", 0)
      all_text = Enum.map_join(result, fn {text, _} -> text end)
      assert all_text == "\#{content}"

      assert [
               {"\#{", [fg: 0xFF0000]},
               {"content", [fg: 0xAAAAAA]},
               {"}", [fg: 0xFF0000]}
             ] = result
    end

    test "innermost-wins: module attribute with atoms" do
      # @reference_forms [:alias, :import, :require]
      # Parent @constant covers entire expression, child atoms get their own style
      hl =
        highlight_with(
          spans:
            List.to_tuple([
              %{start_byte: 0, end_byte: 44, capture_id: 1, pattern_index: 38},
              %{start_byte: 18, end_byte: 24, capture_id: 0, pattern_index: 5},
              %{start_byte: 26, end_byte: 33, capture_id: 0, pattern_index: 5},
              %{start_byte: 35, end_byte: 43, capture_id: 0, pattern_index: 5}
            ]),
          capture_names: ["string.special.symbol", "constant"],
          theme: %{
            "string.special.symbol" => [fg: 0xAA00FF],
            "constant" => [fg: 0xDA8548]
          }
        )

      line = "@reference_forms [:alias, :import, :require]"
      result = Highlight.styles_for_line(hl, line, 0)
      all_text = Enum.map_join(result, fn {text, _} -> text end)
      assert all_text == line

      assert [
               {"@reference_forms [", [fg: 0xDA8548]},
               {":alias", [fg: 0xAA00FF]},
               {", ", [fg: 0xDA8548]},
               {":import", [fg: 0xAA00FF]},
               {", ", [fg: 0xDA8548]},
               {":require", [fg: 0xAA00FF]},
               {"]", [fg: 0xDA8548]}
             ] = result
    end

    test "innermost-wins: three nesting levels" do
      hl =
        highlight_with(
          spans:
            List.to_tuple([
              %{start_byte: 0, end_byte: 20, capture_id: 0, pattern_index: 1},
              %{start_byte: 5, end_byte: 15, capture_id: 1, pattern_index: 2},
              %{start_byte: 8, end_byte: 12, capture_id: 2, pattern_index: 3}
            ]),
          capture_names: ["outer", "middle", "inner"],
          theme: %{
            "outer" => [fg: 0x111111],
            "middle" => [fg: 0x222222],
            "inner" => [fg: 0x333333]
          }
        )

      result = Highlight.styles_for_line(hl, "01234567890123456789", 0)
      all_text = Enum.map_join(result, fn {text, _} -> text end)
      assert all_text == "01234567890123456789"

      assert [
               {"01234", [fg: 0x111111]},
               {"567", [fg: 0x222222]},
               {"8901", [fg: 0x333333]},
               {"234", [fg: 0x222222]},
               {"56789", [fg: 0x111111]}
             ] = result
    end

    test "injection layer always wins over outer layer" do
      # layer=1 (injection) beats layer=0 (outer) even when outer is narrower
      hl =
        highlight_with(
          spans:
            List.to_tuple([
              %{start_byte: 0, end_byte: 5, capture_id: 0, pattern_index: 10, layer: 0},
              %{start_byte: 0, end_byte: 10, capture_id: 1, pattern_index: 1, layer: 1}
            ]),
          capture_names: ["outer.keyword", "injection.string"],
          theme: %{
            "outer.keyword" => [fg: 0xFF0000],
            "injection.string" => [fg: 0x00FF00]
          }
        )

      result = Highlight.styles_for_line(hl, "hello world", 0)

      # Injection wins everywhere it covers, even though outer is narrower
      assert [{"hello", [fg: 0x00FF00]}, {" worl", [fg: 0x00FF00]}, {"d", []}] = result
    end

    test "with line_start_byte offset" do
      hl =
        highlight_with(
          spans: [%{start_byte: 8, end_byte: 11, capture_id: 0}],
          capture_names: ["keyword"],
          theme: %{"keyword" => [fg: 0xFF0000]}
        )

      result = Highlight.styles_for_line(hl, "bar baz", 8)
      assert [{"bar", [fg: 0xFF0000]}, {" baz", []}] = result
    end
  end

  describe "styles_for_visible_lines/2" do
    test "empty highlights returns unstyled segments" do
      hl = Highlight.new()

      result =
        Highlight.styles_for_visible_lines(hl, [
          {"hello", 0},
          {"world", 6}
        ])

      assert result == [[{"hello", []}], [{"world", []}]]
    end

    test "results match per-line styles_for_line" do
      hl =
        highlight_with(
          spans:
            List.to_tuple([
              %{start_byte: 0, end_byte: 3, capture_id: 0, pattern_index: 1},
              %{start_byte: 8, end_byte: 13, capture_id: 1, pattern_index: 2}
            ]),
          capture_names: ["keyword", "string"],
          theme: %{"keyword" => [fg: 0xFF0000], "string" => [fg: 0x00FF00]}
        )

      lines = [{"def foo", 0}, {"world", 8}]

      batch_result = Highlight.styles_for_visible_lines(hl, lines)

      per_line_result =
        Enum.map(lines, fn {text, offset} ->
          Highlight.styles_for_line(hl, text, offset)
        end)

      assert batch_result == per_line_result
    end

    test "multi-line span handled correctly across lines" do
      hl =
        highlight_with(
          spans:
            List.to_tuple([
              %{start_byte: 0, end_byte: 30, capture_id: 0, pattern_index: 1}
            ]),
          capture_names: ["comment"],
          theme: %{"comment" => [fg: 0x888888]}
        )

      lines = [{"first", 0}, {"second", 6}, {"third", 13}]
      result = Highlight.styles_for_visible_lines(hl, lines)

      assert result == [
               [{"first", [fg: 0x888888]}],
               [{"second", [fg: 0x888888]}],
               [{"third", [fg: 0x888888]}]
             ]
    end

    test "watermark advances past consumed spans" do
      hl =
        highlight_with(
          spans:
            List.to_tuple([
              %{start_byte: 0, end_byte: 3, capture_id: 0, pattern_index: 1},
              %{start_byte: 10, end_byte: 15, capture_id: 1, pattern_index: 2}
            ]),
          capture_names: ["keyword", "string"],
          theme: %{"keyword" => [fg: 0xFF0000], "string" => [fg: 0x00FF00]}
        )

      lines = [{"def foo", 0}, {"hello", 8}, {"world", 14}]
      result = Highlight.styles_for_visible_lines(hl, lines)

      assert result == [
               [{"def", [fg: 0xFF0000]}, {" foo", []}],
               [{"he", []}, {"llo", [fg: 0x00FF00]}],
               [{"w", [fg: 0x00FF00]}, {"orld", []}]
             ]
    end
  end

  describe "from_theme/1" do
    test "builds a highlight state with face registry" do
      theme = Minga.Theme.get!(:doom_one)
      hl = Highlight.from_theme(theme)
      assert hl.face_registry != nil
      assert hl.theme == theme.syntax
    end

    test "face registry resolves styles with inheritance" do
      theme = Minga.Theme.get!(:doom_one)
      hl = Highlight.from_theme(theme)

      # "keyword" is defined in doom_one, should resolve with bold
      style = Minga.Face.Registry.style_for(hl.face_registry, "keyword")
      assert Keyword.get(style, :bold) == true
      assert Keyword.get(style, :fg) != nil
    end

    test "face registry falls back through dotted names" do
      theme = Minga.Theme.get!(:doom_one)
      hl = Highlight.from_theme(theme)

      # "keyword.function.builtin.whatever" doesn't exist, should fall back
      style = Minga.Face.Registry.style_for(hl.face_registry, "keyword.function.builtin.whatever")
      # Should get keyword.function or keyword's style
      assert Keyword.get(style, :fg) != nil
    end
  end
end
