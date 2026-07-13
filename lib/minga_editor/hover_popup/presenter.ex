defmodule MingaEditor.HoverPopup.Presenter do
  @moduledoc "Builds hover-popup geometry and display-list presentation from its immutable value."

  alias MingaAgent.Markdown
  alias MingaEditor.DisplayList
  alias MingaEditor.FloatingWindow
  alias MingaEditor.HoverPopup
  alias MingaEditor.MarkdownStyles

  @max_width 60
  @max_height 20
  @min_width 30

  @doc "Returns the popup's conservative outer rect in screen cells."
  @spec box(HoverPopup.t(), {pos_integer(), pos_integer()}, map()) ::
          MingaEditor.Layout.rect() | nil
  def box(%HoverPopup{content_lines: []}, _viewport, _theme), do: nil

  def box(%HoverPopup{} = popup, viewport, theme) do
    popup
    |> spec(viewport, theme)
    |> FloatingWindow.box()
  end

  @spec spec(HoverPopup.t(), {pos_integer(), pos_integer()}, map()) :: FloatingWindow.Spec.t()
  defp spec(%HoverPopup{} = popup, viewport, theme) do
    {viewport_rows, viewport_cols} = viewport
    popup_theme = Map.get(theme, :popup, default_popup_theme())

    {content_draws, content_width, content_height} =
      build_content_draws(popup.content_lines, popup.scroll_offset, viewport_cols, theme)

    width = content_width |> max(@min_width) |> min(@max_width) |> min(viewport_cols - 2)
    desired_inner_height = content_height |> min(@max_height) |> min(viewport_rows - 4)
    desired_total_height = desired_inner_height + 2

    {side, total_height} =
      place_without_anchor_overlap(desired_total_height, popup.anchor_row, viewport_rows)

    height = max(total_height - 2, 1)
    total_lines = Enum.count(popup.content_lines)

    footer =
      if total_lines > height do
        visible_end = min(popup.scroll_offset + height, total_lines)
        "#{popup.scroll_offset + 1}-#{visible_end}/#{total_lines}"
      end

    %FloatingWindow.Spec{
      content: content_draws,
      width: {:cols, width + 2},
      height: {:rows, total_height},
      position: {:anchor, popup.anchor_row, popup.anchor_col, side},
      border: if(popup.focused, do: :single, else: :rounded),
      footer: footer,
      theme: popup_theme,
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

  @spec build_content_draws(
          [Markdown.parsed_line()],
          non_neg_integer(),
          pos_integer(),
          map()
        ) :: {[DisplayList.draw()], non_neg_integer(), non_neg_integer()}
  defp build_content_draws(lines, scroll_offset, max_width, theme) do
    {draws_by_line, max_col, row} =
      lines
      |> Enum.drop(scroll_offset)
      |> Enum.reduce({[], 0, 0}, fn {segments, line_type}, {acc, max_w, row} ->
        line_draws = render_line_segments(segments, line_type, row, max_width, theme)

        line_width =
          segments
          |> Enum.map(fn {text, _style} -> String.length(text) end)
          |> Enum.sum()

        {[line_draws | acc], max(max_w, line_width), row + 1}
      end)

    {draws_by_line |> Enum.reverse() |> List.flatten(), max_col, row}
  end

  @spec render_line_segments(
          [Markdown.segment()],
          Markdown.line_type(),
          non_neg_integer(),
          pos_integer(),
          map()
        ) :: [DisplayList.draw()]
  defp render_line_segments(segments, _line_type, row, max_width, theme) do
    syntax = Map.get(theme, :syntax, %{})
    editor = Map.get(theme, :editor, %{})
    base_fg = Map.get(editor, :fg, 0xBBC2CF)

    {draws, _col} =
      Enum.reduce(segments, {[], 0}, fn {text, style}, {acc, col} ->
        text_length = String.length(text)

        if col >= max_width - 2 do
          {acc, col}
        else
          clipped = String.slice(text, 0, max(max_width - 2 - col, 0))
          draw_style = MarkdownStyles.to_draw_opts(style, syntax, base_fg)
          draw = DisplayList.draw(row, col, clipped, draw_style)
          {[draw | acc], col + text_length}
        end
      end)

    Enum.reverse(draws)
  end

  @spec default_popup_theme() :: map()
  defp default_popup_theme do
    %{bg: 0x21242B, border_fg: 0x5B6268, title_fg: 0xBBC2CF}
  end
end
