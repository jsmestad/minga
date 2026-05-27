defmodule Minga.Frontend.Adapter.TUI.WindowAdapter do
  @moduledoc """
  Proof-of-concept TUI compositor for `Minga.RenderModel.Window`.

  The adapter turns rows with spans and volatile overlays into cell-level `Face` data without depending on `MingaEditor.DisplayList`.
  It is intentionally small: the current TUI path still uses `DisplayList`, but this proves the window model contains enough information for Phase 6.
  """

  import Bitwise

  alias Minga.Core.Face
  alias Minga.Core.Unicode
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.SearchMatch
  alias Minga.RenderModel.Window.Selection
  alias Minga.RenderModel.Window.Span

  @type cell :: %{
          row: non_neg_integer(),
          col: non_neg_integer(),
          text: String.t(),
          face: Face.t()
        }

  @doc "Composites a window model into TUI cells."
  @spec to_cells(Window.t(), keyword()) :: [cell()]
  def to_cells(%Window{} = window, opts \\ []) do
    selection_bg = Keyword.get(opts, :selection_bg, 0x3E4451)
    search_bg = Keyword.get(opts, :search_bg, 0x4F4A26)
    current_search_bg = Keyword.get(opts, :current_search_bg, 0x5B3A3A)
    tab_width = Keyword.get(opts, :tab_width, 2)

    window.rows
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, row_index} ->
      row_to_cells(
        row,
        row_index,
        window.selection,
        window.search_matches,
        selection_bg,
        search_bg,
        current_search_bg,
        tab_width
      )
    end)
  end

  @spec row_to_cells(
          Row.t(),
          non_neg_integer(),
          Selection.t() | nil,
          [SearchMatch.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) :: [cell()]
  defp row_to_cells(
         %Row{} = row,
         row_index,
         selection,
         matches,
         selection_bg,
         search_bg,
         current_search_bg,
         tab_width
       ) do
    {cells, _col} =
      row.text
      |> String.graphemes()
      |> Enum.reduce({[], 0}, fn text, {acc, col} ->
        width = cell_width(text, col, tab_width)
        span = span_at(row.spans, col)
        face = span_face(span)
        face = apply_selection(face, selection, row_index, col, width, selection_bg)
        face = apply_search(face, matches, row_index, col, width, search_bg, current_search_bg)
        {[%{row: row_index, col: col, text: text, face: face} | acc], col + width}
      end)

    Enum.reverse(cells)
  end

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
      underline_style: underline_style(span.attrs),
      font_weight: font_weight(span.font_weight)
    )
  end

  @spec underline_style(non_neg_integer()) :: :line | :curl
  defp underline_style(attrs) do
    if (attrs &&& 0x10) != 0, do: :curl, else: :line
  end

  @spec font_weight(non_neg_integer()) :: Face.font_weight()
  defp font_weight(0), do: :thin
  defp font_weight(1), do: :light
  defp font_weight(2), do: :regular
  defp font_weight(3), do: :medium
  defp font_weight(4), do: :semibold
  defp font_weight(5), do: :bold
  defp font_weight(6), do: :heavy
  defp font_weight(_), do: :black

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
    if selected?(selection, row, col, width), do: face_with_bg(face, selection_bg), else: face
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
      font_weight: face.font_weight,
      font_family: face.font_family
    )
  end
end
