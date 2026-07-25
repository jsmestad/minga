defmodule Minga.HighlightTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Face
  alias Minga.Language.Highlight.Span
  alias MingaEditor.UI.Highlight

  defp assert_segments(result, expected) do
    assert Enum.count(result) == Enum.count(expected),
           "expected #{Enum.count(expected)} segments, got #{Enum.count(result)}: #{inspect(Enum.map(result, fn {text, _face} -> text end))}"

    Enum.zip(result, expected)
    |> Enum.each(fn {{actual_text, actual_face}, {expected_text, expected_attrs}} ->
      assert actual_text == expected_text
      assert %Face{} = actual_face

      for {key, val} <- expected_attrs do
        assert Map.get(actual_face, key) == val,
               "segment #{inspect(expected_text)}: expected #{key}=#{inspect(val)}, got #{inspect(Map.get(actual_face, key))}"
      end
    end)
  end

  defp highlight_with(attrs) do
    theme = Keyword.get(attrs, :theme, %{})

    Highlight.new(theme)
    |> Highlight.put_names(Keyword.get(attrs, :capture_names, []))
    |> Highlight.put_spans(Keyword.get(attrs, :version, 1), Keyword.get(attrs, :spans, []))
  end

  describe "state construction and versioning" do
    test "new, custom themes, capture names, and span versions keep their public contracts" do
      hl = Highlight.new()
      assert hl.version == 0
      assert hl.spans == {}
      assert hl.capture_names == {}
      assert is_map(hl.theme)
      assert map_size(hl.theme) > 0

      theme = %{"keyword" => [fg: 0xFF0000]}
      assert Highlight.new(theme).theme == theme

      assert Highlight.new()
             |> Highlight.put_names(["keyword", "string"])
             |> Map.fetch!(:capture_names) == {"keyword", "string"}

      spans1 = [Span.new(0, 5, 0)]
      spans2 = [Span.new(0, 3, 1)]

      stored = Highlight.new() |> Highlight.put_spans(1, spans1)
      assert stored.version == 1
      assert stored.spans == List.to_tuple(spans1)

      stale = stored |> Highlight.put_spans(5, spans1) |> Highlight.put_spans(3, spans2)
      assert stale.version == 5
      assert stale.spans == List.to_tuple(spans1)

      equal = Highlight.new() |> Highlight.put_spans(5, spans1) |> Highlight.put_spans(5, spans2)
      assert equal.spans == List.to_tuple(spans2)

      assert_raise ArgumentError, fn ->
        Highlight.new() |> Highlight.put_spans(6, [%{start_byte: 0, end_byte: 1, capture_id: 0}])
      end
    end

    test "line byte offsets count newlines and unicode bytes" do
      assert Highlight.byte_offset_for_line(["hello", "world"], 0) == 0
      assert Highlight.byte_offset_for_line(["hello", "world"], 1) == 6
      assert Highlight.byte_offset_for_line(["ab", "cde", "f"], 2) == 7
      assert Highlight.byte_offset_for_line(["café", "x"], 1) == 6
    end

    test "semantic layer composition is pure and deduplicates capture names" do
      parser =
        highlight_with(
          spans: [Span.new(0, 3, 0), Span.new(4, 9, 1), Span.new(100, 103, 0)],
          capture_names: ["keyword", "@lsp.type.variable"],
          theme: %{"keyword" => [fg: 0xFF0000], "@lsp.type.variable" => [fg: 0x00FF00]}
        )

      semantic =
        {0, {"@lsp.type.variable", "@lsp.type.function"},
         {Span.new(0, 3, 0, 0, 2), Span.new(4, 7, 1, 0, 2), Span.new(10, 13, 1, 0, 2)}}

      composed = Highlight.compose_semantic_layer(parser, semantic)

      assert composed.capture_names == {"keyword", "@lsp.type.variable", "@lsp.type.function"}
      assert Enum.map(Tuple.to_list(composed.spans), & &1.capture_id) == [0, 1, 1, 2, 2, 0]
      assert parser.capture_names == {"keyword", "@lsp.type.variable"}
      assert tuple_size(parser.spans) == 3

      assert_segments(
        Highlight.styles_for_visible_lines(composed, [{"def name", 0}]) |> List.first(),
        [
          {"def", fg: 0x00FF00},
          {" ", []},
          {"nam", []},
          {"e", fg: 0x00FF00}
        ]
      )
    end
  end

  describe "styles_for_line/3" do
    test "empty or non-overlapping input returns unstyled or empty segments" do
      assert_segments(Highlight.styles_for_line(Highlight.new(), "hello world", 0), [
        {"hello world", []}
      ])

      with_span =
        highlight_with(
          spans: [Span.new(0, 10, 0)],
          capture_names: ["keyword"],
          theme: %{"keyword" => [fg: 0xFF0000]}
        )

      assert Highlight.styles_for_line(with_span, "", 5) == []

      excluded =
        highlight_with(
          spans: [Span.new(100, 110, 0)],
          capture_names: ["keyword"],
          theme: %{"keyword" => [fg: 0xFF0000]}
        )

      assert_segments(Highlight.styles_for_line(excluded, "hello", 0), [{"hello", []}])
    end

    test "unicode boundaries preserve valid text and style only complete characters" do
      mismatched =
        highlight_with(
          spans: [
            Span.new(2, 5, 0),
            Span.new(10, 20, 0)
          ],
          capture_names: ["keyword"],
          theme: %{"keyword" => [fg: 0xFF0000]}
        )

      line = "# ── Server Callbacks ──────"
      text = Highlight.styles_for_line(mismatched, line, 0) |> joined_text()
      assert String.valid?(text)
      assert text == line

      partial =
        highlight_with(
          spans: [Span.new(0, 1, 0)],
          capture_names: ["comment"],
          theme: %{"comment" => [fg: 0x888888]}
        )

      assert Highlight.styles_for_line(partial, "──", 0) |> joined_text() |> byte_size() ==
               byte_size("──")

      complete =
        highlight_with(
          spans: [Span.new(0, 3, 0)],
          capture_names: ["comment"],
          theme: %{"comment" => [fg: 0x888888]}
        )

      assert_segments(Highlight.styles_for_line(complete, "──", 0), [
        {"─", fg: 0x888888},
        {"─", []}
      ])
    end

    test "simple spans split leading, middle, multiple, crossing, unknown, and offset cases" do
      cases = [
        {
          highlight_with(
            spans: [Span.new(0, 3, 0)],
            capture_names: ["keyword"],
            theme: %{"keyword" => [fg: 0xFF0000]}
          ),
          "def foo",
          0,
          [{"def", fg: 0xFF0000}, {" foo", []}]
        },
        {
          highlight_with(
            spans: [Span.new(4, 7, 0)],
            capture_names: ["string"],
            theme: %{"string" => [fg: 0x00FF00]}
          ),
          "x = :foo + 1",
          0,
          [{"x = ", []}, {":fo", fg: 0x00FF00}, {"o + 1", []}]
        },
        {
          highlight_with(
            spans: [
              Span.new(0, 3, 0),
              Span.new(4, 7, 1)
            ],
            capture_names: ["keyword", "function"],
            theme: %{"keyword" => [fg: 0xFF0000], "function" => [fg: 0x00FF00]}
          ),
          "def foo()",
          0,
          [{"def", fg: 0xFF0000}, {" ", []}, {"foo", fg: 0x00FF00}, {"()", []}]
        },
        {
          highlight_with(
            spans: [Span.new(0, 20, 0)],
            capture_names: ["comment"],
            theme: %{"comment" => [fg: 0x888888, italic: true]}
          ),
          "hello",
          5,
          [{"hello", fg: 0x888888, italic: true}]
        },
        {
          highlight_with(
            spans: [Span.new(0, 3, 99)],
            capture_names: ["keyword"],
            theme: %{"keyword" => [fg: 0xFF0000]}
          ),
          "def foo",
          0,
          [{"def", []}, {" foo", []}]
        },
        {
          highlight_with(
            spans: [Span.new(8, 11, 0)],
            capture_names: ["keyword"],
            theme: %{"keyword" => [fg: 0xFF0000]}
          ),
          "bar baz",
          8,
          [{"bar", fg: 0xFF0000}, {" baz", []}]
        }
      ]

      for {hl, line, offset, expected} <- cases do
        assert_segments(Highlight.styles_for_line(hl, line, offset), expected)
      end
    end

    test "overlap precedence keeps text intact and chooses the most specific visible style" do
      same_width =
        highlight_with(
          spans: [
            Span.new(0, 9, 0, 3),
            Span.new(0, 9, 1, 10)
          ],
          capture_names: ["keyword", "keyword.function"],
          theme: %{"keyword" => [fg: 0xFF0000], "keyword.function" => [fg: 0x00FF00]}
        )

      assert_segments(Highlight.styles_for_line(same_width, "defmodule Foo do", 0), [
        {"defmodule", fg: 0x00FF00},
        {" Foo do", []}
      ])

      partial =
        highlight_with(
          spans: [
            Span.new(0, 5, 0),
            Span.new(3, 8, 1)
          ],
          capture_names: ["keyword", "string"],
          theme: %{"keyword" => [fg: 0xFF0000], "string" => [fg: 0x00FF00]}
        )

      assert Highlight.styles_for_line(partial, "hello world", 0) |> joined_text() ==
               "hello world"

      injection =
        highlight_with(
          spans: [
            Span.new(0, 5, 0, 10, 0),
            Span.new(0, 10, 1, 1, 1)
          ],
          capture_names: ["outer.keyword", "injection.string"],
          theme: %{"outer.keyword" => [fg: 0xFF0000], "injection.string" => [fg: 0x00FF00]}
        )

      assert_segments(Highlight.styles_for_line(injection, "hello world", 0), [
        {"hello", fg: 0x00FF00},
        {" worl", fg: 0x00FF00},
        {"d", []}
      ])
    end

    test "innermost spans override parents across representative nesting shapes" do
      interpolation =
        highlight_with(
          spans: [
            Span.new(0, 2, 1, 10),
            Span.new(0, 10, 0, 5),
            Span.new(9, 10, 1, 10)
          ],
          capture_names: ["embedded", "punctuation.special"],
          theme: %{"embedded" => [fg: 0xAAAAAA], "punctuation.special" => [fg: 0xFF0000]}
        )

      assert_segments(Highlight.styles_for_line(interpolation, ~S(#{content}), 0), [
        {~S(#{), fg: 0xFF0000},
        {"content", fg: 0xAAAAAA},
        {"}", fg: 0xFF0000}
      ])

      attributes =
        highlight_with(
          spans: [
            Span.new(0, 44, 1, 38),
            Span.new(18, 24, 0, 5),
            Span.new(26, 33, 0, 5),
            Span.new(35, 43, 0, 5)
          ],
          capture_names: ["string.special.symbol", "constant"],
          theme: %{"string.special.symbol" => [fg: 0xAA00FF], "constant" => [fg: 0xDA8548]}
        )

      assert_segments(
        Highlight.styles_for_line(attributes, "@reference_forms [:alias, :import, :require]", 0),
        [
          {"@reference_forms [", fg: 0xDA8548},
          {":alias", fg: 0xAA00FF},
          {", ", fg: 0xDA8548},
          {":import", fg: 0xAA00FF},
          {", ", fg: 0xDA8548},
          {":require", fg: 0xAA00FF},
          {"]", fg: 0xDA8548}
        ]
      )

      three_levels =
        highlight_with(
          spans: [
            Span.new(0, 20, 0, 1),
            Span.new(5, 15, 1, 2),
            Span.new(8, 12, 2, 3)
          ],
          capture_names: ["outer", "middle", "inner"],
          theme: %{
            "outer" => [fg: 0x111111],
            "middle" => [fg: 0x222222],
            "inner" => [fg: 0x333333]
          }
        )

      assert_segments(Highlight.styles_for_line(three_levels, "01234567890123456789", 0), [
        {"01234", fg: 0x111111},
        {"567", fg: 0x222222},
        {"8901", fg: 0x333333},
        {"234", fg: 0x222222},
        {"56789", fg: 0x111111}
      ])
    end
  end

  describe "styles_for_visible_lines/2" do
    test "batch styling matches per-line styling and handles empty highlights" do
      empty = Highlight.styles_for_visible_lines(Highlight.new(), [{"hello", 0}, {"world", 6}])
      assert_segments(Enum.at(empty, 0), [{"hello", []}])
      assert_segments(Enum.at(empty, 1), [{"world", []}])

      hl =
        highlight_with(
          spans: [
            Span.new(0, 3, 0, 1),
            Span.new(8, 13, 1, 2)
          ],
          capture_names: ["keyword", "string"],
          theme: %{"keyword" => [fg: 0xFF0000], "string" => [fg: 0x00FF00]}
        )

      lines = [{"def foo", 0}, {"world", 8}]

      per_line =
        Enum.map(lines, fn {text, offset} -> Highlight.styles_for_line(hl, text, offset) end)

      assert Highlight.styles_for_visible_lines(hl, lines) == per_line
    end

    test "batch styling carries multi-line spans and watermark state across visible lines" do
      multiline =
        highlight_with(
          spans: [Span.new(0, 30, 0, 1)],
          capture_names: ["comment"],
          theme: %{"comment" => [fg: 0x888888]}
        )

      result =
        Highlight.styles_for_visible_lines(multiline, [{"first", 0}, {"second", 6}, {"third", 13}])

      assert_segments(Enum.at(result, 0), [{"first", fg: 0x888888}])
      assert_segments(Enum.at(result, 1), [{"second", fg: 0x888888}])
      assert_segments(Enum.at(result, 2), [{"third", fg: 0x888888}])

      watermark =
        highlight_with(
          spans: [
            Span.new(0, 3, 0, 1),
            Span.new(10, 15, 1, 2)
          ],
          capture_names: ["keyword", "string"],
          theme: %{"keyword" => [fg: 0xFF0000], "string" => [fg: 0x00FF00]}
        )

      result =
        Highlight.styles_for_visible_lines(watermark, [
          {"def foo", 0},
          {"hello", 8},
          {"world", 14}
        ])

      assert_segments(Enum.at(result, 0), [{"def", fg: 0xFF0000}, {" foo", []}])
      assert_segments(Enum.at(result, 1), [{"he", []}, {"llo", fg: 0x00FF00}])
      assert_segments(Enum.at(result, 2), [{"w", fg: 0x00FF00}, {"orld", []}])
    end
  end

  describe "from_theme/1" do
    test "builds a face registry that resolves direct and dotted inherited styles" do
      theme = MingaEditor.UI.Theme.get!(:doom_one)
      hl = Highlight.from_theme(theme)
      assert hl.face_registry != nil
      assert hl.theme == theme.syntax

      keyword = MingaEditor.UI.Face.Registry.style_for(hl.face_registry, "keyword")
      assert keyword.bold == true
      assert keyword.fg != nil

      dotted =
        MingaEditor.UI.Face.Registry.style_for(
          hl.face_registry,
          "keyword.function.builtin.whatever"
        )

      assert dotted.fg != nil
    end

    test "renders config-document keys (@property) distinctly from plain text and strings" do
      theme = MingaEditor.UI.Theme.get!(:astrodark)

      # Render `key: "value"` the way the YAML query captures it:
      #   `key`     -> @property
      #   `"value"` -> @string
      line = ~s(key: "value")
      key_span = Span.new(0, 3, 0)
      value_span = Span.new(5, 12, 1)

      hl =
        Highlight.from_theme(theme)
        |> Highlight.put_names(["property", "string"])
        |> Highlight.put_spans(1, [key_span, value_span])

      [{"key", key_face}, {": ", _gap}, {~s("value"), value_face}] =
        Highlight.styles_for_line(hl, line, 0)

      registry = hl.face_registry
      default_fg = MingaEditor.UI.Face.Registry.style_for(registry, "default").fg
      string_fg = MingaEditor.UI.Face.Registry.style_for(registry, "string").fg

      # The key is visibly distinct from plain editor foreground (the bug):
      # in astrodark, @property is a real accent, not the muted editor fg.
      assert key_face.fg != nil
      assert key_face.fg != default_fg

      # Quoted values still resolve through the string face, and remain
      # visibly distinct from keys.
      assert value_face.fg == string_fg
      assert value_face.fg != key_face.fg
    end
  end

  describe "retheme/2" do
    test "swaps colors to the new theme while preserving spans, version, and capture names" do
      spans = [Span.new(0, 7, 0)]

      hl =
        Highlight.from_theme(MingaEditor.UI.Theme.get!(:doom_one))
        |> Highlight.put_names(["keyword"])
        |> Highlight.put_spans(3, spans)

      before_fg = MingaEditor.UI.Face.Registry.style_for(hl.face_registry, "keyword").fg

      one_light = MingaEditor.UI.Theme.get!(:one_light)
      rethemed = Highlight.retheme(hl, one_light)

      # Parse results are theme-independent and survive the swap.
      assert rethemed.version == 3
      assert rethemed.spans == List.to_tuple(spans)
      assert rethemed.capture_names == {"keyword"}

      # Colors come from the new theme.
      assert rethemed.theme == one_light.syntax
      after_fg = MingaEditor.UI.Face.Registry.style_for(rethemed.face_registry, "keyword").fg
      assert after_fg != before_fg
    end
  end

  defp joined_text(result), do: Enum.map_join(result, fn {text, _style} -> text end)
end
