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
  alias Minga.Buffer.Decorations.ConcealRange
  alias Minga.Buffer.Unicode
  alias Minga.Editor.DisplayList
  alias Minga.Editor.Renderer.Composition
  alias Minga.Editor.Renderer.Context
  alias Minga.Face
  alias Minga.Highlight

  @typedoc "Column range of a selection on a single line (display columns, end exclusive)."
  @type line_selection :: nil | :full | {non_neg_integer(), non_neg_integer()}

  @typedoc "A grapheme paired with its display width."
  @type grapheme_pair :: {String.t(), non_neg_integer()}

  @doc """
  Renders a single buffer line into draw tuples, including virtual text decorations.

  When `precomputed_segments` is provided (from `Highlight.styles_for_visible_lines/2`),
  it's used directly instead of calling `styles_for_line/3` per line.
  """
  @spec render(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Context.t(),
          non_neg_integer(),
          [Highlight.styled_segment()] | nil
        ) ::
          [DisplayList.draw()]
  def render(
        line_text,
        screen_row,
        buf_line,
        %Context{} = ctx,
        line_byte_offset \\ 0,
        precomputed_segments \\ nil
      ) do
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

    has_conceals = Decorations.has_conceal_ranges?(ctx.decorations)

    # When conceals are active, apply them to visible_pairs for selection paths.
    # Without this, selection rendering would show raw text (including concealed
    # characters) while selection coordinates are conceal-adjusted.
    concealed_pairs =
      if has_conceals do
        apply_conceals_to_pairs(pairs, ctx.decorations, buf_line)
      else
        nil
      end

    # Recompute display len and visible pairs from concealed pairs when active
    {effective_pairs, effective_display_len} =
      if concealed_pairs do
        {concealed_pairs, display_width_of_pairs(concealed_pairs)}
      else
        {pairs, line_display_len}
      end

    effective_visible =
      effective_pairs
      |> display_drop(ctx.viewport.left)
      |> display_take(ctx.content_w)

    case selection_cols_for_line(buf_line, effective_display_len, ctx.visual_selection) do
      nil when ctx.highlight != nil ->
        render_highlighted_line(
          line_text,
          screen_row,
          buf_line,
          ctx,
          line_byte_offset,
          line_highlights,
          precomputed_segments
        )

      nil when line_highlights != [] or has_conceals ->
        # No syntax highlighting but has decorations or conceals:
        # render through the styled-segment path
        render_decorated_plain_line(line_text, screen_row, buf_line, ctx, line_highlights)

      nil ->
        # Plain text, no decorations, no syntax highlighting, no conceals
        visible_text = join_pairs(visible_pairs)
        [DisplayList.draw(screen_row, ctx.gutter_w, visible_text)]

      :full ->
        visible_text = join_pairs(effective_visible)
        [DisplayList.draw(screen_row, ctx.gutter_w, visible_text, Face.new(reverse: true))]

      {sel_start, sel_end} ->
        render_partial_selection(
          effective_visible,
          screen_row,
          ctx.gutter_w,
          ctx.viewport.left,
          sel_start,
          sel_end
        )
    end
    |> append_eol_virtual_text(screen_row, buf_line, line_display_len, ctx)
    |> append_annotations(screen_row, buf_line, line_display_len, ctx)
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

  # Appends line annotation draw commands after EOL virtual text.
  # Pill annotations render with background color; inline text without.
  # Gutter icons are handled separately in the gutter renderer.
  @spec append_annotations(
          [DisplayList.draw()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Context.t()
        ) :: [DisplayList.draw()]
  defp append_annotations(draws, _screen_row, _buf_line, _line_len, %{
         decorations: %{annotations: []}
       }),
       do: draws

  defp append_annotations(draws, screen_row, buf_line, line_display_len, ctx) do
    anns = Decorations.annotations_for_line(ctx.decorations, buf_line)

    if anns == [] do
      draws
    else
      # Annotations start after the last drawn content on this line.
      # We compute the current end column from existing draws.
      ann_start = max_draw_end_col(draws, line_display_len, ctx)

      {ann_draws, _col} =
        Enum.reduce(anns, {[], ann_start}, fn ann, {acc, col} ->
          render_annotation(ann, screen_row, col, acc)
        end)

      draws ++ Enum.reverse(ann_draws)
    end
  end

  # Computes the column after the last draw command, so annotations
  # don't overlap with EOL virtual text.
  @spec max_draw_end_col([DisplayList.draw()], non_neg_integer(), Context.t()) ::
          non_neg_integer()
  defp max_draw_end_col(draws, line_display_len, ctx) do
    base = max(line_display_len + 1 - ctx.viewport.left, 0) + ctx.gutter_w

    Enum.reduce(draws, base, fn draw, acc ->
      {_row, col, text, _style} = draw
      draw_end = col + Unicode.display_width(text)
      max(acc, draw_end + 1)
    end)
  end

  @spec render_annotation(
          Decorations.LineAnnotation.t(),
          non_neg_integer(),
          non_neg_integer(),
          [DisplayList.draw()]
        ) :: {[DisplayList.draw()], non_neg_integer()}
  defp render_annotation(%{kind: :inline_pill} = ann, screen_row, col, acc) do
    # Pill: space-padded text with background color
    text = " #{ann.text} "
    style = Face.new(fg: ann.fg, bg: ann.bg, bold: true)
    width = Unicode.display_width(text)
    draw = DisplayList.draw(screen_row, col, text, style)
    {[draw | acc], col + width + 1}
  end

  defp render_annotation(%{kind: :inline_text} = ann, screen_row, col, acc) do
    # Inline text: styled text, no background
    style = Face.new(fg: ann.fg)
    width = Unicode.display_width(ann.text)
    draw = DisplayList.draw(screen_row, col, ann.text, style)
    {[draw | acc], col + width + 1}
  end

  defp render_annotation(%{kind: :gutter_icon}, _screen_row, col, acc) do
    # Gutter icons are rendered in the gutter renderer, not at EOL.
    # Skip here.
    {acc, col}
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
        Face.new(reverse: true)
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
    segments = [{line_text, Face.new()}]
    segments = Decorations.merge_highlights(segments, line_highlights, buf_line)
    segments = Composition.apply_conceals(segments, ctx.decorations, buf_line)
    segments = Composition.inject_inline_virtual_text(segments, ctx.decorations, buf_line)
    render_segments_with_scroll(segments, screen_row, ctx)
  end

  # ── Conceal application to grapheme pairs (for selection paths) ──────────────

  # Applies conceals to a list of grapheme pairs, removing concealed graphemes
  # and optionally inserting replacement characters. Used by the selection
  # rendering paths which work with pairs instead of styled segments.
  @spec apply_conceals_to_pairs([grapheme_pair()], Decorations.t(), non_neg_integer()) ::
          [grapheme_pair()]
  defp apply_conceals_to_pairs(pairs, decorations, buf_line) do
    conceals = Decorations.conceals_for_line(decorations, buf_line)
    if conceals == [], do: pairs, else: do_apply_conceals_to_pairs(pairs, conceals, buf_line, 0)
  end

  @spec do_apply_conceals_to_pairs(
          [grapheme_pair()],
          [ConcealRange.t()],
          non_neg_integer(),
          non_neg_integer()
        ) :: [grapheme_pair()]
  defp do_apply_conceals_to_pairs([], _conceals, _line, _col), do: []
  defp do_apply_conceals_to_pairs(pairs, [], _line, _col), do: pairs

  defp do_apply_conceals_to_pairs(
         [{_g, w} = pair | rest],
         [%ConcealRange{} = conceal | rest_conceals] = conceals,
         line,
         col
       ) do
    {_sl, sc} = conceal.start_pos
    {el, ec} = conceal.end_pos
    cs = if elem(conceal.start_pos, 0) < line, do: 0, else: sc
    ce = if el > line, do: col + w + 1, else: ec

    pair_conceal_action(col, w, cs, ce)
    |> apply_pair_action(pair, rest, conceal, rest_conceals, conceals, line, col)
  end

  @spec pair_conceal_action(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :past | :inside | :before
  defp pair_conceal_action(col, w, cs, _ce) when cs >= col + w, do: :past
  defp pair_conceal_action(col, _w, cs, ce) when col >= cs and col < ce, do: :inside
  defp pair_conceal_action(_col, _w, _cs, _ce), do: :before

  # Dispatches on the pair's position relative to the conceal.
  # `w` is extracted from `pair` instead of passed separately (it's redundant).
  # :past and :before have identical behavior (emit pair, continue), so
  # they share the catch-all clause.
  @spec apply_pair_action(
          :past | :inside | :before,
          grapheme_pair(),
          [grapheme_pair()],
          ConcealRange.t(),
          [ConcealRange.t()],
          [ConcealRange.t()],
          non_neg_integer(),
          non_neg_integer()
        ) :: [grapheme_pair()]
  defp apply_pair_action(:inside, {_g, w}, rest, conceal, rest_conceals, conceals, line, col) do
    {_sl, sc} = conceal.start_pos
    cs = if elem(conceal.start_pos, 0) < line, do: 0, else: sc
    {el, ec} = conceal.end_pos
    ce = if el > line, do: col + w + 1, else: ec

    replacement =
      if col == cs and conceal.replacement != nil,
        do: [{conceal.replacement, 1}],
        else: []

    if col + w >= ce do
      replacement ++ do_apply_conceals_to_pairs(rest, rest_conceals, line, col + w)
    else
      replacement ++ do_apply_conceals_to_pairs(rest, conceals, line, col + w)
    end
  end

  # :past and :before both pass through the pair unchanged
  defp apply_pair_action(
         _action,
         {_g, w} = pair,
         rest,
         _conceal,
         _rest_conceals,
         conceals,
         line,
         col
       ) do
    [pair | do_apply_conceals_to_pairs(rest, conceals, line, col + w)]
  end

  # ── Syntax highlighting ──────────────────────────────────────────────────────

  @spec render_highlighted_line(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          Context.t(),
          non_neg_integer(),
          [Decorations.highlight_range()],
          [Highlight.styled_segment()] | nil
        ) ::
          [DisplayList.draw()]
  defp render_highlighted_line(
         line_text,
         screen_row,
         buf_line,
         ctx,
         line_byte_offset,
         line_highlights,
         precomputed_segments
       ) do
    segments =
      precomputed_segments ||
        Highlight.styles_for_line(ctx.highlight, line_text, line_byte_offset)

    # Merge decoration highlight ranges with syntax segments (pre-queried, no double lookup)
    segments = Decorations.merge_highlights(segments, line_highlights, buf_line)
    segments = Composition.apply_conceals(segments, ctx.decorations, buf_line)
    segments = Composition.inject_inline_virtual_text(segments, ctx.decorations, buf_line)

    render_segments_with_scroll(segments, screen_row, ctx)
  end

  # Shared rendering for styled segments with horizontal scroll clipping.
  # Used by both syntax-highlighted and decorated-plain-text paths.
  @spec render_segments_with_scroll(
          [{String.t(), Face.t()}],
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
          Face.t(),
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
          Face.t(),
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
          Face.t(),
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
