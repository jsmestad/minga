defmodule Minga.Frontend.Adapter.TUI.WindowAdapterTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.TUI.WindowAdapter
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

  test "screen cells use pane geometry and include gutter plus tilde filler" do
    model =
      %Window{
        window_id: 1,
        content_kind: :buffer,
        rect: {5, 10, 20, 3},
        geometry: %PaneGeometry{
          window_id: 1,
          total_rect: {5, 10, 20, 3},
          content_rect: {5, 10, 20, 3},
          text_rect: {5, 14, 16, 3},
          gutter_rect: {5, 10, 4, 3},
          clip_rect: {5, 14, 16, 3},
          viewport: nil,
          gutter_metrics: nil,
          hit_regions: []
        },
        gutter: %Gutter{
          window_id: 1,
          content_row: 5,
          content_col: 10,
          content_height: 3,
          is_active: true,
          content_width: 20,
          cursor_line: 0,
          line_number_style: :absolute,
          line_number_width: 1,
          sign_col_width: 3,
          entries: [%GutterEntry{buf_line: 0, display_type: :fold_open, sign_type: :diag_error}]
        },
        rows: [
          %Row{
            row_id: Row.stable_id(:normal, 0),
            row_type: :normal,
            buf_line: 0,
            text: "abc",
            spans: [],
            content_hash: 1
          }
        ],
        cursor_row: 0,
        cursor_col: 0,
        cursor_shape: :block
      }

    cells = WindowAdapter.to_screen_cells(model, gutter_error_fg: 0xFF0000, tilde_fg: 0x777777)

    assert Enum.any?(cells, fn cell ->
             cell.row == 5 and cell.col == 10 and cell.text == "E " and cell.face.fg == 0xFF0000
           end)

    assert Enum.any?(cells, fn cell -> cell.row == 5 and cell.col == 12 and cell.text == "▼" end)
    assert Enum.any?(cells, fn cell -> cell.row == 5 and cell.col == 14 and cell.text == "a" end)

    assert Enum.any?(cells, fn cell ->
             cell.row == 6 and cell.col == 14 and cell.text == "~" and cell.face.fg == 0x777777
           end)

    assert Enum.any?(cells, fn cell -> cell.row == 7 and cell.col == 14 and cell.text == "~" end)
  end

  test "removed diff signs render minus markers" do
    model = %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 0, 10, 1},
      geometry: %PaneGeometry{
        window_id: 1,
        total_rect: {0, 0, 10, 1},
        content_rect: {0, 0, 10, 1},
        text_rect: {0, 4, 6, 1},
        gutter_rect: {0, 0, 4, 1},
        clip_rect: {0, 4, 6, 1},
        viewport: nil,
        gutter_metrics: nil,
        hit_regions: []
      },
      gutter: %Gutter{
        window_id: 1,
        content_row: 0,
        content_col: 0,
        content_height: 1,
        is_active: true,
        content_width: 10,
        cursor_line: 0,
        line_number_style: :absolute,
        line_number_width: 1,
        sign_col_width: 3,
        entries: [%GutterEntry{buf_line: 0, display_type: :normal, sign_type: :git_removed}]
      },
      rows: [
        %Row{
          row_id: Row.stable_id(:normal, 0),
          row_type: :normal,
          buf_line: 0,
          text: "abc",
          spans: [],
          content_hash: 1
        }
      ],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block
    }

    cells = WindowAdapter.to_screen_cells(model, git_deleted_fg: 0xAA0000)

    assert Enum.any?(cells, fn cell ->
             cell.row == 0 and cell.col == 0 and cell.text == "- " and cell.face.fg == 0xAA0000
           end)
  end

  test "blank gutter entries leave line-number cells blank" do
    model = %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 0, 10, 3},
      geometry: %PaneGeometry{
        window_id: 1,
        total_rect: {0, 0, 10, 3},
        content_rect: {0, 0, 10, 3},
        text_rect: {0, 5, 5, 3},
        gutter_rect: {0, 0, 5, 3},
        clip_rect: {0, 5, 5, 3},
        viewport: nil,
        gutter_metrics: nil,
        hit_regions: []
      },
      gutter: %Gutter{
        window_id: 1,
        content_row: 0,
        content_col: 0,
        content_height: 3,
        is_active: true,
        content_width: 10,
        cursor_line: 0,
        line_number_style: :absolute,
        line_number_width: 2,
        sign_col_width: 3,
        entries: [
          %GutterEntry{buf_line: 0, display_type: :normal, sign_type: :none},
          %GutterEntry{buf_line: 0, display_type: :wrap_continuation, sign_type: :none},
          %GutterEntry{buf_line: 0, display_type: :blank, sign_type: :none}
        ]
      },
      rows: [
        %Row{
          row_id: Row.stable_id(:normal, 0),
          row_type: :normal,
          buf_line: 0,
          text: "abcde",
          spans: [],
          content_hash: 1
        },
        %Row{
          row_id: Row.stable_id(:wrap_continuation, 0, 1),
          row_type: :wrap_continuation,
          buf_line: 0,
          text: "fghij",
          spans: [],
          content_hash: 2
        },
        %Row{
          row_id: Row.stable_decoration_id(:virtual_line, 0, :test),
          row_type: :virtual_line,
          buf_line: 0,
          text: "virt",
          spans: [],
          content_hash: 3
        }
      ],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block
    }

    cells = WindowAdapter.to_screen_cells(model)

    assert Enum.any?(cells, fn cell -> cell.row == 0 and cell.col == 3 and cell.text == "1" end)
    assert Enum.any?(cells, fn cell -> cell.row == 1 and cell.col == 3 and cell.text == " " end)
    assert Enum.any?(cells, fn cell -> cell.row == 2 and cell.col == 3 and cell.text == " " end)

    refute Enum.any?(cells, fn cell ->
             cell.row in [1, 2] and cell.col == 3 and cell.text == "1"
           end)
  end

  test "screen cells clip and rebase text by horizontal scroll" do
    model = %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 0, 6, 1},
      geometry: %PaneGeometry{
        window_id: 1,
        total_rect: {0, 0, 6, 1},
        content_rect: {0, 0, 6, 1},
        text_rect: {0, 2, 4, 1},
        gutter_rect: {0, 0, 2, 1},
        clip_rect: {0, 2, 4, 1},
        viewport: nil,
        gutter_metrics: nil,
        hit_regions: []
      },
      rows: [
        %Row{
          row_id: Row.stable_id(:normal, 0),
          row_type: :normal,
          buf_line: 0,
          text: "abcdef",
          spans: [],
          content_hash: 1
        }
      ],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      scroll_left: 2
    }

    cells = WindowAdapter.to_screen_cells(model)

    assert Enum.map(cells, &{&1.text, &1.row, &1.col}) == [
             {"c", 0, 2},
             {"d", 0, 3},
             {"e", 0, 4},
             {"f", 0, 5}
           ]
  end

  test "screen cells rebase overlays after horizontal scroll" do
    model = %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: {0, 0, 6, 1},
      geometry: %PaneGeometry{
        window_id: 1,
        total_rect: {0, 0, 6, 1},
        content_rect: {0, 0, 6, 1},
        text_rect: {0, 2, 4, 1},
        gutter_rect: {0, 0, 2, 1},
        clip_rect: {0, 2, 4, 1},
        viewport: nil,
        gutter_metrics: nil,
        hit_regions: []
      },
      rows: [
        %Row{
          row_id: Row.stable_id(:normal, 0),
          row_type: :normal,
          buf_line: 0,
          text: "abcdef",
          spans: [],
          content_hash: 1
        }
      ],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      scroll_left: 2,
      selection: %Selection{type: :char, start_row: 0, start_col: 1, end_row: 0, end_col: 4},
      search_matches: [%SearchMatch{row: 0, start_col: 3, end_col: 5, is_current: false}]
    }

    cells = WindowAdapter.to_screen_cells(model, selection_bg: 0x111111, search_bg: 0x222222)
    by_text = Map.new(cells, fn cell -> {cell.text, cell} end)

    assert by_text["c"].col == 2
    assert by_text["c"].face.bg == 0x111111
    assert by_text["d"].col == 3
    assert by_text["d"].face.bg == 0x222222
    assert by_text["e"].col == 4
    assert by_text["e"].face.bg == 0x222222
    assert by_text["f"].col == 5
    assert by_text["f"].face.bg == nil
  end

  test "screen cells include cursorline and indent guides from the model" do
    model = %Window{
      window_id: 1,
      content_kind: :buffer,
      rect: {5, 10, 20, 2},
      geometry: %PaneGeometry{
        window_id: 1,
        total_rect: {5, 10, 20, 2},
        content_rect: {5, 10, 20, 2},
        text_rect: {5, 14, 16, 2},
        gutter_rect: {5, 10, 4, 2},
        clip_rect: {5, 14, 16, 2},
        viewport: nil,
        gutter_metrics: nil,
        hit_regions: []
      },
      rows: [
        %Row{
          row_id: Row.stable_id(:normal, 0),
          row_type: :normal,
          buf_line: 0,
          text: "  child",
          spans: [],
          content_hash: 1
        },
        %Row{
          row_id: Row.stable_id(:normal, 1),
          row_type: :normal,
          buf_line: 1,
          text: "",
          spans: [],
          content_hash: 2
        }
      ],
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      cursorline: %Cursorline{row: 5, bg_rgb: 0x123456},
      indent_guides: %IndentGuides{
        window_id: 1,
        tab_width: 2,
        active_guide_col: 0,
        guide_cols: [0],
        line_indent_levels: [0, 0]
      }
    }

    cells = WindowAdapter.to_screen_cells(model, indent_guide_active_fg: 0xABCDEF)

    assert Enum.any?(cells, fn cell ->
             cell.row == 5 and cell.col == 14 and cell.text == " " and cell.face.bg == 0x123456
           end)

    assert Enum.any?(cells, fn cell ->
             cell.row == 5 and cell.col == 14 and cell.text == "│" and cell.face.fg == 0xABCDEF
           end)

    assert Enum.any?(cells, fn cell ->
             cell.row == 5 and cell.col == 21 and cell.text == " " and cell.face.bg == 0x123456
           end)

    assert Enum.any?(cells, fn cell ->
             cell.row == 6 and cell.col == 14 and cell.text == "│" and cell.face.fg == 0xABCDEF
           end)
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
