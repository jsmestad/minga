defmodule Minga.Editor.CompletionUI do
  @moduledoc """
  Renders the LSP completion popup as an overlay near the cursor.

  Produces a list of `DisplayList.draw()` tuples for the completion menu
  and an optional documentation preview pane beside it. The preview pane
  shows the selected item's documentation rendered as formatted markdown.

  The popup is positioned below the cursor if there's room, above if not.
  Sized to fit the visible items up to a maximum of 10 rows and 50 columns.
  The doc preview appears to the right if there's room, to the left if not.
  """

  alias Minga.Agent.Markdown
  alias Minga.Completion
  alias Minga.Editor.DisplayList
  alias Minga.Editor.FloatingWindow
  alias Minga.Editor.MarkdownStyles

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
      # Compute the completion popup's position and dimensions
      item_count = min(length(items), @max_rows)

      label_widths = Enum.map(items, fn i -> String.length(i.label) + 4 end)
      popup_width = label_widths |> Enum.max() |> max(@min_width) |> min(@max_width)
      popup_width = min(popup_width, opts.viewport_cols - opts.cursor_col)
      popup_col = min(opts.cursor_col, max(0, opts.viewport_cols - popup_width))

      space_below = opts.viewport_rows - opts.cursor_row - 2

      popup_row =
        if space_below >= item_count, do: opts.cursor_row + 1, else: opts.cursor_row - item_count

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
