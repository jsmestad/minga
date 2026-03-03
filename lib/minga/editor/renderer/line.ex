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
  """

  alias Minga.Buffer.Unicode
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.SearchHighlight
  alias Minga.Highlight
  alias Minga.Port.Protocol

  @typedoc "Column range of a selection on a single line (display columns, end exclusive)."
  @type line_selection :: nil | :full | {non_neg_integer(), non_neg_integer()}

  @typedoc "A grapheme paired with its display width."
  @type grapheme_pair :: {String.t(), non_neg_integer()}

  @doc "Renders a single buffer line into draw commands."
  @spec render(String.t(), non_neg_integer(), non_neg_integer(), Context.t(), non_neg_integer()) ::
          [binary()]
  def render(line_text, screen_row, buf_line, %Context{} = ctx, line_byte_offset \\ 0) do
    pairs = grapheme_pairs(line_text)
    line_display_len = display_width_of_pairs(pairs)

    visible_pairs =
      pairs
      |> display_drop(ctx.viewport.left)
      |> display_take(ctx.content_w)

    commands =
      case selection_cols_for_line(buf_line, line_display_len, ctx.visual_selection) do
        nil when ctx.highlight != nil ->
          render_highlighted_line(line_text, screen_row, ctx, line_byte_offset)

        nil ->
          visible_graphemes = Enum.map(visible_pairs, fn {g, _} -> g end)

          SearchHighlight.render_line_with_search(
            visible_graphemes,
            screen_row,
            buf_line,
            ctx.viewport,
            ctx.search_matches,
            ctx.gutter_w,
            ctx.confirm_match
          )

        :full ->
          visible_text = join_pairs(visible_pairs)
          [Protocol.encode_draw(screen_row, ctx.gutter_w, visible_text, reverse: true)]

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

    commands
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
        ) :: [binary()]
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
      Protocol.encode_draw(screen_row, gutter_w, before_text),
      Protocol.encode_draw(
        screen_row,
        gutter_w + before_width,
        sel_text,
        reverse: true
      ),
      Protocol.encode_draw(
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

  # ── Syntax highlighting ──────────────────────────────────────────────────────

  @spec render_highlighted_line(String.t(), non_neg_integer(), Context.t(), non_neg_integer()) ::
          [binary()]
  defp render_highlighted_line(line_text, screen_row, ctx, line_byte_offset) do
    segments = Highlight.styles_for_line(ctx.highlight, line_text, line_byte_offset)

    # Apply horizontal scroll: track display column, skip segments before
    # viewport.left, clip segments that straddle the boundary.
    left = ctx.viewport.left
    max_col = ctx.content_w

    {commands, _screen_col, _buf_col} =
      Enum.reduce(segments, {[], 0, 0}, fn {text, style}, {cmds, screen_col, buf_col} ->
        seg_end = buf_col + Unicode.display_width(text)

        cond do
          seg_end <= left -> {cmds, screen_col, seg_end}
          screen_col >= max_col -> {cmds, screen_col, seg_end}
          true -> clip_and_draw(text, style, screen_row, ctx, cmds, screen_col, buf_col, seg_end)
        end
      end)

    Enum.reverse(commands)
  end

  @spec clip_and_draw(
          String.t(),
          Protocol.style(),
          non_neg_integer(),
          Context.t(),
          [binary()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {[binary()], non_neg_integer(), non_neg_integer()}
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
      cmd = Protocol.encode_draw(screen_row, ctx.gutter_w + screen_col, visible_text, style)
      {[cmd | cmds], screen_col + visible_width, seg_end}
    else
      {cmds, screen_col, seg_end}
    end
  end
end
