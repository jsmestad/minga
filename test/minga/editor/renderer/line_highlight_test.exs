defmodule Minga.Editor.Renderer.LineHighlightTest do
  @moduledoc """
  Tests for line rendering with syntax highlighting.

  Tests the Line renderer directly with pre-populated highlight contexts,
  bypassing the full editor/port stack.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.Line, as: LineRenderer
  alias Minga.Editor.Viewport
  alias Minga.Highlight

  @keyword_color 0xFF0000
  @string_color 0x00FF00
  @comment_color 0x888888

  defp base_ctx(opts) do
    width = Keyword.get(opts, :width, 80)
    gutter_w = Keyword.get(opts, :gutter_w, 0)

    %Context{
      viewport: Viewport.new(24, width),
      gutter_w: gutter_w,
      content_w: width - gutter_w,
      highlight: Keyword.get(opts, :highlight, nil)
    }
  end

  defp highlight_with(spans, names, theme) do
    %Highlight{
      version: 1,
      spans: spans,
      capture_names: names,
      theme: theme,
      face_registry: Minga.Face.Registry.from_syntax(theme)
    }
  end

  defp decode_draw({row, col, text, style}) do
    %{
      row: row,
      col: col,
      text: text,
      fg: Keyword.get(style, :fg, 0xFFFFFF),
      bg: Keyword.get(style, :bg, 0x000000),
      attrs: decode_attrs(style)
    }
  end

  defp decode_attrs(style) do
    []
    |> then(fn a -> if Keyword.get(style, :bold, false), do: [:bold | a], else: a end)
    |> then(fn a -> if Keyword.get(style, :italic, false), do: [:italic | a], else: a end)
    |> then(fn a -> if Keyword.get(style, :underline, false), do: [:underline | a], else: a end)
    |> then(fn a -> if Keyword.get(style, :reverse, false), do: [:reverse | a], else: a end)
    |> Enum.reverse()
  end

  describe "rendering with syntax highlighting" do
    test "single span at start of line" do
      hl =
        highlight_with(
          [%{start_byte: 0, end_byte: 3, capture_id: 0}],
          ["keyword"],
          %{"keyword" => [fg: @keyword_color]}
        )

      ctx = base_ctx(highlight: hl)
      cmds = LineRenderer.render("def foo", 0, 0, ctx, 0)

      assert length(cmds) == 2

      first = decode_draw(Enum.at(cmds, 0))
      assert first.text == "def"
      assert first.fg == @keyword_color

      second = decode_draw(Enum.at(cmds, 1))
      assert second.text == " foo"
      assert second.fg == 0xFFFFFF
    end

    test "span in middle of line" do
      hl =
        highlight_with(
          [%{start_byte: 4, end_byte: 7, capture_id: 0}],
          ["string"],
          %{"string" => [fg: @string_color]}
        )

      ctx = base_ctx(highlight: hl)
      cmds = LineRenderer.render("x = :ok + 1", 0, 0, ctx, 0)

      assert length(cmds) == 3

      first = decode_draw(Enum.at(cmds, 0))
      assert first.text == "x = "

      second = decode_draw(Enum.at(cmds, 1))
      assert second.text == ":ok"
      assert second.fg == @string_color

      third = decode_draw(Enum.at(cmds, 2))
      assert third.text == " + 1"
    end

    test "multiple spans on one line" do
      hl =
        highlight_with(
          [
            %{start_byte: 0, end_byte: 3, capture_id: 0},
            %{start_byte: 4, end_byte: 7, capture_id: 1}
          ],
          ["keyword", "function"],
          %{"keyword" => [fg: @keyword_color], "function" => [fg: @string_color]}
        )

      ctx = base_ctx(highlight: hl)
      cmds = LineRenderer.render("def foo()", 0, 0, ctx, 0)

      texts = Enum.map(cmds, fn cmd -> decode_draw(cmd).text end)
      assert texts == ["def", " ", "foo", "()"]
    end

    test "span on second line with byte offset" do
      # "def foo\nbar baz" — line 2 starts at byte 8
      hl =
        highlight_with(
          [%{start_byte: 8, end_byte: 11, capture_id: 0}],
          ["keyword"],
          %{"keyword" => [fg: @keyword_color]}
        )

      ctx = base_ctx(highlight: hl)
      cmds = LineRenderer.render("bar baz", 1, 1, ctx, 8)

      first = decode_draw(Enum.at(cmds, 0))
      assert first.text == "bar"
      assert first.fg == @keyword_color
    end

    test "span crossing line boundary is clamped" do
      # Span covers bytes 0-50, but we render line at bytes 5-10
      hl =
        highlight_with(
          [%{start_byte: 0, end_byte: 50, capture_id: 0}],
          ["comment"],
          %{"comment" => [fg: @comment_color, italic: true]}
        )

      ctx = base_ctx(highlight: hl)
      cmds = LineRenderer.render("hello", 0, 1, ctx, 5)

      assert length(cmds) == 1
      first = decode_draw(Enum.at(cmds, 0))
      assert first.text == "hello"
      assert first.fg == @comment_color
    end

    test "no spans overlapping line renders unstyled" do
      hl =
        highlight_with(
          [%{start_byte: 100, end_byte: 110, capture_id: 0}],
          ["keyword"],
          %{"keyword" => [fg: @keyword_color]}
        )

      ctx = base_ctx(highlight: hl)
      cmds = LineRenderer.render("hello", 0, 0, ctx, 0)

      assert length(cmds) == 1
      first = decode_draw(Enum.at(cmds, 0))
      assert first.text == "hello"
      assert first.fg == 0xFFFFFF
    end

    test "nil highlight falls through to search highlight path" do
      ctx = base_ctx(highlight: nil)
      cmds = LineRenderer.render("hello world", 0, 0, ctx, 0)

      # Should render without errors (basic unstyled line)
      assert cmds != []
      first = decode_draw(Enum.at(cmds, 0))
      assert String.contains?(first.text, "hello")
    end

    test "with gutter offset, columns are shifted" do
      hl =
        highlight_with(
          [%{start_byte: 0, end_byte: 3, capture_id: 0}],
          ["keyword"],
          %{"keyword" => [fg: @keyword_color]}
        )

      ctx = base_ctx(highlight: hl, gutter_w: 4)
      cmds = LineRenderer.render("def foo", 0, 0, ctx, 0)

      first = decode_draw(Enum.at(cmds, 0))
      assert first.col == 4
    end

    test "overlapping spans do not produce duplicated text on screen" do
      # Reproduces the bug where tree-sitter returns multiple captures for
      # the same node (e.g. "defmodule" matching both @keyword and
      # @keyword.function), causing text to render multiple times.
      hl =
        highlight_with(
          [
            %{start_byte: 0, end_byte: 9, capture_id: 0},
            %{start_byte: 0, end_byte: 9, capture_id: 1},
            %{start_byte: 0, end_byte: 9, capture_id: 0},
            %{start_byte: 10, end_byte: 13, capture_id: 1}
          ],
          ["keyword", "keyword.function"],
          %{"keyword" => [fg: @keyword_color], "keyword.function" => [fg: @string_color]}
        )

      ctx = base_ctx(highlight: hl)
      cmds = LineRenderer.render("defmodule Foo do", 0, 0, ctx, 0)

      # Concatenate all rendered text — must equal the original line exactly once
      all_text = Enum.map_join(cmds, fn cmd -> decode_draw(cmd).text end)
      assert all_text == "defmodule Foo do"
    end

    test "visual selection takes priority over highlight" do
      hl =
        highlight_with(
          [%{start_byte: 0, end_byte: 3, capture_id: 0}],
          ["keyword"],
          %{"keyword" => [fg: @keyword_color]}
        )

      ctx = %{base_ctx(highlight: hl) | visual_selection: {:line, 0, 0}}
      cmds = LineRenderer.render("def foo", 0, 0, ctx, 0)

      # Should render as full reverse (visual selection), not syntax colored
      first = decode_draw(Enum.at(cmds, 0))
      assert :reverse in first.attrs
    end
  end
end
