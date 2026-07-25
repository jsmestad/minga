defmodule MingaEditor.RenderPipeline.ContentHelpersTest do
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations
  alias Minga.Language.Highlight.Span
  alias MingaEditor.UI.Theme
  alias MingaEditor.Renderer.Context
  alias MingaEditor.RenderPipeline.ContentHelpers
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.UI.Highlight
  alias MingaEditor.State.Highlighting
  alias MingaEditor.Viewport

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
        |> Highlight.put_spans(1, [Span.new(0, 3, 0)])

      after_fp = ContentHelpers.context_fingerprint(%{ctx | highlight: highlight}, true)

      refute before_fp == after_fp
    end

    test "changes when syntax highlight version changes" do
      highlight_v1 =
        Highlight.new()
        |> Highlight.put_names(["keyword"])
        |> Highlight.put_spans(1, [Span.new(0, 3, 0)])

      highlight_v2 =
        Highlight.put_spans(highlight_v1, 2, [Span.new(4, 7, 0)])

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
        |> Highlight.put_spans(1, [Span.new(0, 3, 0)])

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

    test "changes when the width oracle revision changes" do
      oracle = %Minga.Core.WidthOracle.Measured{cache: %{"hello" => 2}, revision: 0}

      ctx = %Context{
        viewport: Viewport.new(20, 80),
        gutter_w: 4,
        content_w: 76,
        width_oracle: oracle
      }

      changed = %{oracle | revision: 1}

      refute ContentHelpers.context_fingerprint(ctx, true) ==
               ContentHelpers.context_fingerprint(%{ctx | width_oracle: changed}, true)
    end
  end

  describe "build_render_ctx/3" do
    test "threads the supplied width oracle into the render context" do
      editor = TestHelpers.base_state()
      state = MingaEditor.RenderPipeline.Input.from_editor_state(editor)
      window = state.windows.map[state.windows.active]
      oracle = %Minga.Core.WidthOracle.Measured{cache: %{"hello" => 2}}

      {ctx, _state} =
        ContentHelpers.build_render_ctx(state, window, %{
          viewport: window.viewport,
          cursor: {0, 0},
          lines: ["hello"],
          first_line: 0,
          preview_matches: [],
          gutter_w: 4,
          content_w: 10,
          has_sign_column: true,
          is_active: true,
          wrap_on: false,
          line_number_style: :absolute,
          width_oracle: oracle
        })

      assert ctx.width_oracle == oracle
    end

    test "composes semantic layer without mutating parser or LSP owners and honors face overrides" do
      editor = TestHelpers.base_state()
      state = MingaEditor.RenderPipeline.Input.from_editor_state(editor)
      buffer = state.workspace.buffers.active
      window = state.windows.map[state.windows.active]

      parser =
        Highlight.new(%{"keyword" => [fg: 0xFF0000], "@lsp.type.variable" => [fg: 0x00FF00]})
        |> Highlight.put_names(["keyword"])
        |> Highlight.put_spans(1, [Span.new(0, 5, 0)])

      semantic = {0, {"@lsp.type.variable"}, {Span.new(0, 5, 0, 0, 2)}}

      override =
        Highlight.new(%{"keyword" => [fg: 0xFF0000], "@lsp.type.variable" => [fg: 0x123456]}).face_registry

      frame = %{
        state.intent.frame
        | highlighting:
            Highlighting.put_highlight(state.intent.frame.highlighting, buffer, parser),
          semantic_tokens: %{buffer => semantic},
          face_override_registries: %{buffer => override}
      }

      state = %{state | intent: %{state.intent | frame: frame}}

      ctx = ContentHelpers.window_highlight(state, window)

      assert [{"hello", face}] =
               Highlight.styles_for_visible_lines(ctx, [{"hello", 0}]) |> List.first()

      assert face.fg == 0x123456
      assert state.intent.frame.highlighting.highlights[buffer] == parser
      assert state.intent.frame.semantic_tokens[buffer] == semantic
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

      assert Enum.count(result1.block_decorations) == 1

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
      assert Enum.count(result2.block_decorations) == 2,
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

  describe "merge_cmd_hover_link_decoration/4 (#2630)" do
    setup do
      %{theme: Theme.get!(Theme.default())}
    end

    test "underlines the word range in the theme link color", %{theme: theme} do
      assert theme.editor.link_fg != nil, "builder themes must define an editor link color"

      {result, _cache} =
        ContentHelpers.merge_cmd_hover_link_decoration(
          Decorations.new(),
          {{0, 6}, {0, 11}},
          theme,
          nil
        )

      [highlight] = Decorations.highlights_for_line(result, 0)
      assert highlight.group == :cmd_hover_link
      assert highlight.start == {0, 6}
      assert highlight.end_ == {0, 11}
      assert highlight.style.underline == true
      assert highlight.style.fg == theme.editor.link_fg
    end

    test "a nil link clears any standing link decoration", %{theme: theme} do
      {with_link, cache} =
        ContentHelpers.merge_cmd_hover_link_decoration(
          Decorations.new(),
          {{0, 6}, {0, 11}},
          theme,
          nil
        )

      assert Decorations.highlights_for_line(with_link, 0) != []

      {cleared, _cache} =
        ContentHelpers.merge_cmd_hover_link_decoration(with_link, nil, theme, cache)

      assert Decorations.highlights_for_line(cleared, 0) == []
    end

    test "an unchanged link reuses the cached decorations", %{theme: theme} do
      decs = Decorations.new()
      link = {{0, 6}, {0, 11}}

      {result1, cache1} = ContentHelpers.merge_cmd_hover_link_decoration(decs, link, theme, nil)

      {result2, _cache2} =
        ContentHelpers.merge_cmd_hover_link_decoration(decs, link, theme, cache1)

      assert result2 == result1
    end
  end
end
