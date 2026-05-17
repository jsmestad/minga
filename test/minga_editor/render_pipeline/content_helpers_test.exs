defmodule MingaEditor.RenderPipeline.ContentHelpersTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Editing.Fold.Range, as: FoldRange
  alias MingaEditor.Renderer.Gutter
  alias MingaEditor.UI.Theme
  alias MingaEditor.Renderer.Context
  alias MingaEditor.RenderPipeline.ContentHelpers
  alias MingaEditor.UI.Highlight
  alias MingaEditor.Viewport
  alias MingaEditor.Window

  @search_colors %MingaEditor.UI.Theme.Search{
    highlight_bg: 0xECBE7B,
    highlight_fg: 0x282C34,
    current_bg: 0xFF6C6B
  }

  defp make_match(line, col, len) do
    %Minga.Editing.Search.Match{line: line, col: col, length: len}
  end

  describe "context_fingerprint/2" do
    test "changes when syntax highlight spans arrive" do
      ctx = %Context{viewport: Viewport.new(20, 80), gutter_w: 4, content_w: 76}
      before_fp = ContentHelpers.context_fingerprint(ctx, true)

      highlight =
        Highlight.new()
        |> Highlight.put_names(["keyword"])
        |> Highlight.put_spans(1, [%{start_byte: 0, end_byte: 3, capture_id: 0}])

      after_fp = ContentHelpers.context_fingerprint(%{ctx | highlight: highlight}, true)

      refute before_fp == after_fp
    end

    test "changes when syntax highlight version changes" do
      highlight_v1 =
        Highlight.new()
        |> Highlight.put_names(["keyword"])
        |> Highlight.put_spans(1, [%{start_byte: 0, end_byte: 3, capture_id: 0}])

      highlight_v2 =
        Highlight.put_spans(highlight_v1, 2, [%{start_byte: 4, end_byte: 7, capture_id: 0}])

      ctx = %Context{
        viewport: Viewport.new(20, 80),
        gutter_w: 4,
        content_w: 76,
        highlight: highlight_v1
      }

      refute ContentHelpers.context_fingerprint(ctx, true) ==
               ContentHelpers.context_fingerprint(%{ctx | highlight: highlight_v2}, true)
    end

    test "changes when highlight theme changes with the same spans" do
      highlight =
        Highlight.new()
        |> Highlight.put_names(["keyword"])
        |> Highlight.put_spans(1, [%{start_byte: 0, end_byte: 3, capture_id: 0}])

      themed_highlight = Highlight.new(Theme.get!(:one_light).syntax)

      themed_highlight = %{
        themed_highlight
        | version: highlight.version,
          spans: highlight.spans,
          capture_names: highlight.capture_names
      }

      ctx = %Context{
        viewport: Viewport.new(20, 80),
        gutter_w: 4,
        content_w: 76,
        highlight: highlight
      }

      refute ContentHelpers.context_fingerprint(ctx, true) ==
               ContentHelpers.context_fingerprint(%{ctx | highlight: themed_highlight}, true)
    end

    test "changes when chrome theme colors used by content change" do
      ctx = %Context{
        viewport: Viewport.new(20, 80),
        gutter_w: 4,
        content_w: 76,
        editor_bg: 0x111111
      }

      refute ContentHelpers.context_fingerprint(ctx, true) ==
               ContentHelpers.context_fingerprint(%{ctx | editor_bg: 0x222222}, true)
    end

    test "changes when search colors change" do
      ctx = %Context{
        viewport: Viewport.new(20, 80),
        gutter_w: 4,
        content_w: 76,
        search_colors: @search_colors
      }

      alt_colors = %{@search_colors | highlight_bg: 0x123456}

      refute ContentHelpers.context_fingerprint(ctx, true) ==
               ContentHelpers.context_fingerprint(%{ctx | search_colors: alt_colors}, true)
    end

    test "changes when document highlight colors change" do
      ctx = %Context{
        viewport: Viewport.new(20, 80),
        gutter_w: 4,
        content_w: 76,
        document_highlight_colors: {0x111111, 0x222222}
      }

      refute ContentHelpers.context_fingerprint(ctx, true) ==
               ContentHelpers.context_fingerprint(
                 %{
                   ctx
                   | document_highlight_colors: {0x333333, 0x444444}
                 },
                 true
               )
    end

    test "changes when wrap mode changes" do
      ctx = %Context{viewport: Viewport.new(20, 80), gutter_w: 4, content_w: 76, wrap_on: false}

      refute ContentHelpers.context_fingerprint(ctx, true) ==
               ContentHelpers.context_fingerprint(%{ctx | wrap_on: true}, true)
    end

    test "changes when line number style changes" do
      ctx = %Context{
        viewport: Viewport.new(20, 80),
        gutter_w: 4,
        content_w: 76,
        line_number_style: :absolute
      }

      refute ContentHelpers.context_fingerprint(ctx, true) ==
               ContentHelpers.context_fingerprint(%{ctx | line_number_style: :relative}, true)
    end
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

    test "different search colors rebuild cached decorations" do
      decs = Decorations.new()
      matches = [make_match(0, 0, 3)]
      alt_colors = %{@search_colors | highlight_bg: 0x123456}

      {_result1, cache1} =
        ContentHelpers.merge_search_decorations(decs, matches, nil, @search_colors, nil)

      {result2, _cache2} =
        ContentHelpers.merge_search_decorations(decs, matches, nil, alt_colors, cache1)

      [highlight] = Decorations.highlights_for_line(result2, 0)
      assert highlight.style.bg == 0x123456
    end
  end

  describe "render_lines_nowrap with visible_line_map and wrap_on" do
    setup do
      buf = start_supervised!({Minga.Buffer.Process, content: ""})
      viewport = Viewport.new(20, 20, 0)

      gutter_colors = %Theme.Gutter{
        fg: 0x111111,
        current_fg: 0x222222,
        error_fg: 0x333333,
        warning_fg: 0x444444,
        info_fg: 0x555555,
        hint_fg: 0x666666,
        fold_fg: 0xABCDEF
      }

      ctx = %Context{
        viewport: viewport,
        gutter_w: 6,
        content_w: 10,
        decorations: Decorations.new(),
        gutter_colors: gutter_colors
      }

      window = %Window{
        id: 1,
        content: Window.Content.buffer(buf),
        buffer: buf,
        viewport: viewport,
        render_cache: MingaEditor.Window.RenderCache.reset()
      }

      %{buf: buf, ctx: ctx, window: window}
    end

    test "expanded foldable lines render a down chevron in the gutter", %{
      ctx: ctx,
      window: window
    } do
      lines = ["defmodule Example do", "  def run, do: :ok", "end"]
      window = Window.set_fold_ranges(window, [FoldRange.new!(0, 2)])

      opts = %{
        first_line: 0,
        cursor_line: 0,
        ctx: ctx,
        ln_style: :absolute,
        gutter_w: 6,
        first_byte_off: 0,
        row_off: 0,
        col_off: 0,
        window: window,
        buffer: window.buffer
      }

      {gutter_layer, _content_layer, _rows, _window} =
        ContentHelpers.render_lines_nowrap_layers(lines, opts)

      assert {col, "▾", face} =
               Enum.find(Map.get(gutter_layer, 0), fn {_col, text, _face} -> text == "▾" end)

      assert col == Gutter.fold_column_offset()
      assert face.fg == ctx.gutter_colors.fold_fg
    end

    test "passes indent guide data through to buffer line rendering", %{ctx: ctx, window: window} do
      lines = ["def run do", "    child", "end"]

      ctx = %{
        ctx
        | tab_width: 2,
          cursor_col: 4,
          indent_guide_face: Minga.Core.Face.new(fg: 0x111111),
          indent_guide_active_face: Minga.Core.Face.new(fg: 0x222222)
      }

      opts = %{
        first_line: 0,
        cursor_line: 1,
        ctx: ctx,
        ln_style: :absolute,
        gutter_w: 6,
        first_byte_off: 0,
        row_off: 0,
        col_off: 0,
        window: window,
        buffer: window.buffer
      }

      {_gutter_layer, content_layer, _rows, _window} =
        ContentHelpers.render_lines_nowrap_layers(lines, opts)

      assert {8, "│", face} =
               Enum.find(Map.get(content_layer, 1), fn {col, text, _face} ->
                 col == 8 and text == "│"
               end)

      assert face.fg == 0x111111
    end

    test "fold indicators do not overwrite diagnostic signs", %{ctx: ctx, window: window} do
      lines = ["defmodule Example do", "  def run, do: :ok", "end"]
      window = Window.set_fold_ranges(window, [FoldRange.new!(0, 2)])
      ctx = %{ctx | diagnostic_signs: %{0 => :error}}

      opts = %{
        first_line: 0,
        cursor_line: 0,
        ctx: ctx,
        ln_style: :absolute,
        gutter_w: 6,
        first_byte_off: 0,
        row_off: 0,
        col_off: 0,
        window: window,
        buffer: window.buffer
      }

      {gutter_layer, _content_layer, _rows, _window} =
        ContentHelpers.render_lines_nowrap_layers(lines, opts)

      row = Map.get(gutter_layer, 0)

      assert {0, "E ", _diag_face} =
               Enum.find(row, fn {col, text, _face} -> col == 0 and text == "E " end)

      assert {2, "▾", _fold_face} =
               Enum.find(row, fn {col, text, _face} -> col == 2 and text == "▾" end)
    end

    test "folded lines render a right chevron in the gutter", %{ctx: ctx, window: window} do
      lines = ["defmodule Example do", "  def run, do: :ok", "end"]
      visible_line_map = [{0, {:fold_start, 2}}]

      opts = %{
        first_line: 0,
        cursor_line: 0,
        ctx: ctx,
        ln_style: :absolute,
        gutter_w: 6,
        row_off: 0,
        col_off: 0,
        window: window,
        visible_line_map: visible_line_map,
        fold_map: %MingaEditor.FoldMap{folds: []}
      }

      {gutter_draws, _line_draws, _rendered_rows, _window} =
        ContentHelpers.render_lines_nowrap(lines, opts)

      assert {_row, _col, "▸", face} =
               Enum.find(gutter_draws, fn {_row, _col, text, _face} -> text == "▸" end)

      assert face.fg == ctx.gutter_colors.fold_fg
    end

    test "custom decoration fold placeholders render chevron in the fold column", %{
      ctx: ctx,
      window: window
    } do
      lines = ["agent output", "line two", "line three"]

      {_id, decorations} =
        Decorations.add_fold_region(Decorations.new(), 0, 2,
          closed: true,
          placeholder: fn _start_line, _end_line, _width ->
            [{"custom placeholder", Minga.Core.Face.new(fg: 0xEEEEEE)}]
          end
        )

      [fold] = Decorations.closed_fold_regions(decorations)
      ctx = %{ctx | decorations: decorations}

      opts = %{
        first_line: 0,
        cursor_line: 0,
        ctx: ctx,
        ln_style: :absolute,
        gutter_w: 6,
        row_off: 0,
        col_off: 0,
        window: window,
        visible_line_map: [{0, {:decoration_fold, fold}}],
        fold_map: %MingaEditor.FoldMap{folds: []}
      }

      {gutter_draws, line_draws, _rendered_rows, _window} =
        ContentHelpers.render_lines_nowrap(lines, opts)

      assert {_row, col, "▸", face} =
               Enum.find(gutter_draws, fn {_row, _col, text, _face} -> text == "▸" end)

      assert {_row, content_col, "custom placeholder", _face} =
               Enum.find(line_draws, fn {_row, _col, text, _face} ->
                 text == "custom placeholder"
               end)

      assert col == Gutter.fold_column_offset()
      assert content_col == ctx.gutter_w
      assert face.fg == ctx.gutter_colors.fold_fg
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
        gutter_w: 6,
        row_off: 0,
        col_off: 0,
        window: window,
        visible_line_map: visible_line_map,
        fold_map: %MingaEditor.FoldMap{folds: []},
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
        gutter_w: 6,
        row_off: 0,
        col_off: 0,
        window: window,
        visible_line_map: visible_line_map,
        fold_map: %MingaEditor.FoldMap{folds: []},
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
