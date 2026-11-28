defmodule MingaEditor.HoverPopup.Presenter do
  @moduledoc "Builds hover-popup geometry from its immutable value."

  alias MingaAgent.Markdown
  alias MingaEditor.FloatingWindow
  alias MingaEditor.HoverPopup

  @max_width 60
  @max_height 20
  @min_width 30

  @doc "Returns the popup's conservative outer rect in screen cells."
  @spec box(HoverPopup.t(), {pos_integer(), pos_integer()}) ::
          MingaEditor.Layout.rect() | nil
  def box(%HoverPopup{content_lines: []}, _viewport), do: nil

  def box(%HoverPopup{} = popup, viewport) do
    case spec(popup, viewport) do
      nil -> nil
      spec -> FloatingWindow.box(spec)
    end
  end

  @spec spec(HoverPopup.t(), {pos_integer(), pos_integer()}) :: FloatingWindow.Spec.t() | nil
  defp spec(%HoverPopup{} = popup, viewport) do
    {viewport_rows, viewport_cols} = viewport
    {content_width, content_height} = content_dimensions(HoverPopup.display_lines(popup))

    width = content_width |> max(@min_width) |> min(@max_width) |> min(max(viewport_cols - 2, 1))
    desired_height = min(content_height, @max_height) + 2
    anchor_row = min(popup.anchor_row, viewport_rows - 1)
    caret_row = popup.code_source && Map.get(popup.code_source, :terminal_caret_row)
    {rows_above, rows_below} = available_rows(anchor_row, viewport_rows, caret_row)
    side = choose_hover_side(desired_height, rows_above, rows_below)
    height = min(desired_height, if(side == :above, do: rows_above, else: rows_below))

    if height > 0 do
      %FloatingWindow.Spec{
        width: {:cols, width + 2},
        height: {:rows, height},
        position: {:anchor, anchor_row, popup.anchor_col, side},
        viewport: viewport
      }
    end
  end

  @spec available_rows(non_neg_integer(), pos_integer(), non_neg_integer() | nil) ::
          {non_neg_integer(), non_neg_integer()}
  defp available_rows(anchor, rows, caret) when is_integer(caret) and caret < anchor,
    do: {anchor - caret - 1, rows - anchor - 1}

  defp available_rows(anchor, rows, caret)
       when is_integer(caret) and caret > anchor and caret < rows,
       do: {anchor, caret - anchor - 1}

  defp available_rows(anchor, rows, _caret), do: {anchor, rows - anchor - 1}

  @spec choose_hover_side(pos_integer(), non_neg_integer(), non_neg_integer()) :: :above | :below
  defp choose_hover_side(desired_height, rows_above, _rows_below)
       when rows_above >= desired_height,
       do: :above

  defp choose_hover_side(desired_height, _rows_above, rows_below)
       when rows_below >= desired_height,
       do: :below

  defp choose_hover_side(_desired_height, rows_above, rows_below) when rows_above >= rows_below,
    do: :above

  defp choose_hover_side(_desired_height, _rows_above, _rows_below), do: :below

  @spec content_dimensions([Markdown.parsed_line()]) :: {non_neg_integer(), non_neg_integer()}
  defp content_dimensions(lines) do
    Enum.reduce(lines, {0, 0}, fn {segments, _line_type}, {max_width, height} ->
      line_width =
        Enum.reduce(segments, 0, fn {text, _style}, width -> width + String.length(text) end)

      {max(max_width, line_width), height + 1}
    end)
  end
end
