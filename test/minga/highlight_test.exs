defmodule Minga.HighlightTest do
  use ExUnit.Case, async: true

  alias Minga.Highlight

  describe "new/0" do
    test "creates empty state with default theme" do
      hl = Highlight.new()
      assert hl.version == 0
      assert hl.spans == []
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
      assert hl.spans == spans
    end

    test "rejects spans with older version" do
      spans1 = [%{start_byte: 0, end_byte: 5, capture_id: 0}]
      spans2 = [%{start_byte: 0, end_byte: 3, capture_id: 1}]

      hl =
        Highlight.new()
        |> Highlight.put_spans(5, spans1)
        |> Highlight.put_spans(3, spans2)

      assert hl.version == 5
      assert hl.spans == spans1
    end

    test "accepts spans with equal version" do
      spans1 = [%{start_byte: 0, end_byte: 5, capture_id: 0}]
      spans2 = [%{start_byte: 0, end_byte: 3, capture_id: 1}]

      hl =
        Highlight.new()
        |> Highlight.put_spans(5, spans1)
        |> Highlight.put_spans(5, spans2)

      assert hl.spans == spans2
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
      hl = %Highlight{
        version: 1,
        spans: [%{start_byte: 0, end_byte: 3, capture_id: 0}],
        capture_names: ["keyword"],
        theme: %{"keyword" => [fg: 0xFF0000]}
      }

      result = Highlight.styles_for_line(hl, "def foo", 0)
      assert [{"def", [fg: 0xFF0000]}, {" foo", []}] = result
    end

    test "span in middle of line" do
      hl = %Highlight{
        version: 1,
        spans: [%{start_byte: 4, end_byte: 7, capture_id: 0}],
        capture_names: ["string"],
        theme: %{"string" => [fg: 0x00FF00]}
      }

      result = Highlight.styles_for_line(hl, "x = :foo + 1", 0)
      assert [{"x = ", []}, {":fo", [fg: 0x00FF00]}, {"o + 1", []}] = result
    end

    test "multiple spans on one line" do
      hl = %Highlight{
        version: 1,
        spans: [
          %{start_byte: 0, end_byte: 3, capture_id: 0},
          %{start_byte: 4, end_byte: 7, capture_id: 1}
        ],
        capture_names: ["keyword", "function"],
        theme: %{"keyword" => [fg: 0xFF0000], "function" => [fg: 0x00FF00]}
      }

      result = Highlight.styles_for_line(hl, "def foo()", 0)
      assert [{"def", [fg: 0xFF0000]}, {" ", []}, {"foo", [fg: 0x00FF00]}, {"()", []}] = result
    end

    test "span crossing line boundary is clamped" do
      # Span covers bytes 0-20, but line is only bytes 5-10
      hl = %Highlight{
        version: 1,
        spans: [%{start_byte: 0, end_byte: 20, capture_id: 0}],
        capture_names: ["comment"],
        theme: %{"comment" => [fg: 0x888888, italic: true]}
      }

      result = Highlight.styles_for_line(hl, "hello", 5)
      assert [{"hello", [fg: 0x888888, italic: true]}] = result
    end

    test "span not overlapping this line is excluded" do
      hl = %Highlight{
        version: 1,
        spans: [%{start_byte: 100, end_byte: 110, capture_id: 0}],
        capture_names: ["keyword"],
        theme: %{"keyword" => [fg: 0xFF0000]}
      }

      result = Highlight.styles_for_line(hl, "hello", 0)
      assert [{"hello", []}] = result
    end

    test "unknown capture_id returns empty style" do
      hl = %Highlight{
        version: 1,
        spans: [%{start_byte: 0, end_byte: 3, capture_id: 99}],
        capture_names: ["keyword"],
        theme: %{"keyword" => [fg: 0xFF0000]}
      }

      result = Highlight.styles_for_line(hl, "def foo", 0)
      assert [{"def", []}, {" foo", []}] = result
    end

    test "overlapping spans are deduplicated (last wins for same range)" do
      # Tree-sitter often returns overlapping captures for the same node
      # (e.g. "@" matches both @attribute and @comment.doc).
      # Later patterns in the query are more specific and should win.
      hl = %Highlight{
        version: 1,
        spans: [
          %{start_byte: 0, end_byte: 9, capture_id: 0},
          %{start_byte: 0, end_byte: 9, capture_id: 1}
        ],
        capture_names: ["keyword", "keyword.function"],
        theme: %{
          "keyword" => [fg: 0xFF0000],
          "keyword.function" => [fg: 0x00FF00]
        }
      }

      result = Highlight.styles_for_line(hl, "defmodule Foo do", 0)

      # Should NOT produce "defmodule" twice
      all_text = Enum.map_join(result, fn {text, _} -> text end)
      assert all_text == "defmodule Foo do"

      # Last span wins for the overlapping region (tree-sitter priority)
      assert [{"defmodule", [fg: 0x00FF00]}, {" Foo do", []}] = result
    end

    test "partially overlapping spans don't duplicate text" do
      hl = %Highlight{
        version: 1,
        spans: [
          %{start_byte: 0, end_byte: 5, capture_id: 0},
          %{start_byte: 3, end_byte: 8, capture_id: 1}
        ],
        capture_names: ["keyword", "string"],
        theme: %{"keyword" => [fg: 0xFF0000], "string" => [fg: 0x00FF00]}
      }

      result = Highlight.styles_for_line(hl, "hello world", 0)
      all_text = Enum.map_join(result, fn {text, _} -> text end)
      assert all_text == "hello world"
    end

    test "with line_start_byte offset" do
      # "def foo\nbar baz" — line 2 starts at byte 8
      hl = %Highlight{
        version: 1,
        spans: [%{start_byte: 8, end_byte: 11, capture_id: 0}],
        capture_names: ["keyword"],
        theme: %{"keyword" => [fg: 0xFF0000]}
      }

      result = Highlight.styles_for_line(hl, "bar baz", 8)
      assert [{"bar", [fg: 0xFF0000]}, {" baz", []}] = result
    end
  end
end
