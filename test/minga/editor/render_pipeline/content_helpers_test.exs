defmodule Minga.Editor.RenderPipeline.ContentHelpersTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.RenderPipeline.ContentHelpers
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window

  @search_colors %Minga.UI.Theme.Search{
    highlight_bg: 0xECBE7B,
    highlight_fg: 0x282C34,
    current_bg: 0xFF6C6B
  }

  defp make_match(line, col, len) do
    %Minga.Editing.Search.Match{line: line, col: col, length: len}
  end

  describe "merge_search_decorations/5" do
    test "cache hit when search and base version match" do
      decs = Decorations.new()
      matches = [make_match(0, 0, 3)]

      {result1, cache1} =
        ContentHelpers.merge_search_decorations(decs, matches, nil, @search_colors, nil)

      assert Decorations.highlight_count(result1) > 0

      # Same matches, same base version: cache hit returns identical result
      {result2, _cache2} =
        ContentHelpers.merge_search_decorations(decs, matches, nil, @search_colors, cache1)

      assert result2 == result1
    end

    test "cache invalidates when base decoration version changes" do
      # Frame 1: base decorations with a block decoration
      decs_v1 = Decorations.new()

      {_id, decs_v1} =
        Decorations.add_block_decoration(decs_v1, 0,
          placement: :above,
          render: fn _w -> [{"Header v1", Minga.Core.Face.new(bold: true)}] end,
          priority: 10
        )

      matches = [make_match(0, 0, 3)]

      {result1, cache1} =
        ContentHelpers.merge_search_decorations(decs_v1, matches, nil, @search_colors, nil)

      assert length(result1.block_decorations) == 1

      # Frame 2: base decorations updated (new block decoration, higher version)
      decs_v2 = Decorations.new()

      {_id, decs_v2} =
        Decorations.add_block_decoration(decs_v2, 0,
          placement: :above,
          render: fn _w -> [{"Header A", Minga.Core.Face.new(bold: true)}] end,
          priority: 10
        )

      {_id, decs_v2} =
        Decorations.add_block_decoration(decs_v2, 1,
          placement: :above,
          render: fn _w -> [{"Header B", Minga.Core.Face.new(bold: true)}] end,
          priority: 10
        )

      # Same search matches, but stale cache (base version changed)
      {result2, _cache2} =
        ContentHelpers.merge_search_decorations(decs_v2, matches, nil, @search_colors, cache1)

      # Regression: previously returned result1's stale decorations (1 block).
      # Must return result built on decs_v2 (2 blocks).
      assert length(result2.block_decorations) == 2,
             "fresh block decorations must survive search cache invalidation"
    end

    test "different search matches always rebuild" do
      decs = Decorations.new()
      matches1 = [make_match(0, 0, 3)]
      matches2 = [make_match(1, 5, 4)]

      {_result1, cache1} =
        ContentHelpers.merge_search_decorations(decs, matches1, nil, @search_colors, nil)

      {result2, _cache2} =
        ContentHelpers.merge_search_decorations(decs, matches2, nil, @search_colors, cache1)

      # Different matches: must rebuild, not return cached
      highlights = Decorations.highlights_for_line(result2, 1)
      assert highlights != [], "new search match on line 1 should produce a highlight"
    end
  end

  describe "render_lines_nowrap with visible_line_map and wrap_on" do
    setup do
      buf = start_supervised!({Minga.Buffer.Server, content: ""})
      viewport = Viewport.new(20, 20, 0)

      ctx = %Context{
        viewport: viewport,
        gutter_w: 3,
        content_w: 10,
        decorations: Decorations.new()
      }

      window = %Window{
        id: 1,
        content: Window.Content.buffer(buf),
        buffer: buf,
        viewport: viewport,
        dirty_lines: :all
      }

      %{buf: buf, ctx: ctx, window: window}
    end

    test "wrapped lines at screen_row > 0 render all visual rows", %{ctx: ctx, window: window} do
      # Line 0: short (1 row). Line 1: long, wraps to 2+ rows at content_w=10.
      lines = ["short", "this line is longer than ten columns wide"]

      # Both are normal buffer lines
      visible_line_map = [{0, :normal}, {1, :normal}]

      opts = %{
        first_line: 0,
        cursor_line: 0,
        ctx: ctx,
        ln_style: :absolute,
        gutter_w: 3,
        row_off: 0,
        col_off: 0,
        window: window,
        visible_line_map: visible_line_map,
        fold_map: %Minga.Editor.FoldMap{folds: []},
        wrap_on: true
      }

      {_gutter_draws, line_draws, rendered_rows, _window} =
        ContentHelpers.render_lines_nowrap(lines, opts)

      # Line 0 takes 1 row. Line 1 wraps to multiple rows at width 10.
      # Total rendered_rows must be > 2 (proving wrapping happened).
      assert rendered_rows > 2,
             "expected wrapped lines to consume more than 2 rows, got #{rendered_rows}"

      # There must be draw commands for rows beyond row 1 (the wrap continuation rows).
      # Each draw is a {row, col, text, style} tuple.
      draw_rows = line_draws |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      assert length(draw_rows) > 2,
             "expected draw commands on 3+ rows for wrapped content, got rows: #{inspect(draw_rows)}"
    end

    test "multiple wrapped lines each get correct row count", %{ctx: ctx, window: window} do
      # Three lines, each longer than content_w=10
      lines = [
        "first line that wraps around",
        "second line also wraps here",
        "third wrapping line content"
      ]

      visible_line_map = [{0, :normal}, {1, :normal}, {2, :normal}]

      opts = %{
        first_line: 0,
        cursor_line: 0,
        ctx: ctx,
        ln_style: :absolute,
        gutter_w: 3,
        row_off: 0,
        col_off: 0,
        window: window,
        visible_line_map: visible_line_map,
        fold_map: %Minga.Editor.FoldMap{folds: []},
        wrap_on: true
      }

      {_gutter_draws, _line_draws, rendered_rows, _window} =
        ContentHelpers.render_lines_nowrap(lines, opts)

      # Each 27-28 char line at width 10 should wrap to 3 rows.
      # Total should be ~9 rows (3 lines × 3 rows each).
      assert rendered_rows >= 6,
             "expected at least 6 rendered rows for 3 wrapped lines, got #{rendered_rows}"
    end
  end
end
