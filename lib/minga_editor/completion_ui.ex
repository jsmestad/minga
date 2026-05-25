defmodule MingaEditor.CompletionUI do
  @moduledoc """
  Renders the LSP completion popup as an overlay near the cursor.

  Produces a list of `DisplayList.draw()` tuples for the completion menu
  and an optional documentation preview pane beside it. The preview pane
  shows the selected item's documentation rendered as formatted markdown.

  The popup is positioned below the cursor if there's room, above if not.
  Sized to fit the visible items up to a maximum of 10 rows and 50 columns.
  The doc preview appears to the right if there's room, to the left if not.
  """

  alias MingaAgent.Markdown
  alias Minga.Core.Face
  alias Minga.Editing.Completion
  alias MingaEditor.DisplayList
  alias MingaEditor.FloatingWindow
  alias MingaEditor.MarkdownStyles

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
        menu_draws = do_render(items, selected_offset, opts, theme)
        selected_item = Enum.at(visible, selected_offset)
        doc_draws = render_doc_preview(selected_item, items, selected_offset, opts, theme)
        menu_draws ++ doc_draws
    end
  end

  @doc "Returns the screen rect for the visible completion menu, or nil when it is empty."
  @spec menu_rect(Completion.t() | nil, render_opts()) :: MingaEditor.Layout.rect() | nil
  def menu_rect(nil, _opts), do: nil

  def menu_rect(%Completion{} = completion, opts) do
    {visible, _selected_offset} = Completion.visible_items(completion)

    case menu_geometry(visible, opts) do
      nil -> nil
      %{row: row, col: col, width: width, height: height} -> {row, col, width, height}
    end
  end

  @spec do_render([Completion.item()], non_neg_integer(), render_opts(), map()) ::
          [DisplayList.draw()]
  defp do_render(items, selected_offset, opts, theme) do
    geometry = menu_geometry(items, opts)
    %{row: start_row, col: start_col, width: popup_width, height: item_count} = geometry

    visible_items = Enum.take(items, item_count)

    pc = theme.picker
    popup = Map.get(theme, :popup, %{})

    colors = %{
      bg: pc.bg,
      border_fg: Map.get(popup, :border_fg, pc.border_fg),
      text_fg: pc.text_fg,
      highlight_fg: pc.highlight_fg,
      dim_fg: pc.dim_fg
    }

    border_draws = render_menu_border(geometry, colors)

    item_draws =
      visible_items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, idx} ->
        row = start_row + idx

        if row >= 0 and row < opts.viewport_rows do
          render_completion_item(
            row,
            start_col,
            popup_width,
            item,
            idx == selected_offset,
            colors
          )
        else
          []
        end
      end)

    border_draws ++ item_draws
  end

  @spec menu_geometry([Completion.item()], render_opts()) ::
          %{
            row: non_neg_integer(),
            col: non_neg_integer(),
            width: pos_integer(),
            height: pos_integer(),
            box_row: non_neg_integer(),
            box_col: non_neg_integer(),
            box_width: pos_integer(),
            box_height: pos_integer()
          }
          | nil
  defp menu_geometry([], _opts), do: nil

  defp menu_geometry(items, opts) do
    item_capacity = max(min(@max_rows, opts.viewport_rows - 2), 1)
    item_count = min(length(items), item_capacity)
    visible_items = Enum.take(items, item_count)
    label_widths = Enum.map(visible_items, fn item -> String.length(item.label) + 4 end)
    desired_width = label_widths |> Enum.max() |> max(@min_width) |> min(@max_width)
    box_width = min(max(desired_width + 2, 3), max(opts.viewport_cols, 1))
    popup_width = max(box_width - 2, 1)
    box_height = min(item_count + 2, max(opts.viewport_rows, 1))
    box_row = menu_box_start_row(opts.cursor_row, opts.viewport_rows, box_height)
    box_col = min(opts.cursor_col, max(0, opts.viewport_cols - box_width))

    %{
      row: box_row + 1,
      col: box_col + 1,
      width: popup_width,
      height: item_count,
      box_row: box_row,
      box_col: box_col,
      box_width: box_width,
      box_height: box_height
    }
  end

  @spec menu_box_start_row(non_neg_integer(), non_neg_integer(), pos_integer()) ::
          non_neg_integer()
  defp menu_box_start_row(cursor_row, viewport_rows, box_height) do
    space_below = viewport_rows - cursor_row - 1
    space_above = cursor_row
    choose_menu_box_start_row(cursor_row, box_height, space_below, space_above, viewport_rows)
  end

  @spec choose_menu_box_start_row(
          non_neg_integer(),
          pos_integer(),
          integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp choose_menu_box_start_row(
         cursor_row,
         box_height,
         space_below,
         _space_above,
         _viewport_rows
       )
       when space_below >= box_height do
    cursor_row + 1
  end

  defp choose_menu_box_start_row(
         cursor_row,
         box_height,
         _space_below,
         space_above,
         _viewport_rows
       )
       when space_above >= box_height do
    cursor_row - box_height
  end

  defp choose_menu_box_start_row(
         cursor_row,
         box_height,
         _space_below,
         _space_above,
         viewport_rows
       ) do
    min(cursor_row + 1, max(viewport_rows - box_height, 0))
  end

  @spec render_menu_border(map(), map()) :: [DisplayList.draw()]
  defp render_menu_border(
         %{box_row: row, box_col: col, box_width: width, box_height: height},
         colors
       ) do
    bg_style = Face.new(bg: colors.bg)
    fill = String.duplicate(" ", width)

    bg_draws =
      for draw_row <- row..(row + height - 1) do
        DisplayList.draw(draw_row, col, fill, bg_style)
      end

    border_style = Face.new(fg: colors.border_fg, bg: colors.bg)
    border_draws = render_menu_border_lines(row, col, width, height, border_style)

    bg_draws ++ border_draws
  end

  @spec render_menu_border_lines(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          Face.t()
        ) :: [DisplayList.draw()]
  defp render_menu_border_lines(row, col, width, 1, style) do
    [DisplayList.draw(row, col, menu_top_border(width), style)]
  end

  defp render_menu_border_lines(row, col, width, height, style) do
    top = DisplayList.draw(row, col, menu_top_border(width), style)
    bottom = DisplayList.draw(row + height - 1, col, menu_bottom_border(width), style)
    sides = render_menu_side_borders(row, col, width, height, style)
    [top, bottom | sides]
  end

  @spec render_menu_side_borders(
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          Face.t()
        ) :: [DisplayList.draw()]
  defp render_menu_side_borders(_row, _col, _width, height, _style) when height <= 2, do: []

  defp render_menu_side_borders(row, col, width, height, style) do
    (row + 1)..(row + height - 2)
    |> Enum.flat_map(fn draw_row ->
      [
        DisplayList.draw(draw_row, col, "│", style),
        DisplayList.draw(draw_row, col + width - 1, "│", style)
      ]
    end)
  end

  @spec menu_top_border(pos_integer()) :: String.t()
  defp menu_top_border(1), do: "╭"
  defp menu_top_border(2), do: "╭╮"
  defp menu_top_border(width), do: "╭" <> String.duplicate("─", width - 2) <> "╮"

  @spec menu_bottom_border(pos_integer()) :: String.t()
  defp menu_bottom_border(1), do: "╰"
  defp menu_bottom_border(2), do: "╰╯"
  defp menu_bottom_border(width), do: "╰" <> String.duplicate("─", width - 2) <> "╯"

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
    bg = colors.bg

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
      DisplayList.draw(
        row,
        col,
        String.pad_trailing(full_text, width),
        Face.new(fg: fg, bg: bg, bold: is_selected)
      )
    ]

    rail_cmds = render_completion_selection_rail(row, col, is_selected, colors)

    # Render kind character with dim color
    kind_cmd =
      DisplayList.draw(row, col + 1, kind_char, Face.new(fg: colors.dim_fg, bg: bg))

    # Render detail with dim color if present
    detail_cmds =
      if detail_part != "" do
        detail_col = col + String.length(label_part) + padding
        [DisplayList.draw(row, detail_col, detail_part, Face.new(fg: colors.dim_fg, bg: bg))]
      else
        []
      end

    cmds ++ rail_cmds ++ [kind_cmd] ++ detail_cmds
  end

  @spec render_completion_selection_rail(non_neg_integer(), non_neg_integer(), boolean(), map()) ::
          [DisplayList.draw()]
  defp render_completion_selection_rail(_row, _col, false, _colors), do: []

  defp render_completion_selection_rail(row, col, true, colors) do
    [DisplayList.draw(row, col, "▌", Face.new(fg: colors.highlight_fg, bg: colors.bg))]
  end

  # ── Documentation preview pane ────────────────────────────────────────────

  @doc_max_width 50
  @doc_max_height 15

  @spec render_doc_preview(
          Completion.item() | nil,
          [Completion.item()],
          non_neg_integer(),
          render_opts(),
          map()
        ) :: [DisplayList.draw()]
  defp render_doc_preview(nil, _items, _sel_offset, _opts, _theme), do: []

  defp render_doc_preview(item, items, _sel_offset, opts, theme) do
    doc_text = item.documentation

    if doc_text == "" do
      []
    else
      render_doc_pane(doc_text, items, opts, theme)
    end
  end

  @spec render_doc_pane(
          String.t(),
          [Completion.item()],
          render_opts(),
          map()
        ) :: [DisplayList.draw()]
  defp render_doc_pane(doc_text, items, opts, theme) do
    # Parse markdown
    parsed_lines = Markdown.parse(doc_text)

    if parsed_lines == [] do
      []
    else
      # Compute the completion popup's bordered position and dimensions.
      geometry = menu_geometry(items, opts)
      item_count = geometry.height
      popup_width = geometry.box_width
      popup_col = geometry.box_col
      popup_row = geometry.box_row

      # Position the doc pane beside the completion popup
      doc_width = min(@doc_max_width, opts.viewport_cols - popup_col - popup_width - 1)
      space_right = opts.viewport_cols - popup_col - popup_width

      {doc_col, effective_width} =
        if space_right >= 25 do
          # Right side of popup
          {popup_col + popup_width, min(doc_width, space_right)}
        else
          # Left side of popup
          left_space = popup_col
          {max(popup_col - min(@doc_max_width, left_space), 0), min(@doc_max_width, left_space)}
        end

      if effective_width < 20 do
        # Not enough room for a doc pane
        []
      else
        doc_height = min(length(parsed_lines) + 2, min(@doc_max_height, item_count))

        # Build content draws (relative coordinates for FloatingWindow)
        content_draws = build_doc_content(parsed_lines, effective_width - 2, theme)

        popup_theme =
          Map.get(theme, :popup, %{bg: 0x21242B, border_fg: 0x5B6268, title_fg: 0xBBC2CF})

        spec = %FloatingWindow.Spec{
          content: content_draws,
          width: {:cols, effective_width},
          height: {:rows, doc_height},
          position: {:anchor, popup_row - 1, doc_col, :below},
          border: :rounded,
          theme: popup_theme,
          viewport: {opts.viewport_rows, opts.viewport_cols}
        }

        FloatingWindow.render(spec)
      end
    end
  end

  @spec build_doc_content([Markdown.parsed_line()], pos_integer(), map()) ::
          [DisplayList.draw()]
  defp build_doc_content(lines, max_width, theme) do
    syntax = Map.get(theme, :syntax, %{})
    editor = Map.get(theme, :editor, %{})
    base_fg = Map.get(editor, :fg, 0xBBC2CF)

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {{segments, _line_type}, row} ->
      render_doc_line(segments, row, max_width, syntax, base_fg)
    end)
  end

  @spec render_doc_line(
          [Markdown.segment()],
          non_neg_integer(),
          pos_integer(),
          map(),
          non_neg_integer()
        ) ::
          [DisplayList.draw()]
  defp render_doc_line(segments, row, max_width, syntax, base_fg) do
    {draws, _col} =
      Enum.reduce(segments, {[], 0}, fn {text, style}, {acc, col} ->
        if col >= max_width do
          {acc, col}
        else
          clipped = String.slice(text, 0, max(max_width - col, 0))
          draw_style = MarkdownStyles.to_draw_opts(style, syntax, base_fg)
          draw = DisplayList.draw(row, col, clipped, draw_style)
          {[draw | acc], col + String.length(text)}
        end
      end)

    Enum.reverse(draws)
  end
end
