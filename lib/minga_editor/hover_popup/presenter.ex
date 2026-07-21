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
    popup
    |> spec(viewport)
    |> FloatingWindow.box()
  end

  @spec spec(HoverPopup.t(), {pos_integer(), pos_integer()}) :: FloatingWindow.Spec.t()
  defp spec(%HoverPopup{} = popup, viewport) do
    {viewport_rows, viewport_cols} = viewport
    {content_width, content_height} = content_dimensions(popup.content_lines, popup.scroll_offset)

    width = content_width |> max(@min_width) |> min(@max_width) |> min(viewport_cols - 2)
    desired_inner_height = content_height |> min(@max_height) |> min(viewport_rows - 4)
    desired_total_height = desired_inner_height + 2

    {side, total_height} =
      place_without_anchor_overlap(desired_total_height, popup.anchor_row, viewport_rows)

    %FloatingWindow.Spec{
      width: {:cols, width + 2},
      height: {:rows, total_height},
      position: {:anchor, popup.anchor_row, popup.anchor_col, side},
      viewport: viewport
    }
  end

  @spec place_without_anchor_overlap(pos_integer(), non_neg_integer(), pos_integer()) ::
          {:above | :below, pos_integer()}
  defp place_without_anchor_overlap(desired_height, anchor_row, viewport_rows) do
    rows_above = anchor_row
    rows_below = max(viewport_rows - anchor_row - 1, 0)
    side = choose_hover_side(desired_height, rows_above, rows_below)

    available_rows =
      case side do
        :above -> rows_above
        :below -> rows_below
      end

    {side, min(desired_height, max(available_rows, 1))}
  end

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

  @spec content_dimensions([Markdown.parsed_line()], non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp content_dimensions(lines, scroll_offset) do
    lines
    |> Enum.drop(scroll_offset)
    |> Enum.reduce({0, 0}, fn {segments, _line_type}, {max_width, height} ->
      line_width =
        segments
        |> Enum.map(fn {text, _style} -> String.length(text) end)
        |> Enum.sum()

      {max(max_width, line_width), height + 1}
    end)
  end
end
