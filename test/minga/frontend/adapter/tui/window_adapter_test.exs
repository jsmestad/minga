defmodule Minga.Frontend.Adapter.TUI.WindowAdapterTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.TUI.WindowAdapter
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.SearchMatch
  alias Minga.RenderModel.Window.Selection
  alias Minga.RenderModel.Window.Span

  defp window(rows, opts) do
    %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 0, 20, length(rows)},
      rows: rows,
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      selection: Keyword.get(opts, :selection, nil),
      search_matches: Keyword.get(opts, :search_matches, [])
    }
  end

  test "composites syntax spans and overlays into cell faces" do
    window =
      window(
        [
          %Row{
            row_id: Row.stable_id(:normal, 0),
            row_type: :normal,
            buf_line: 0,
            text: "abcdef",
            spans: [
              %Span{start_col: 0, end_col: 3, fg: 0xFF0000, bg: 0x000000, attrs: 1},
              %Span{start_col: 3, end_col: 6, fg: 0x00FF00, bg: 0x000000, attrs: 0}
            ],
            content_hash: 1
          }
        ],
        selection: %Selection{type: :char, start_row: 0, start_col: 1, end_row: 0, end_col: 5},
        search_matches: [%SearchMatch{row: 0, start_col: 2, end_col: 4, is_current: true}]
      )

    cells = WindowAdapter.to_cells(window, selection_bg: 0x111111, current_search_bg: 0x222222)

    assert Enum.at(cells, 0).face.fg == 0xFF0000
    assert Enum.at(cells, 0).face.bold == true
    assert Enum.at(cells, 1).face.bg == 0x111111
    assert Enum.at(cells, 2).face.bg == 0x222222
    assert Enum.at(cells, 3).face.fg == 0x00FF00
    assert Enum.at(cells, 3).face.bg == 0x222222
  end

  test "uses display columns for wide grapheme overlays" do
    model =
      window(
        [
          %Row{
            row_id: Row.stable_id(:normal, 0),
            row_type: :normal,
            buf_line: 0,
            text: "a日b",
            spans: [%Span{start_col: 1, end_col: 3, fg: 0x00FF00, bg: 0x000000, attrs: 0}],
            content_hash: 1
          }
        ],
        selection: %Selection{type: :char, start_row: 0, start_col: 2, end_row: 0, end_col: 3}
      )

    cells = WindowAdapter.to_cells(model, selection_bg: 0x111111)

    assert Enum.map(cells, & &1.col) == [0, 1, 3]
    assert Enum.at(cells, 1).text == "日"
    assert Enum.at(cells, 1).face.fg == 0x00FF00
    assert Enum.at(cells, 1).face.bg == 0x111111
  end

  test "tabs advance to the next configured tab stop" do
    model =
      window(
        [
          %Row{
            row_id: Row.stable_id(:normal, 0),
            row_type: :normal,
            buf_line: 0,
            text: "\tb",
            spans: [%Span{start_col: 4, end_col: 5, fg: 0x00FF00, bg: 0x000000, attrs: 0}],
            content_hash: 1
          }
        ],
        []
      )

    cells = WindowAdapter.to_cells(model, tab_width: 4)

    assert Enum.map(cells, & &1.col) == [0, 4]
    assert Enum.at(cells, 1).text == "b"
    assert Enum.at(cells, 1).face.fg == 0x00FF00
  end

  test "block selections select a rectangular column range" do
    model =
      window(
        [
          %Row{
            row_id: Row.stable_id(:normal, 0),
            row_type: :normal,
            buf_line: 0,
            text: "abcd",
            spans: [],
            content_hash: 1
          },
          %Row{
            row_id: Row.stable_id(:normal, 1),
            row_type: :normal,
            buf_line: 1,
            text: "abcd",
            spans: [],
            content_hash: 2
          },
          %Row{
            row_id: Row.stable_id(:normal, 2),
            row_type: :normal,
            buf_line: 2,
            text: "abcd",
            spans: [],
            content_hash: 3
          }
        ],
        selection: %Selection{type: :block, start_row: 0, start_col: 1, end_row: 2, end_col: 3}
      )

    selected =
      model
      |> WindowAdapter.to_cells(selection_bg: 0x111111)
      |> Enum.filter(fn cell -> cell.face.bg == 0x111111 end)
      |> Enum.map(fn cell -> {cell.row, cell.col} end)

    assert selected == [{0, 1}, {0, 2}, {1, 1}, {1, 2}, {2, 1}, {2, 2}]
  end
end
