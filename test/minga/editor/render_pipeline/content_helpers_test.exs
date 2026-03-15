defmodule Minga.Editor.RenderPipeline.ContentHelpersTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Decorations
  alias Minga.Editor.RenderPipeline.ContentHelpers

  @search_colors %Minga.Theme.Search{
    highlight_bg: 0xECBE7B,
    highlight_fg: 0x282C34,
    current_bg: 0xFF6C6B
  }

  defp make_match(line, col, len) do
    %Minga.Search.Match{line: line, col: col, length: len}
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
          render: fn _w -> [{"Header v1", [bold: true]}] end,
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
          render: fn _w -> [{"Header A", [bold: true]}] end,
          priority: 10
        )

      {_id, decs_v2} =
        Decorations.add_block_decoration(decs_v2, 1,
          placement: :above,
          render: fn _w -> [{"Header B", [bold: true]}] end,
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
end
