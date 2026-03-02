defmodule Minga.Editor.Renderer.Line do
  @moduledoc """
  Line content rendering with visual selection and search highlight support.
  """

  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.SearchHighlight
  alias Minga.Port.Protocol

  @typedoc "Column range of a selection on a single line."
  @type line_selection :: nil | :full | {non_neg_integer(), non_neg_integer()}

  @doc "Renders a single buffer line into draw commands."
  @spec render(String.t(), non_neg_integer(), non_neg_integer(), Context.t()) :: [binary()]
  def render(line_text, screen_row, buf_line, %Context{} = ctx) do
    graphemes = String.graphemes(line_text)
    line_len = length(graphemes)

    visible_graphemes =
      graphemes
      |> Enum.drop(ctx.viewport.left)
      |> Enum.take(ctx.content_w)

    case selection_cols_for_line(buf_line, line_len, ctx.visual_selection) do
      nil ->
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
        [
          Protocol.encode_draw(screen_row, ctx.gutter_w, Enum.join(visible_graphemes),
            reverse: true
          )
        ]

      {sel_start, sel_end} ->
        render_partial_selection(
          visible_graphemes,
          screen_row,
          ctx.gutter_w,
          ctx.viewport.left,
          sel_start,
          sel_end
        )
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec render_partial_selection(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [binary()]
  defp render_partial_selection(visible_graphemes, screen_row, gutter_w, left, sel_start, sel_end) do
    before_sel = Enum.take(visible_graphemes, max(0, sel_start - left))

    sel_graphemes =
      visible_graphemes
      |> Enum.drop(max(0, sel_start - left))
      |> Enum.take(sel_end - max(sel_start, left) + 1)

    after_sel =
      Enum.drop(
        visible_graphemes,
        max(0, sel_start - left) + length(sel_graphemes)
      )

    before_text = Enum.join(before_sel)
    sel_text = Enum.join(sel_graphemes)
    after_text = Enum.join(after_sel)

    [
      Protocol.encode_draw(screen_row, gutter_w, before_text),
      Protocol.encode_draw(
        screen_row,
        gutter_w + length(before_sel),
        sel_text,
        reverse: true
      ),
      Protocol.encode_draw(
        screen_row,
        gutter_w + length(before_sel) + length(sel_graphemes),
        after_text
      )
    ]
  end

  @spec selection_cols_for_line(
          non_neg_integer(),
          non_neg_integer(),
          Context.visual_selection()
        ) :: line_selection()
  defp selection_cols_for_line(_buf_line, _line_len, nil), do: nil

  defp selection_cols_for_line(buf_line, _line_len, {:line, start_line, end_line}) do
    if buf_line >= start_line and buf_line <= end_line, do: :full, else: nil
  end

  defp selection_cols_for_line(buf_line, _line_len, {:char, {start_line, _sc}, {end_line, _ec}})
       when buf_line < start_line or buf_line > end_line,
       do: nil

  defp selection_cols_for_line(_buf_line, _line_len, {:char, {same, start_col}, {same, end_col}}),
    do: {start_col, end_col}

  defp selection_cols_for_line(buf_line, line_len, {:char, {buf_line, start_col}, _end_pos}),
    do: {start_col, max(0, line_len - 1)}

  defp selection_cols_for_line(buf_line, _line_len, {:char, _start_pos, {buf_line, end_col}}),
    do: {0, end_col}

  defp selection_cols_for_line(_buf_line, _line_len, {:char, _start_pos, _end_pos}),
    do: :full
end
