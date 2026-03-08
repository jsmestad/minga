defmodule Minga.Editor.CompletionUI do
  @moduledoc """
  Renders the LSP completion popup as an overlay near the cursor.

  Produces a list of `DisplayList.draw()` tuples for the completion menu.
  The popup is positioned below the cursor if there's room, above if not.
  Sized to fit the visible items up to a maximum of 10 rows and 50 columns.
  """

  alias Minga.Completion
  alias Minga.Editor.DisplayList

  @max_rows 10
  @max_width 50
  @min_width 20

  @typedoc "Render context with cursor position and viewport."
  @type render_opts :: %{
          cursor_row: non_neg_integer(),
          cursor_col: non_neg_integer(),
          viewport_rows: non_neg_integer(),
          viewport_cols: non_neg_integer()
        }

  @doc """
  Renders the completion popup. Returns a list of draw tuples.

  Returns an empty list if completion is nil or has no visible items.
  """
  @spec render(Completion.t() | nil, render_opts(), map()) :: [DisplayList.draw()]
  def render(nil, _opts, _theme), do: []

  def render(%Completion{} = completion, opts, theme) do
    {visible, selected_offset} = Completion.visible_items(completion)

    case visible do
      [] ->
        []

      items ->
        do_render(items, selected_offset, opts, theme)
    end
  end

  @spec do_render([Completion.item()], non_neg_integer(), render_opts(), map()) ::
          [DisplayList.draw()]
  defp do_render(items, selected_offset, opts, theme) do
    item_count = min(length(items), @max_rows)
    visible_items = Enum.take(items, item_count)

    # Calculate popup width based on longest label
    label_widths = Enum.map(visible_items, fn item -> String.length(item.label) + 4 end)
    popup_width = label_widths |> Enum.max() |> max(@min_width) |> min(@max_width)
    popup_width = min(popup_width, opts.viewport_cols - opts.cursor_col)

    # Position: below cursor if room, above if not
    space_below = opts.viewport_rows - opts.cursor_row - 2
    space_above = opts.cursor_row

    {start_row, _direction} =
      cond do
        space_below >= item_count -> {opts.cursor_row + 1, :below}
        space_above >= item_count -> {opts.cursor_row - item_count, :above}
        true -> {opts.cursor_row + 1, :below}
      end

    start_col = min(opts.cursor_col, max(0, opts.viewport_cols - popup_width))

    # Theme colors (reuse picker colors)
    pc = theme.picker
    bg = pc.bg
    sel_bg = pc.sel_bg
    text_fg = pc.text_fg
    highlight_fg = pc.highlight_fg
    dim_fg = pc.dim_fg

    visible_items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} ->
      row = start_row + idx

      if row >= 0 and row < opts.viewport_rows do
        is_selected = idx == selected_offset

        render_completion_item(row, start_col, popup_width, item, is_selected, %{
          bg: bg,
          sel_bg: sel_bg,
          text_fg: text_fg,
          highlight_fg: highlight_fg,
          dim_fg: dim_fg
        })
      else
        []
      end
    end)
  end

  @spec render_completion_item(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          Completion.item(),
          boolean(),
          map()
        ) :: [DisplayList.draw()]
  defp render_completion_item(row, col, width, item, is_selected, colors) do
    fg = if is_selected, do: colors.highlight_fg, else: colors.text_fg
    bg = if is_selected, do: colors.sel_bg, else: colors.bg

    kind_char = Completion.kind_label(item.kind)
    label = item.label

    # Format: " k label    detail "
    detail = item.detail
    label_part = " #{kind_char} #{label}"

    avail_for_detail = width - String.length(label_part) - 2

    detail_part =
      if detail != "" and avail_for_detail > 5 do
        truncated = String.slice(detail, 0, avail_for_detail)
        truncated
      else
        ""
      end

    padding = max(0, width - String.length(label_part) - String.length(detail_part) - 1)
    full_text = label_part <> String.duplicate(" ", padding) <> detail_part <> " "
    full_text = String.slice(full_text, 0, width)

    cmds = [
      DisplayList.draw(row, col, String.pad_trailing(full_text, width),
        fg: fg,
        bg: bg,
        bold: is_selected
      )
    ]

    # Render kind character with dim color
    kind_cmd =
      DisplayList.draw(row, col + 1, kind_char,
        fg: colors.dim_fg,
        bg: bg
      )

    # Render detail with dim color if present
    detail_cmds =
      if detail_part != "" do
        detail_col = col + String.length(label_part) + padding
        [DisplayList.draw(row, detail_col, detail_part, fg: colors.dim_fg, bg: bg)]
      else
        []
      end

    [kind_cmd | cmds] ++ detail_cmds
  end
end
