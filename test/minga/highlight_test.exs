defmodule Minga.HighlightTest do
  use ExUnit.Case, async: true

  alias Minga.Highlight

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

    test "overlapping spans use first (pre-sorted by Zig with highest priority first)" do
      # Spans arrive from Zig sorted by (start_byte ASC, pattern_index DESC).
      # The most specific pattern comes first. First-wins picks it.
      # In tests, we simulate this by putting the specific span first.
      hl = %Highlight{
        version: 1,
        spans: [
          %{start_byte: 0, end_byte: 9, capture_id: 1},
          %{start_byte: 0, end_byte: 9, capture_id: 0}
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

      # First span (highest priority) wins for the overlapping region
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

    test "contained spans: inner overrides outer when sorted first" do
      # Spans pre-sorted by Zig: narrower (inner) before broader (outer)
      # at the same start_byte. Inner span at 0-2 comes first, wins for
      # its range, then outer covers the remainder.
      # String: #{content} = bytes: #(0) {(1) c(2) o(3) n(4) t(5) e(6) n(7) t(8) }(9)
      hl = %Highlight{
        version: 1,
        spans: [
          %{start_byte: 0, end_byte: 2, capture_id: 1},
          %{start_byte: 0, end_byte: 10, capture_id: 0},
          %{start_byte: 9, end_byte: 10, capture_id: 1}
        ],
        capture_names: ["embedded", "punctuation.special"],
        theme: %{
          "embedded" => [fg: 0xAAAAAA],
          "punctuation.special" => [fg: 0xFF0000]
        }
      }

      result = Highlight.styles_for_line(hl, "\#{content}", 0)
      all_text = Enum.map_join(result, fn {text, _} -> text end)
      assert all_text == "\#{content}"

      # Inner span wins for its range, outer covers the rest
      assert [
               {"\#{", [fg: 0xFF0000]},
               {"content}", [fg: 0xAAAAAA]}
             ] = result
    end

    test "three overlapping spans at same position: first (highest priority) wins" do
      # Spans arrive from Zig sorted by pattern_index DESC.
      # In this test, keyword has the highest priority so comes first.
      hl = %Highlight{
        version: 1,
        spans: [
          %{start_byte: 0, end_byte: 3, capture_id: 2},
          %{start_byte: 0, end_byte: 3, capture_id: 1},
          %{start_byte: 0, end_byte: 3, capture_id: 0}
        ],
        capture_names: ["variable", "function", "keyword"],
        theme: %{
          "variable" => [fg: 0x111111],
          "function" => [fg: 0x222222],
          "keyword" => [fg: 0x333333]
        }
      }

      result = Highlight.styles_for_line(hl, "def bar", 0)
      assert [{"def", [fg: 0x333333]}, {" bar", []}] = result
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
