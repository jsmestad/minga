defmodule Minga.Editor.Renderer.Line do
  @moduledoc """
  Line content rendering with visual selection and search highlight support.

  All column positions are in **display columns** (terminal columns), not
  grapheme counts. Wide characters (CJK, emoji) occupy 2 columns; combining
  marks occupy 0. The `viewport.left` field and `sel_start`/`sel_end` values
  passed to this module are already in display columns.

  Visual selection bounds use an **exclusive** end column convention:
  `sel_end` is the first display column *after* the last selected grapheme,
  so `selection_width = sel_end - sel_start` works correctly for wide chars.

  All render functions return `DisplayList.draw()` tuples.
  """

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Unicode
  alias Minga.Editor.DisplayList
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.SearchHighlight
  alias Minga.Highlight

  @typedoc "Column range of a selection on a single line (display columns, end exclusive)."
  @type line_selection :: nil | :full | {non_neg_integer(), non_neg_integer()}

  @typedoc "A grapheme paired with its display width."
  @type grapheme_pair :: {String.t(), non_neg_integer()}

  @doc "Renders a single buffer line into draw tuples, including virtual text decorations."
  @spec render(String.t(), non_neg_integer(), non_neg_integer(), Context.t(), non_neg_integer()) ::
          [DisplayList.draw()]
  def render(line_text, screen_row, buf_line, %Context{} = ctx, line_byte_offset \\ 0) do
    pairs = grapheme_pairs(line_text)
    line_display_len = display_width_of_pairs(pairs)

    visible_pairs =
      pairs
      |> display_drop(ctx.viewport.left)
      |> display_take(ctx.content_w)

    # Query decoration highlights once per line, reuse across render paths
    line_highlights =
      if Decorations.empty?(ctx.decorations) do
        []
      else
        Decorations.highlights_for_line(ctx.decorations, buf_line)
      end

    case selection_cols_for_line(buf_line, line_display_len, ctx.visual_selection) do
      nil when ctx.highlight != nil ->
        render_highlighted_line(
          line_text,
          screen_row,
          buf_line,
          ctx,
          line_byte_offset,
          line_highlights
        )

      nil when line_highlights != [] ->
        # No syntax highlighting but has decorations: render through the
        # styled-segment path so decorations are applied
        render_decorated_plain_line(line_text, screen_row, buf_line, ctx, line_highlights)

      nil ->
        visible_graphemes = Enum.map(visible_pairs, fn {g, _} -> g end)

        SearchHighlight.render_line_with_search(
          visible_graphemes,
          screen_row,
          buf_line,
          ctx.viewport,
          ctx.search_matches,
          ctx.gutter_w,
          ctx.confirm_match,
          ctx.search_colors
        )

      :full ->
        visible_text = join_pairs(visible_pairs)
        [DisplayList.draw(screen_row, ctx.gutter_w, visible_text, reverse: true)]

      {sel_start, sel_end} ->
        render_partial_selection(
          visible_pairs,
          screen_row,
          ctx.gutter_w,
          ctx.viewport.left,
          sel_start,
          sel_end
        )
    end
    |> append_eol_virtual_text(screen_row, buf_line, line_display_len, ctx)
  end

  # Appends EOL virtual text draw commands after the line content.
  # EOL text appears after the last character, separated by one space.
  @spec append_eol_virtual_text(
          [DisplayList.draw()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Context.t()
        ) :: [DisplayList.draw()]
  defp append_eol_virtual_text(draws, _screen_row, _buf_line, _line_len, %{
         decorations: %{virtual_texts: []}
       }),
       do: draws

  defp append_eol_virtual_text(draws, screen_row, buf_line, line_display_len, ctx) do
    eol_vts = Decorations.eol_virtual_texts_for_line(ctx.decorations, buf_line)

    if eol_vts == [] do
      draws
    else
      # EOL text starts after the line content + 1 space separator,
      # adjusted for viewport horizontal scroll
      eol_start = max(line_display_len + 1 - ctx.viewport.left, 0) + ctx.gutter_w

      {eol_draws, _col} =
        Enum.reduce(eol_vts, {[], eol_start}, fn vt, {acc, col} ->
          render_virtual_text_segments(vt.segments, screen_row, col, acc)
        end)

      draws ++ Enum.reverse(eol_draws)
    end
  end

  # Renders styled virtual text segments into draw commands.
  @spec render_virtual_text_segments(
          [Decorations.VirtualText.segment()],
          non_neg_integer(),
          non_neg_integer(),
          [DisplayList.draw()]
        ) :: {[DisplayList.draw()], non_neg_integer()}
  defp render_virtual_text_segments(segments, screen_row, start_col, acc) do
    Enum.reduce(segments, {acc, start_col}, fn {text, style}, {draws, col} ->
      width = Unicode.display_width(text)
      draw = DisplayList.draw(screen_row, col, text, style)
      {[draw | draws], col + width}
    end)
  end

  # ── Display-width helpers ─────────────────────────────────────────────────

  # Converts a string to a list of {grapheme, display_width} pairs.
  @spec grapheme_pairs(String.t()) :: [grapheme_pair()]
  defp grapheme_pairs(text) do
    text
    |> String.graphemes()
    |> Enum.map(fn g -> {g, Unicode.grapheme_width(g)} end)
  end

  # Returns the total display width of a list of {grapheme, width} pairs.
  @spec display_width_of_pairs([grapheme_pair()]) :: non_neg_integer()
  defp display_width_of_pairs(pairs) do
    Enum.reduce(pairs, 0, fn {_, w}, acc -> acc + w end)
  end

  # Joins grapheme pairs back to a string.
  @spec join_pairs([grapheme_pair()]) :: String.t()
  defp join_pairs(pairs) do
    Enum.map_join(pairs, fn {g, _} -> g end)
  end

  # Drops graphemes from the front until `n` display columns have been consumed.
  # If a wide character straddles the boundary (e.g. viewport.left=1 but a CJK
  # char occupies cols 0-1), that character is skipped entirely — matching
  # terminal behaviour where a half-consumed wide char cell is left blank.
  @spec display_drop([grapheme_pair()], non_neg_integer()) :: [grapheme_pair()]
  defp display_drop(pairs, 0), do: pairs
  defp display_drop([], _n), do: []

  defp display_drop([{_g, w} | rest], n) when w <= n do
    display_drop(rest, n - w)
  end

  defp display_drop([{_g, _w} | rest], _n) do
    # Wide char straddles boundary — skip it
    rest
  end

  # Takes graphemes from the front until adding the next one would exceed `n`
  # display columns. A wide character that would overflow is omitted.
  @spec display_take([grapheme_pair()], non_neg_integer()) :: [grapheme_pair()]
  defp display_take(pairs, n), do: do_display_take(pairs, n, [])

  @spec do_display_take([grapheme_pair()], non_neg_integer(), [grapheme_pair()]) ::
          [grapheme_pair()]
  defp do_display_take([], _n, acc), do: Enum.reverse(acc)
  defp do_display_take(_pairs, 0, acc), do: Enum.reverse(acc)

  defp do_display_take([{g, w} | rest], n, acc) when w <= n do
    do_display_take(rest, n - w, [{g, w} | acc])
  end

  defp do_display_take(_pairs, _n, acc) do
    # Next char would overflow — stop here
    Enum.reverse(acc)
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec render_partial_selection(
          [grapheme_pair()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [DisplayList.draw()]
  defp render_partial_selection(visible_pairs, screen_row, gutter_w, left, sel_start, sel_end) do
    # sel_start is inclusive, sel_end is exclusive — both in display columns.
    # selection width = sel_end - max(sel_start, left), no +1 needed.
    before_cols = max(0, sel_start - left)
    sel_cols = sel_end - max(sel_start, left)

    before_pairs = display_take(visible_pairs, before_cols)
    remaining = display_drop(visible_pairs, before_cols)
    sel_pairs = display_take(remaining, sel_cols)
    after_pairs = display_drop(remaining, sel_cols)

    before_text = join_pairs(before_pairs)
    before_width = display_width_of_pairs(before_pairs)
    sel_text = join_pairs(sel_pairs)
    sel_width = display_width_of_pairs(sel_pairs)
    after_text = join_pairs(after_pairs)

    [
      DisplayList.draw(screen_row, gutter_w, before_text),
      DisplayList.draw(
        screen_row,
        gutter_w + before_width,
        sel_text,
        reverse: true
      ),
      DisplayList.draw(
        screen_row,
        gutter_w + before_width + sel_width,
        after_text
      )
    ]
  end

  @spec selection_cols_for_line(
          non_neg_integer(),
          non_neg_integer(),
          Context.visual_selection()
        ) :: line_selection()
  defp selection_cols_for_line(_buf_line, _line_display_len, nil), do: nil

  defp selection_cols_for_line(buf_line, _line_display_len, {:line, start_line, end_line}) do
    if buf_line >= start_line and buf_line <= end_line, do: :full, else: nil
  end

  defp selection_cols_for_line(
         buf_line,
         _line_display_len,
         {:char, {start_line, _sc}, {end_line, _ec}}
       )
       when buf_line < start_line or buf_line > end_line,
       do: nil

  defp selection_cols_for_line(
         _buf_line,
         _line_display_len,
         {:char, {same, start_col}, {same, end_col}}
       ),
       do: {start_col, end_col}

  defp selection_cols_for_line(
         buf_line,
         line_display_len,
         {:char, {buf_line, start_col}, _end_pos}
       ),
       # Exclusive end = total line display width (one past the last column)
       do: {start_col, line_display_len}

  defp selection_cols_for_line(
         buf_line,
         _line_display_len,
         {:char, _start_pos, {buf_line, end_col}}
       ),
       do: {0, end_col}

  defp selection_cols_for_line(_buf_line, _line_display_len, {:char, _start_pos, _end_pos}),
    do: :full

  # ── Decorated plain line (no tree-sitter, has decorations) ──────────────────

  # Renders a plain-text line (no tree-sitter) with decoration highlight ranges.
  # Uses the same segment-based rendering as syntax-highlighted lines, but
  # starts with the entire line as a single unstyled segment.
  @spec render_decorated_plain_line(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Context.t(),
          [Decorations.highlight_range()]
        ) :: [DisplayList.draw()]
  defp render_decorated_plain_line(line_text, screen_row, buf_line, ctx, line_highlights) do
    segments = [{line_text, []}]
    segments = Decorations.merge_highlights(segments, line_highlights, buf_line)
    segments = inject_inline_virtual_text(segments, ctx.decorations, buf_line)
    render_segments_with_scroll(segments, screen_row, ctx)
  end

  # ── Inline virtual text injection ────────────────────────────────────────────

  # Injects inline virtual text segments into the styled segment list at their
  # anchor column positions, displacing subsequent content rightward.
  # Virtual text segments are tagged with {:virtual, true} in their style so
  # selection rendering can skip them.
  @spec inject_inline_virtual_text(
          [{String.t(), keyword()}],
          Decorations.t(),
          non_neg_integer()
        ) :: [{String.t(), keyword()}]
  defp inject_inline_virtual_text(segments, decorations, buf_line) do
    inline_vts = Decorations.inline_virtual_texts_for_line(decorations, buf_line)

    if inline_vts == [] do
      segments
    else
      do_inject_inline(segments, inline_vts, 0, [])
    end
  end

  # Walk through segments, tracking the current buffer column. When a virtual
  # text's anchor column falls within the current segment, split the segment
  # and insert the virtual text segments between the halves.
  @spec do_inject_inline(
          [{String.t(), keyword()}],
          [Decorations.VirtualText.t()],
          non_neg_integer(),
          [{String.t(), keyword()}]
        ) :: [{String.t(), keyword()}]
  defp do_inject_inline([], remaining_vts, _col, acc) do
    # Append any remaining virtual texts after all buffer content
    vt_segments =
      Enum.flat_map(remaining_vts, fn vt ->
        Enum.map(vt.segments, fn {text, style} ->
          {text, Keyword.put(style, :virtual, true)}
        end)
      end)

    Enum.reverse(acc, vt_segments)
  end

  defp do_inject_inline(segments, [], _col, acc) do
    # No more virtual texts to inject, append remaining segments
    Enum.reverse(acc, segments)
  end

  defp do_inject_inline(
         [{seg_text, seg_style} | rest_segs],
         [%{anchor: {_l, anchor_col}} = vt | rest_vts],
         col,
         acc
       ) do
    seg_width = Unicode.display_width(seg_text)
    seg_end = col + seg_width

    inject_at_position(
      {seg_text, seg_style},
      rest_segs,
      vt,
      rest_vts,
      col,
      seg_end,
      anchor_col,
      acc
    )
  end

  # Virtual text anchor is at or before the current segment start: inject before
  @spec inject_at_position(
          {String.t(), keyword()},
          [{String.t(), keyword()}],
          Decorations.VirtualText.t(),
          [Decorations.VirtualText.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [{String.t(), keyword()}]
        ) :: [{String.t(), keyword()}]
  defp inject_at_position(seg, rest_segs, vt, rest_vts, col, _seg_end, anchor_col, acc)
       when anchor_col <= col do
    vt_segs = tag_virtual_segments(vt.segments)
    do_inject_inline([seg | rest_segs], rest_vts, col, vt_segs ++ acc)
  end

  # Virtual text anchor is within the current segment: split and inject
  defp inject_at_position(
         {seg_text, seg_style},
         rest_segs,
         vt,
         rest_vts,
         col,
         seg_end,
         anchor_col,
         acc
       )
       when anchor_col < seg_end do
    split_at = anchor_col - col
    {before_text, after_text} = split_text_at_display_col(seg_text, split_at)
    vt_segs = tag_virtual_segments(vt.segments)

    after_part = if after_text != "", do: [{after_text, seg_style}], else: []
    new_acc = after_part ++ vt_segs ++ [{before_text, seg_style} | acc]
    do_inject_inline(rest_segs, rest_vts, seg_end, new_acc)
  end

  # Virtual text anchor is after the current segment: skip segment, keep going
  defp inject_at_position(
         {seg_text, seg_style},
         rest_segs,
         vt,
         rest_vts,
         _col,
         seg_end,
         _anchor_col,
         acc
       ) do
    do_inject_inline(rest_segs, [vt | rest_vts], seg_end, [{seg_text, seg_style} | acc])
  end

  @spec tag_virtual_segments([{String.t(), keyword()}]) :: [{String.t(), keyword()}]
  defp tag_virtual_segments(segments) do
    Enum.map(segments, fn {text, style} ->
      {text, Keyword.put(style, :virtual, true)}
    end)
  end

  # Split text at a display column position (not byte or grapheme index).
  @spec split_text_at_display_col(String.t(), non_neg_integer()) :: {String.t(), String.t()}
  defp split_text_at_display_col(text, display_col) do
    graphemes = String.graphemes(text)

    {before_acc, after_acc, _} =
      Enum.reduce(graphemes, {[], [], 0}, fn g, {bef, aft, col} ->
        w = Unicode.grapheme_width(g)

        if col < display_col do
          {[g | bef], aft, col + w}
        else
          {bef, [g | aft], col + w}
        end
      end)

    {before_acc |> Enum.reverse() |> Enum.join(), after_acc |> Enum.reverse() |> Enum.join()}
  end

  # ── Syntax highlighting ──────────────────────────────────────────────────────

  @spec render_highlighted_line(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Context.t(),
          non_neg_integer(),
          [Decorations.highlight_range()]
        ) ::
          [DisplayList.draw()]
  defp render_highlighted_line(
         line_text,
         screen_row,
         buf_line,
         ctx,
         line_byte_offset,
         line_highlights
       ) do
    segments = Highlight.styles_for_line(ctx.highlight, line_text, line_byte_offset)

    # Merge decoration highlight ranges with syntax segments (pre-queried, no double lookup)
    segments = Decorations.merge_highlights(segments, line_highlights, buf_line)
    segments = inject_inline_virtual_text(segments, ctx.decorations, buf_line)

    render_segments_with_scroll(segments, screen_row, ctx)
  end

  # Shared rendering for styled segments with horizontal scroll clipping.
  # Used by both syntax-highlighted and decorated-plain-text paths.
  @spec render_segments_with_scroll(
          [{String.t(), keyword()}],
          non_neg_integer(),
          Context.t()
        ) :: [DisplayList.draw()]
  defp render_segments_with_scroll(segments, screen_row, ctx) do
    {commands, _screen_col, _buf_col} =
      Enum.reduce(segments, {[], 0, 0}, fn {text, style}, {cmds, screen_col, buf_col} ->
        render_segment_with_scroll(text, style, screen_row, ctx, cmds, screen_col, buf_col)
      end)

    Enum.reverse(commands)
  end

  @spec render_segment_with_scroll(
          String.t(),
          keyword(),
          non_neg_integer(),
          Context.t(),
          [DisplayList.draw()],
          non_neg_integer(),
          non_neg_integer()
        ) :: {[DisplayList.draw()], non_neg_integer(), non_neg_integer()}
  defp render_segment_with_scroll(text, style, screen_row, ctx, cmds, screen_col, buf_col) do
    seg_end = buf_col + Unicode.display_width(text)
    scroll_segment(seg_end, text, style, screen_row, ctx, cmds, screen_col, buf_col)
  end

  # Segment is entirely before the viewport left edge: skip
  @spec scroll_segment(
          non_neg_integer(),
          String.t(),
          keyword(),
          non_neg_integer(),
          Context.t(),
          [DisplayList.draw()],
          non_neg_integer(),
          non_neg_integer()
        ) :: {[DisplayList.draw()], non_neg_integer(), non_neg_integer()}
  defp scroll_segment(
         seg_end,
         _text,
         _style,
         _screen_row,
         %{viewport: %{left: left}},
         cmds,
         screen_col,
         _buf_col
       )
       when seg_end <= left do
    {cmds, screen_col, seg_end}
  end

  # Already past the right edge of the viewport: skip
  defp scroll_segment(
         seg_end,
         _text,
         _style,
         _screen_row,
         %{content_w: cw},
         cmds,
         screen_col,
         _buf_col
       )
       when screen_col >= cw do
    {cmds, screen_col, seg_end}
  end

  # Segment is visible: clip and draw
  defp scroll_segment(seg_end, text, style, screen_row, ctx, cmds, screen_col, buf_col) do
    clip_and_draw(text, style, screen_row, ctx, cmds, screen_col, buf_col, seg_end)
  end

  @spec clip_and_draw(
          String.t(),
          keyword(),
          non_neg_integer(),
          Context.t(),
          [DisplayList.draw()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {[DisplayList.draw()], non_neg_integer(), non_neg_integer()}
  defp clip_and_draw(text, style, screen_row, ctx, cmds, screen_col, buf_col, seg_end) do
    drop_cols = max(0, ctx.viewport.left - buf_col)
    remaining_budget = ctx.content_w - screen_col

    pairs =
      text
      |> grapheme_pairs()
      |> display_drop(drop_cols)
      |> display_take(remaining_budget)

    visible_text = join_pairs(pairs)
    visible_width = display_width_of_pairs(pairs)

    if visible_width > 0 do
      cmd = DisplayList.draw(screen_row, ctx.gutter_w + screen_col, visible_text, style)
      {[cmd | cmds], screen_col + visible_width, seg_end}
    else
      {cmds, screen_col, seg_end}
    end
  end
end
