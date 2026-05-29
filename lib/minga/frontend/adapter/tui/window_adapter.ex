defmodule Minga.Frontend.Adapter.TUI.WindowAdapter do
  @moduledoc """
  TUI compositor for `Minga.RenderModel.Window`.

  The adapter turns rows with spans, gutter metadata, and volatile overlays into cell-level `Face` data without depending on `MingaEditor.DisplayList`. The editor emit path may still translate these cells into the existing draw protocol, but buffer-window visible truth now comes from `Minga.RenderModel.Window`.
  """

  import Bitwise

  alias Minga.Core.Face
  alias Minga.Core.Unicode
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.Cursorline
  alias Minga.RenderModel.Window.Gutter
  alias Minga.RenderModel.Window.GutterEntry
  alias Minga.RenderModel.Window.IndentGuides
  alias Minga.RenderModel.Window.PaneGeometry
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.SearchMatch
  alias Minga.RenderModel.Window.Selection
  alias Minga.RenderModel.Window.Span

  @sign_text_width 2

  @default_selection_bg 0x3E4451
  @default_search_bg 0x4F4A26
  @default_current_search_bg 0x5B3A3A
  @default_gutter_fg 0x5B6268
  @default_gutter_current_fg 0xBBC2CF
  @default_error_fg 0xFF6C6B
  @default_warning_fg 0xECBE7B
  @default_info_fg 0x51AFEF
  @default_hint_fg 0x98BE65
  @default_tilde_fg 0x5B6268

  @typep overlay_opts :: %{
           selection: Selection.t() | nil,
           matches: [SearchMatch.t()],
           selection_bg: non_neg_integer(),
           search_bg: non_neg_integer(),
           current_search_bg: non_neg_integer(),
           tab_width: pos_integer(),
           scroll_left: non_neg_integer(),
           visible_cols: non_neg_integer(),
           cursorline_row: non_neg_integer() | nil,
           cursorline_bg: non_neg_integer() | nil
         }

  @type cell :: %{
          row: non_neg_integer(),
          col: non_neg_integer(),
          text: String.t(),
          face: Face.t()
        }

  @doc "Composites only text rows into window-relative TUI cells."
  @spec to_cells(Window.t(), keyword()) :: [cell()]
  def to_cells(%Window{} = window, opts \\ []) do
    {_row, _col, width} = text_rect(window)
    overlays = overlay_opts(opts, window, nil, 0, width)
    content_cells(window.rows, overlays, 0, 0)
  end

  @doc "Composites gutter, text rows, and tilde filler into absolute screen cells."
  @spec to_screen_cells(Window.t(), keyword()) :: [cell()]
  def to_screen_cells(%Window{} = window, opts \\ []) do
    gutter_cells(window, opts) ++
      cursorline_fill_cells(window, opts) ++
      content_screen_cells(window, opts) ++
      indent_guide_cells(window, opts) ++ tilde_cells(window, opts)
  end

  @spec overlay_opts(
          keyword(),
          Window.t(),
          non_neg_integer() | nil,
          non_neg_integer(),
          non_neg_integer()
        ) :: overlay_opts()
  defp overlay_opts(opts, %Window{} = window, cursorline_row, scroll_left, visible_cols) do
    %{
      selection: window.selection,
      matches: window.search_matches,
      selection_bg: Keyword.get(opts, :selection_bg, @default_selection_bg),
      search_bg: Keyword.get(opts, :search_bg, @default_search_bg),
      current_search_bg: Keyword.get(opts, :current_search_bg, @default_current_search_bg),
      tab_width: max(Keyword.get(opts, :tab_width, 2), 1),
      scroll_left: scroll_left,
      visible_cols: visible_cols,
      cursorline_row: cursorline_row,
      cursorline_bg: cursorline_bg(window)
    }
  end

  @spec content_screen_cells(Window.t(), keyword()) :: [cell()]
  defp content_screen_cells(%Window{} = window, opts) do
    {row_offset, col_offset, visible_cols} = text_rect(window)
    scroll_left = window.scroll_left
    overlays = overlay_opts(opts, window, cursorline_row(window), scroll_left, visible_cols)
    content_cells(window.rows, overlays, row_offset, col_offset)
  end

  @spec cursorline_fill_cells(Window.t(), keyword()) :: [cell()]
  defp cursorline_fill_cells(%Window{} = window, opts) do
    case {cursorline_row(window), cursorline_bg(window)} do
      {row, bg} when is_integer(row) and is_integer(bg) ->
        do_cursorline_fill_cells(window, opts, row, bg)

      _ ->
        []
    end
  end

  @spec do_cursorline_fill_cells(Window.t(), keyword(), non_neg_integer(), non_neg_integer()) :: [
          cell()
        ]
  defp do_cursorline_fill_cells(%Window{} = window, opts, row, bg) do
    {row_offset, col_offset, visible_cols} = text_rect(window)
    row_index = row - row_offset

    if row_index >= 0 and row_index < visible_rows(window) and visible_cols > 0 do
      occupied =
        occupied_visible_cols(
          Enum.at(window.rows, row_index),
          window.scroll_left,
          visible_cols,
          opts
        )

      fill_face = Face.new(bg: bg)

      0..(visible_cols - 1)
      |> Enum.reject(&MapSet.member?(occupied, &1))
      |> Enum.map(fn col -> %{row: row, col: col_offset + col, text: " ", face: fill_face} end)
    else
      []
    end
  end

  @spec occupied_visible_cols(Row.t() | nil, non_neg_integer(), non_neg_integer(), keyword()) ::
          MapSet.t(non_neg_integer())
  defp occupied_visible_cols(nil, _scroll_left, _visible_cols, _opts), do: MapSet.new()

  defp occupied_visible_cols(%Row{} = row, scroll_left, visible_cols, opts) do
    tab_width = max(Keyword.get(opts, :tab_width, 2), 1)
    visible_right = scroll_left + visible_cols

    {_col, occupied} =
      row.text
      |> String.graphemes()
      |> Enum.reduce({0, MapSet.new()}, fn text, {col, occupied} ->
        width = cell_width(text, col, tab_width)
        occupied = add_occupied_cols(occupied, col, width, scroll_left, visible_right)
        {col + width, occupied}
      end)

    occupied
  end

  @spec add_occupied_cols(
          MapSet.t(non_neg_integer()),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: MapSet.t(non_neg_integer())
  defp add_occupied_cols(occupied, col, width, scroll_left, visible_right) do
    if col >= scroll_left and col + width <= visible_right do
      Enum.reduce(col..(col + width - 1), occupied, fn occupied_col, acc ->
        MapSet.put(acc, occupied_col - scroll_left)
      end)
    else
      occupied
    end
  end

  @spec content_cells([Row.t()], overlay_opts(), non_neg_integer(), non_neg_integer()) :: [cell()]
  defp content_cells(rows, overlays, row_offset, col_offset) do
    rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, row_index} ->
      row_to_cells(row, row_index, overlays, row_offset, col_offset)
    end)
  end

  @spec row_to_cells(
          Row.t(),
          non_neg_integer(),
          overlay_opts(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [cell()]
  defp row_to_cells(%Row{} = row, row_index, overlays, row_offset, col_offset) do
    {cells, _col} =
      row.text
      |> String.graphemes()
      |> Enum.reduce({[], 0}, fn text, {acc, col} ->
        width = cell_width(text, col, overlays.tab_width)
        span = span_at(row.spans, col)
        face = span_face(span)
        screen_row = row_index + row_offset
        face = apply_cursorline(face, screen_row, overlays)

        face =
          apply_selection(face, overlays.selection, row_index, col, width, overlays.selection_bg)

        face =
          apply_search(
            face,
            overlays.matches,
            row_index,
            col,
            width,
            overlays.search_bg,
            overlays.current_search_bg
          )

        cell = %{
          row: screen_row,
          col: col - overlays.scroll_left + col_offset,
          text: text,
          face: face
        }

        acc = if visible_cell?(col, width, overlays), do: [cell | acc], else: acc
        {acc, col + width}
      end)

    Enum.reverse(cells)
  end

  @spec gutter_cells(Window.t(), keyword()) :: [cell()]
  defp gutter_cells(%Window{gutter: nil}, _opts), do: []

  defp gutter_cells(%Window{gutter: %Gutter{} = gutter, rows: rows}, opts) do
    gutter.entries
    |> Enum.take(min(gutter.content_height, length(rows)))
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, row_index} ->
      gutter_entry_cells(entry, row_index, gutter, opts)
    end)
  end

  @spec gutter_entry_cells(GutterEntry.t(), non_neg_integer(), Gutter.t(), keyword()) :: [cell()]
  defp gutter_entry_cells(%GutterEntry{} = entry, row_index, %Gutter{} = gutter, opts) do
    row = gutter.content_row + row_index
    sign_col = gutter.content_col
    fold_col = sign_col + @sign_text_width
    number_col = gutter.content_col + gutter.sign_col_width

    sign_cell(entry, row, sign_col, opts) ++
      fold_cell(entry, row, fold_col, opts) ++
      line_number_cell(entry, row, number_col, gutter, opts)
  end

  @spec sign_cell(GutterEntry.t(), non_neg_integer(), non_neg_integer(), keyword()) :: [cell()]
  defp sign_cell(%GutterEntry{} = entry, row, col, opts) do
    {text, fg} = sign_text_and_color(entry, opts)
    [%{row: row, col: col, text: pad_sign_text(text), face: Face.new(fg: fg)}]
  end

  @spec sign_text_and_color(GutterEntry.t(), keyword()) :: {String.t(), non_neg_integer()}
  defp sign_text_and_color(%GutterEntry{sign_type: :diag_error}, opts),
    do: {"E ", Keyword.get(opts, :gutter_error_fg, @default_error_fg)}

  defp sign_text_and_color(%GutterEntry{sign_type: :diag_warning}, opts),
    do: {"W ", Keyword.get(opts, :gutter_warning_fg, @default_warning_fg)}

  defp sign_text_and_color(%GutterEntry{sign_type: :diag_info}, opts),
    do: {"I ", Keyword.get(opts, :gutter_info_fg, @default_info_fg)}

  defp sign_text_and_color(%GutterEntry{sign_type: :diag_hint}, opts),
    do: {"H ", Keyword.get(opts, :gutter_hint_fg, @default_hint_fg)}

  defp sign_text_and_color(%GutterEntry{sign_type: :git_added}, opts),
    do: {"▎ ", Keyword.get(opts, :git_added_fg, @default_hint_fg)}

  defp sign_text_and_color(%GutterEntry{sign_type: :git_modified}, opts),
    do: {"▎ ", Keyword.get(opts, :git_modified_fg, @default_warning_fg)}

  defp sign_text_and_color(%GutterEntry{sign_type: :git_removed}, opts),
    do: {"- ", Keyword.get(opts, :git_deleted_fg, @default_error_fg)}

  defp sign_text_and_color(%GutterEntry{sign_type: :git_deleted}, opts),
    do: {"▁ ", Keyword.get(opts, :git_deleted_fg, @default_error_fg)}

  defp sign_text_and_color(
         %GutterEntry{sign_type: :annotation, sign_text: text, sign_fg: fg},
         opts
       ),
       do: {text || "", fg || Keyword.get(opts, :gutter_fg, @default_gutter_fg)}

  defp sign_text_and_color(%GutterEntry{}, opts),
    do: {"  ", Keyword.get(opts, :gutter_fg, @default_gutter_fg)}

  @spec pad_sign_text(String.t()) :: String.t()
  defp pad_sign_text(text) do
    text
    |> String.slice(0, @sign_text_width)
    |> String.pad_trailing(@sign_text_width)
  end

  @spec fold_cell(GutterEntry.t(), non_neg_integer(), non_neg_integer(), keyword()) :: [cell()]
  defp fold_cell(%GutterEntry{} = entry, row, col, opts) do
    [
      %{
        row: row,
        col: col,
        text: fold_text(entry.display_type),
        face: Face.new(fg: Keyword.get(opts, :gutter_fold_fg, @default_gutter_fg))
      }
    ]
  end

  @spec fold_text(GutterEntry.display_type()) :: String.t()
  defp fold_text(:fold_start), do: "▶"
  defp fold_text(:fold_open), do: "▼"
  defp fold_text(_display_type), do: " "

  @spec line_number_cell(
          GutterEntry.t(),
          non_neg_integer(),
          non_neg_integer(),
          Gutter.t(),
          keyword()
        ) :: [cell()]
  defp line_number_cell(_entry, _row, _col, %Gutter{line_number_style: :none}, _opts), do: []
  defp line_number_cell(_entry, _row, _col, %Gutter{line_number_width: 0}, _opts), do: []

  defp line_number_cell(
         %GutterEntry{display_type: display_type},
         row,
         col,
         %Gutter{} = gutter,
         opts
       )
       when display_type in [:wrap_continuation, :blank] do
    width = max(gutter.line_number_width - 1, 0)
    text = String.duplicate(" ", width)

    [
      %{
        row: row,
        col: col,
        text: text,
        face: Face.new(fg: Keyword.get(opts, :gutter_fg, @default_gutter_fg))
      }
    ]
  end

  defp line_number_cell(%GutterEntry{} = entry, row, col, %Gutter{} = gutter, opts) do
    number = line_number_value(entry.buf_line, gutter.cursor_line, gutter.line_number_style)
    fg = line_number_color(entry.buf_line, gutter.cursor_line, gutter.line_number_style, opts)
    width = max(gutter.line_number_width - 1, 0)
    text = number |> Integer.to_string() |> String.pad_leading(width)
    [%{row: row, col: col, text: text, face: Face.new(fg: fg)}]
  end

  @spec line_number_value(non_neg_integer(), non_neg_integer(), Gutter.line_number_style()) ::
          non_neg_integer()
  defp line_number_value(buf_line, _cursor_line, :absolute), do: buf_line + 1
  defp line_number_value(buf_line, cursor_line, :relative), do: abs(buf_line - cursor_line)

  defp line_number_value(buf_line, cursor_line, :hybrid) when buf_line == cursor_line,
    do: buf_line + 1

  defp line_number_value(buf_line, cursor_line, :hybrid), do: abs(buf_line - cursor_line)
  defp line_number_value(buf_line, _cursor_line, _style), do: buf_line + 1

  @spec line_number_color(
          non_neg_integer(),
          non_neg_integer(),
          Gutter.line_number_style(),
          keyword()
        ) :: non_neg_integer()
  defp line_number_color(buf_line, cursor_line, :absolute, opts) when buf_line == cursor_line,
    do: Keyword.get(opts, :gutter_current_fg, @default_gutter_current_fg)

  defp line_number_color(buf_line, cursor_line, :hybrid, opts) when buf_line == cursor_line,
    do: Keyword.get(opts, :gutter_current_fg, @default_gutter_current_fg)

  defp line_number_color(_buf_line, _cursor_line, _style, opts),
    do: Keyword.get(opts, :gutter_fg, @default_gutter_fg)

  @spec indent_guide_cells(Window.t(), keyword()) :: [cell()]
  defp indent_guide_cells(%Window{indent_guides: nil}, _opts), do: []
  defp indent_guide_cells(%Window{indent_guides: %IndentGuides{guide_cols: []}}, _opts), do: []

  defp indent_guide_cells(%Window{indent_guides: %IndentGuides{} = guides} = window, opts) do
    {row_offset, col_offset, visible_cols} = text_rect(window)
    scroll_left = window.scroll_left
    visible_right = scroll_left + visible_cols

    active_fg =
      Keyword.get(
        opts,
        :indent_guide_active_fg,
        Keyword.get(opts, :gutter_current_fg, @default_gutter_current_fg)
      )

    fg = Keyword.get(opts, :indent_guide_fg, Keyword.get(opts, :gutter_fg, @default_gutter_fg))

    window.rows
    |> Enum.zip(guides.line_indent_levels)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{%Row{} = row, indent_level}, row_index} ->
      indent_guide_row_cells(guides, row, indent_level, row_index, %{
        row_offset: row_offset,
        col_offset: col_offset,
        scroll_left: scroll_left,
        visible_right: visible_right,
        active_fg: active_fg,
        fg: fg
      })
    end)
  end

  @spec indent_guide_row_cells(
          IndentGuides.t(),
          Row.t(),
          non_neg_integer(),
          non_neg_integer(),
          map()
        ) :: [
          cell()
        ]
  defp indent_guide_row_cells(
         %IndentGuides{} = guides,
         %Row{} = row,
         indent_level,
         row_index,
         opts
       ) do
    leading_width = leading_whitespace_width(row.text, guides.tab_width)
    blank? = String.trim(row.text) == ""

    guides.guide_cols
    |> Enum.filter(fn col ->
      guide_visible?(col, indent_level, guides.tab_width, leading_width, blank?, opts)
    end)
    |> Enum.map(fn col ->
      indent_guide_cell(col, row_index, guides.active_guide_col, opts)
    end)
  end

  @spec indent_guide_cell(non_neg_integer(), non_neg_integer(), non_neg_integer(), map()) ::
          cell()
  defp indent_guide_cell(col, row_index, active_guide_col, opts) do
    guide_fg = if col == active_guide_col, do: opts.active_fg, else: opts.fg

    %{
      row: opts.row_offset + row_index,
      col: opts.col_offset + col - opts.scroll_left,
      text: "│",
      face: Face.new(fg: guide_fg)
    }
  end

  @spec guide_visible?(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          map()
        ) :: boolean()
  defp guide_visible?(_col, _indent_level, 0, _leading_width, _blank?, _opts), do: false

  defp guide_visible?(col, indent_level, tab_width, leading_width, blank?, opts) do
    col >= opts.scroll_left and col < opts.visible_right and div(col, tab_width) <= indent_level and
      (blank? or col < leading_width)
  end

  @spec leading_whitespace_width(String.t(), non_neg_integer()) :: non_neg_integer()
  defp leading_whitespace_width(text, tab_width) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({0, 0}, fn
      " ", {width, col} ->
        {:cont, {width + 1, col + 1}}

      "\t", {width, col} ->
        tab_stop = tab_width - rem(col, max(tab_width, 1))
        {:cont, {width + tab_stop, col + tab_stop}}

      _grapheme, {width, _col} ->
        {:halt, {width, 0}}
    end)
    |> elem(0)
  end

  @spec tilde_cells(Window.t(), keyword()) :: [cell()]
  defp tilde_cells(%Window{} = window, opts) do
    {row_offset, col_offset} = text_origin(window)
    visible_rows = visible_rows(window)
    tilde_cells_from(length(window.rows), visible_rows, row_offset, col_offset, opts)
  end

  @spec tilde_cells_from(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) :: [cell()]
  defp tilde_cells_from(rows_used, visible_rows, _row_offset, _col_offset, _opts)
       when rows_used >= visible_rows, do: []

  defp tilde_cells_from(rows_used, visible_rows, row_offset, col_offset, opts) do
    tilde_fg = Keyword.get(opts, :tilde_fg, @default_tilde_fg)

    Enum.map(rows_used..(visible_rows - 1), fn row ->
      %{row: row_offset + row, col: col_offset, text: "~", face: Face.new(fg: tilde_fg)}
    end)
  end

  @spec text_origin(Window.t()) :: {non_neg_integer(), non_neg_integer()}
  defp text_origin(%Window{} = window) do
    {row, col, _width} = text_rect(window)
    {row, col}
  end

  @spec text_rect(Window.t()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp text_rect(%Window{geometry: %PaneGeometry{text_rect: {row, col, width, _height}}}),
    do: {row, col, width}

  defp text_rect(%Window{rect: {row, col, width, _height}, gutter: gutter}) do
    gutter_width = gutter_width(gutter)
    {row, col + gutter_width, max(width - gutter_width, 0)}
  end

  @spec visible_rows(Window.t()) :: non_neg_integer()
  defp visible_rows(%Window{geometry: %PaneGeometry{text_rect: {_row, _col, _width, height}}}),
    do: height

  defp visible_rows(%Window{rect: {_row, _col, _width, height}}), do: height

  @spec gutter_width(Gutter.t() | nil) :: non_neg_integer()
  defp gutter_width(nil), do: 0

  defp gutter_width(%Gutter{
         line_number_width: line_number_width,
         sign_col_width: sign_col_width
       }),
       do: line_number_width + sign_col_width

  @spec cell_width(String.t(), non_neg_integer(), pos_integer()) :: pos_integer()
  defp cell_width("\t", col, tab_width), do: tab_width - rem(col, tab_width)
  defp cell_width(text, _col, _tab_width), do: max(Unicode.display_width(text), 1)

  @spec span_at([Span.t()], non_neg_integer()) :: Span.t() | nil
  defp span_at(spans, col) do
    Enum.find(spans, fn span -> col >= span.start_col and col < span.end_col end)
  end

  @spec span_face(Span.t() | nil) :: Face.t()
  defp span_face(nil), do: Face.new()

  defp span_face(%Span{} = span) do
    Face.new(
      fg: span.fg,
      bg: span.bg,
      bold: (span.attrs &&& 0x01) != 0,
      italic: (span.attrs &&& 0x02) != 0,
      underline: (span.attrs &&& 0x04) != 0,
      strikethrough: (span.attrs &&& 0x08) != 0,
      underline_style: underline_style(span.attrs)
    )
  end

  @spec underline_style(non_neg_integer()) :: :line | :curl
  defp underline_style(attrs) do
    if (attrs &&& 0x10) != 0, do: :curl, else: :line
  end

  @spec visible_cell?(non_neg_integer(), pos_integer(), overlay_opts()) :: boolean()
  defp visible_cell?(col, width, overlays) do
    col >= overlays.scroll_left and col + width <= overlays.scroll_left + overlays.visible_cols
  end

  @spec cursorline_row(Window.t()) :: non_neg_integer() | nil
  defp cursorline_row(%Window{cursorline: %Cursorline{row: 0xFFFF}}), do: nil
  defp cursorline_row(%Window{cursorline: %Cursorline{row: row}}), do: row
  defp cursorline_row(%Window{}), do: nil

  @spec cursorline_bg(Window.t()) :: non_neg_integer() | nil
  defp cursorline_bg(%Window{cursorline: %Cursorline{row: 0xFFFF}}), do: nil
  defp cursorline_bg(%Window{cursorline: %Cursorline{bg_rgb: bg}}), do: bg
  defp cursorline_bg(%Window{}), do: nil

  @spec apply_cursorline(Face.t(), non_neg_integer(), overlay_opts()) :: Face.t()
  defp apply_cursorline(%Face{} = face, row, %{cursorline_row: row, cursorline_bg: bg})
       when is_integer(bg), do: face_with_bg(face, bg)

  defp apply_cursorline(%Face{} = face, _row, _overlays), do: face

  @spec apply_selection(
          Face.t(),
          Selection.t() | nil,
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) :: Face.t()
  defp apply_selection(%Face{} = face, nil, _row, _col, _width, _selection_bg), do: face

  defp apply_selection(%Face{} = face, %Selection{} = selection, row, col, width, selection_bg) do
    if selected?(selection, row, col, width),
      do: face_with_selection(face, selection_bg),
      else: face
  end

  @spec selected?(Selection.t(), non_neg_integer(), non_neg_integer(), pos_integer()) :: boolean()
  defp selected?(
         %Selection{type: :line, start_row: start_row, end_row: end_row},
         row,
         _col,
         _width
       ),
       do: row >= start_row and row <= end_row

  defp selected?(
         %Selection{
           type: :block,
           start_row: start_row,
           start_col: start_col,
           end_row: end_row,
           end_col: end_col
         },
         row,
         col,
         width
       ) do
    row >= min(start_row, end_row) and row <= max(start_row, end_row) and
      ranges_overlap?(col, col + width, min(start_col, end_col), max(start_col, end_col))
  end

  defp selected?(
         %Selection{
           type: _type,
           start_row: start_row,
           start_col: start_col,
           end_row: end_row,
           end_col: end_col
         },
         row,
         col,
         width
       ) do
    after_start? = row > start_row or (row == start_row and col + width > start_col)
    before_end? = row < end_row or (row == end_row and col < end_col)
    after_start? and before_end?
  end

  @spec apply_search(
          Face.t(),
          [SearchMatch.t()],
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: Face.t()
  defp apply_search(%Face{} = face, matches, row, col, width, search_bg, current_search_bg) do
    case Enum.find(matches, fn match ->
           match.row == row and ranges_overlap?(col, col + width, match.start_col, match.end_col)
         end) do
      %SearchMatch{is_current: true} -> face_with_bg(face, current_search_bg)
      %SearchMatch{} -> face_with_bg(face, search_bg)
      nil -> face
    end
  end

  @spec ranges_overlap?(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: boolean()
  defp ranges_overlap?(left_start, left_end, right_start, right_end) do
    left_end > right_start and left_start < right_end
  end

  @spec face_with_selection(Face.t(), non_neg_integer()) :: Face.t()
  defp face_with_selection(%Face{} = face, bg) do
    Face.new(
      fg: face.fg,
      bg: bg,
      bold: face.bold,
      italic: face.italic,
      underline: face.underline,
      strikethrough: face.strikethrough,
      underline_style: face.underline_style,
      reverse: true
    )
  end

  @spec face_with_bg(Face.t(), non_neg_integer()) :: Face.t()
  defp face_with_bg(%Face{} = face, bg) do
    Face.new(
      fg: face.fg,
      bg: bg,
      bold: face.bold,
      italic: face.italic,
      underline: face.underline,
      strikethrough: face.strikethrough,
      underline_style: face.underline_style,
      reverse: face.reverse
    )
  end
end
