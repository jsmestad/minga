defmodule Minga.Editor.Renderer.Composition do
  @moduledoc """
  Shared text composition pipeline for both draw and semantic render paths.

  Provides three pure operations on styled segment lists:
  1. Conceal application (hide concealed text, insert replacements)
  2. Inline virtual text injection (splice ghost text at anchor columns)
  3. Text splitting at display column boundaries

  These functions are used by both `Renderer.Line` (draw-based path) and
  `SemanticWindow.Builder` (semantic 0x80 path) to ensure both paths
  produce identical composed output for the same input.

  All functions are pure calculations with no rendering or viewport
  dependencies. They operate on `[{text, Face.t()}]` styled segments
  and return styled segments.
  """

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Decorations.ConcealRange
  alias Minga.Buffer.Unicode
  alias Minga.Face

  @type styled_segment :: {String.t(), Face.t()}

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Applies conceal ranges to a list of styled segments.

  Walks segments and conceals together (both sorted by column position).
  Concealed text is removed and optionally replaced with a single
  replacement character.
  """
  @spec apply_conceals([styled_segment()], Decorations.t(), non_neg_integer()) ::
          [styled_segment()]
  def apply_conceals(segments, decorations, buf_line) do
    conceals = Decorations.conceals_for_line(decorations, buf_line)

    if conceals == [] do
      segments
    else
      do_apply_conceals(segments, conceals, %{line: buf_line, col: 0, acc: []})
    end
  end

  @doc """
  Injects inline virtual text segments into a styled segment list at their
  anchor column positions, displacing subsequent content rightward.
  """
  @spec inject_inline_virtual_text([styled_segment()], Decorations.t(), non_neg_integer()) ::
          [styled_segment()]
  def inject_inline_virtual_text(segments, decorations, buf_line) do
    inline_vts = Decorations.inline_virtual_texts_for_line(decorations, buf_line)

    if inline_vts == [] do
      segments
    else
      do_inject_inline(segments, inline_vts, 0, [])
    end
  end

  @doc """
  Splits text at a display column position (not byte or grapheme index).
  Handles wide characters (CJK) correctly.
  """
  @spec split_text_at_display_col(String.t(), non_neg_integer()) :: {String.t(), String.t()}
  def split_text_at_display_col(text, display_col) do
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

  @doc """
  Runs the full composition pipeline on styled segments:
  merge_highlights → apply_conceals → inject_inline_virtual_text.

  Returns the final composed segments suitable for conversion to either
  draw commands (Line.ex) or text + spans (SemanticWindow.Builder).
  """
  @spec compose_segments(
          [styled_segment()],
          Decorations.t(),
          non_neg_integer()
        ) :: [styled_segment()]
  def compose_segments(segments, decorations, buf_line) do
    segments
    |> apply_conceals(decorations, buf_line)
    |> inject_inline_virtual_text(decorations, buf_line)
  end

  @doc """
  Converts a list of composed styled segments into {text, [Span.t()]}
  for the semantic window path.

  The text is the concatenation of all segment texts. Spans are built
  from each segment's Face, with display column coordinates.
  """
  @spec segments_to_text_and_spans([styled_segment()]) ::
          {String.t(), [Minga.Editor.SemanticWindow.Span.t()]}
  def segments_to_text_and_spans(segments) do
    alias Minga.Editor.SemanticWindow.Span

    {spans_rev, text_parts, _col} =
      Enum.reduce(segments, {[], [], 0}, fn {text, face}, {spans, parts, col} ->
        width = Unicode.display_width(text)

        if width > 0 do
          span = Span.from_face(face, col, col + width)
          {[span | spans], [text | parts], col + width}
        else
          {spans, parts, col}
        end
      end)

    {text_parts |> Enum.reverse() |> Enum.join(), Enum.reverse(spans_rev)}
  end

  # ── Inline virtual text injection (private) ──────────────────────────────

  @spec do_inject_inline(
          [styled_segment()],
          [Decorations.VirtualText.t()],
          non_neg_integer(),
          [styled_segment()]
        ) :: [styled_segment()]
  defp do_inject_inline([], remaining_vts, _col, acc) do
    vt_segments = Enum.flat_map(remaining_vts, fn vt -> vt.segments end)
    Enum.reverse(acc, vt_segments)
  end

  defp do_inject_inline(segments, [], _col, acc) do
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

  @spec inject_at_position(
          styled_segment(),
          [styled_segment()],
          Decorations.VirtualText.t(),
          [Decorations.VirtualText.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [styled_segment()]
        ) :: [styled_segment()]
  defp inject_at_position(seg, rest_segs, vt, rest_vts, col, _seg_end, anchor_col, acc)
       when anchor_col <= col do
    do_inject_inline([seg | rest_segs], rest_vts, col, vt.segments ++ acc)
  end

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
    after_part = if after_text != "", do: [{after_text, seg_style}], else: []
    new_acc = after_part ++ vt.segments ++ [{before_text, seg_style} | acc]
    do_inject_inline(rest_segs, rest_vts, seg_end, new_acc)
  end

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

  # ── Conceal application (private) ──────────────────────────────────────

  @typep conceal_ctx :: %{
           line: non_neg_integer(),
           col: non_neg_integer(),
           acc: [styled_segment()]
         }

  @dialyzer {:nowarn_function, do_apply_conceals: 3}
  @dialyzer {:nowarn_function, apply_conceal_from_start: 7}
  @dialyzer {:nowarn_function, apply_conceal_mid_segment: 7}
  @dialyzer {:nowarn_function, maybe_emit_replacement: 5}

  @spec do_apply_conceals([styled_segment()], [ConcealRange.t()], conceal_ctx()) ::
          [styled_segment()]
  defp do_apply_conceals([], _conceals, ctx), do: Enum.reverse(ctx.acc)
  defp do_apply_conceals(segments, [], ctx), do: Enum.reverse(ctx.acc, segments)

  defp do_apply_conceals(
         [{seg_text, seg_style} | rest_segs],
         [%ConcealRange{} = conceal | rest_conceals] = conceals,
         ctx
       ) do
    seg_width = Unicode.display_width(seg_text)
    seg_end = ctx.col + seg_width

    {_sl, sc} = conceal.start_pos
    {el, ec} = conceal.end_pos
    conceal_start = if elem(conceal.start_pos, 0) < ctx.line, do: 0, else: sc
    conceal_end = if el > ctx.line, do: seg_end + 1, else: ec

    if conceal_start >= seg_end do
      do_apply_conceals(
        rest_segs,
        conceals,
        %{ctx | col: seg_end, acc: [{seg_text, seg_style} | ctx.acc]}
      )
    else
      if conceal_start <= ctx.col do
        apply_conceal_from_start(
          {seg_text, seg_style},
          rest_segs,
          conceal,
          rest_conceals,
          seg_end,
          conceal_end,
          ctx
        )
      else
        apply_conceal_mid_segment(
          {seg_text, seg_style},
          rest_segs,
          conceal,
          rest_conceals,
          seg_end,
          conceal_start,
          ctx
        )
      end
    end
  end

  @spec apply_conceal_from_start(
          styled_segment(),
          [styled_segment()],
          ConcealRange.t(),
          [ConcealRange.t()],
          non_neg_integer(),
          non_neg_integer(),
          conceal_ctx()
        ) :: [styled_segment()]
  defp apply_conceal_from_start(
         {seg_text, seg_style},
         rest_segs,
         conceal,
         rest_conceals,
         seg_end,
         conceal_end,
         ctx
       ) do
    if conceal_end >= seg_end do
      replacement_acc = maybe_emit_replacement(ctx.acc, conceal, ctx.col, ctx.line, seg_style)

      if conceal_end == seg_end do
        do_apply_conceals(rest_segs, rest_conceals, %{ctx | col: seg_end, acc: replacement_acc})
      else
        do_apply_conceals(
          rest_segs,
          [conceal | rest_conceals],
          %{ctx | col: seg_end, acc: replacement_acc}
        )
      end
    else
      replacement_acc = maybe_emit_replacement(ctx.acc, conceal, ctx.col, ctx.line, seg_style)
      drop_cols = conceal_end - ctx.col
      {_before, after_text} = split_text_at_display_col(seg_text, drop_cols)

      if after_text != "" do
        do_apply_conceals(
          [{after_text, seg_style} | rest_segs],
          rest_conceals,
          %{ctx | col: conceal_end, acc: replacement_acc}
        )
      else
        do_apply_conceals(
          rest_segs,
          rest_conceals,
          %{ctx | col: seg_end, acc: replacement_acc}
        )
      end
    end
  end

  @spec apply_conceal_mid_segment(
          styled_segment(),
          [styled_segment()],
          ConcealRange.t(),
          [ConcealRange.t()],
          non_neg_integer(),
          non_neg_integer(),
          conceal_ctx()
        ) :: [styled_segment()]
  defp apply_conceal_mid_segment(
         {seg_text, seg_style},
         rest_segs,
         conceal,
         rest_conceals,
         seg_end,
         conceal_start,
         ctx
       ) do
    split_at = conceal_start - ctx.col
    {before_text, after_text} = split_text_at_display_col(seg_text, split_at)

    before_acc = if before_text != "", do: [{before_text, seg_style} | ctx.acc], else: ctx.acc

    if after_text != "" do
      do_apply_conceals(
        [{after_text, seg_style} | rest_segs],
        [conceal | rest_conceals],
        %{ctx | col: conceal_start, acc: before_acc}
      )
    else
      do_apply_conceals(
        rest_segs,
        [conceal | rest_conceals],
        %{ctx | col: seg_end, acc: before_acc}
      )
    end
  end

  @spec maybe_emit_replacement(
          [styled_segment()],
          ConcealRange.t(),
          non_neg_integer(),
          non_neg_integer(),
          Face.t()
        ) :: [styled_segment()]
  defp maybe_emit_replacement(acc, %ConcealRange{replacement: nil}, _col, _line, _seg_style),
    do: acc

  defp maybe_emit_replacement(acc, conceal, col, line, seg_style) do
    {sl, sc} = conceal.start_pos
    conceal_start_on_line = if sl < line, do: 0, else: sc

    if col <= conceal_start_on_line do
      merged_style = Decorations.merge_style_props(seg_style, conceal.replacement_style)
      [{conceal.replacement, merged_style} | acc]
    else
      acc
    end
  end
end
