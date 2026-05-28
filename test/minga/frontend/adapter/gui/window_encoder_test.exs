defmodule Minga.Frontend.Adapter.GUI.WindowEncoderTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI, as: AdapterGUI
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.WindowEncoder
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.Window
  alias Minga.RenderModel.Window.Annotation
  alias Minga.RenderModel.Window.Cursorline
  alias Minga.RenderModel.Window.DiagnosticRange
  alias Minga.RenderModel.Window.DocumentHighlight
  alias Minga.RenderModel.Window.Gutter
  alias Minga.RenderModel.Window.GutterEntry
  alias Minga.RenderModel.Window.GutterMetrics
  alias Minga.RenderModel.Window.HitRegion
  alias Minga.RenderModel.Window.IndentGuides
  alias Minga.RenderModel.Window.PaneGeometry
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.SearchMatch
  alias Minga.RenderModel.Window.Selection
  alias Minga.RenderModel.Window.Span
  alias Minga.RenderModel.Window.Viewport
  alias Minga.Test.GUIWindowDecoder

  defp window(opts) do
    %Window{
      window_id: Keyword.get(opts, :window_id, 1),
      content_kind: Keyword.get(opts, :content_kind, :buffer),
      rect: Keyword.get(opts, :rect, {0, 0, 80, 20}),
      rows: Keyword.get(opts, :rows, []),
      cursor_row: Keyword.get(opts, :cursor_row, 0),
      cursor_col: Keyword.get(opts, :cursor_col, 0),
      cursor_shape: Keyword.get(opts, :cursor_shape, :block),
      cursor_visible: Keyword.get(opts, :cursor_visible, true),
      scroll_left: Keyword.get(opts, :scroll_left, 0),
      selection: Keyword.get(opts, :selection, nil),
      search_matches: Keyword.get(opts, :search_matches, []),
      diagnostic_ranges: Keyword.get(opts, :diagnostic_ranges, []),
      document_highlights: Keyword.get(opts, :document_highlights, []),
      annotations: Keyword.get(opts, :annotations, []),
      gutter: Keyword.get(opts, :gutter, nil),
      cursorline: Keyword.get(opts, :cursorline, nil),
      indent_guides: Keyword.get(opts, :indent_guides, nil),
      geometry: Keyword.get(opts, :geometry, nil),
      content_epoch: Keyword.get(opts, :content_epoch, 0),
      full_refresh: Keyword.get(opts, :full_refresh, true)
    }
  end

  defp geometry_model do
    %PaneGeometry{
      window_id: 1,
      total_rect: {1, 2, 40, 12},
      content_rect: {2, 3, 38, 10},
      text_rect: {2, 8, 33, 10},
      gutter_rect: {2, 3, 5, 10},
      clip_rect: {2, 8, 33, 10},
      viewport: %Viewport{top: 5, left: 2, rows: 10, cols: 33, total_lines: 200},
      gutter_metrics: %GutterMetrics{line_number_width: 2, sign_col_width: 3},
      hit_regions: [
        %HitRegion{kind: :text, rect: {2, 8, 33, 10}, window_id: 1},
        %HitRegion{kind: :gutter, rect: {2, 3, 5, 10}, window_id: 1},
        %HitRegion{kind: :fold_control, rect: {2, 7, 1, 10}, window_id: 1},
        %HitRegion{kind: :divider, rect: {0, 41, 1, 20}, window_id: 1},
        %HitRegion{kind: :status_bar, rect: {23, 0, 80, 1}, window_id: 1}
      ]
    }
  end

  defp gutter_model do
    %Gutter{
      window_id: 1,
      content_row: 2,
      content_col: 3,
      content_height: 10,
      is_active: true,
      content_width: 77,
      cursor_line: 4,
      line_number_style: :absolute,
      line_number_width: 2,
      sign_col_width: 3,
      entries: [
        %GutterEntry{
          buf_line: 4,
          display_type: :fold_open,
          sign_type: :diag_warning,
          fold_end_line: 9
        }
      ]
    }
  end

  defp opcodes(commands), do: Enum.map(commands, fn <<opcode::8, _rest::binary>> -> opcode end)

  test "encodes window content from the core window model" do
    row = %Row{
      row_id: Row.stable_id(:normal, 7),
      row_type: :normal,
      buf_line: 7,
      text: "hello",
      spans: [%Span{start_col: 0, end_col: 5, fg: 0xFF0000, bg: 0x000000, attrs: 1}],
      content_hash: 123
    }

    selection = %Selection{type: :char, start_row: 0, start_col: 1, end_row: 0, end_col: 4}

    decoded =
      window(rows: [row], selection: selection)
      |> WindowEncoder.encode_window_content()
      |> GUIWindowDecoder.decode()

    assert decoded.window_id == 1
    assert hd(decoded.rows).text == "hello"
    assert hd(decoded.rows).row_id == Row.stable_id(:normal, 7)
    assert hd(decoded.rows).buf_line == 7
    assert hd(decoded.rows).spans |> hd() |> Map.fetch!(:fg) == 0xFF0000
    assert decoded.selection.start_col == 1
  end

  test "encodes full window content overlays and cursor flags" do
    row = %Row{
      row_id: Row.stable_id(:virtual_line, 11, 0, 4),
      row_type: :virtual_line,
      buf_line: 11,
      text: "héllo",
      spans: [
        %Span{
          start_col: 0,
          end_col: 5,
          fg: 0xAA0000,
          bg: 0x001122,
          attrs: 3,
          font_weight: 2,
          font_id: 4
        }
      ],
      content_hash: 456
    }

    decoded =
      window(
        rows: [row],
        cursor_row: 3,
        cursor_col: 9,
        cursor_shape: :underline,
        cursor_visible: false,
        scroll_left: 2,
        full_refresh: false,
        selection: %Selection{type: :block, start_row: 1, start_col: 2, end_row: 3, end_col: 7},
        search_matches: [%SearchMatch{row: 1, start_col: 0, end_col: 5, is_current: true}],
        diagnostic_ranges: [
          %DiagnosticRange{start_row: 1, start_col: 0, end_row: 1, end_col: 5, severity: :warning}
        ],
        document_highlights: [
          %DocumentHighlight{start_row: 2, start_col: 1, end_row: 2, end_col: 4, kind: :write}
        ],
        annotations: [
          %Annotation{row: 4, kind: :inline_pill, text: "hint", fg: 0x123456, bg: 0x654321}
        ]
      )
      |> WindowEncoder.encode_window_content()
      |> GUIWindowDecoder.decode()

    assert decoded.full_refresh == false
    assert decoded.cursor_visible == false
    assert decoded.cursor_row == 3
    assert decoded.cursor_col == 9
    assert decoded.cursor_shape == :underline
    assert decoded.scroll_left == 2
    assert hd(decoded.rows).row_type == :virtual_line
    assert hd(decoded.rows).row_id == Row.stable_id(:virtual_line, 11, 0, 4)
    assert hd(decoded.rows).text == "héllo"

    assert hd(decoded.rows).spans |> hd() |> Map.take([:attrs, :font_weight, :font_id]) == %{
             attrs: 3,
             font_weight: 2,
             font_id: 4
           }

    assert decoded.selection.type == :block
    assert hd(decoded.search_matches).is_current == true
    assert hd(decoded.diagnostic_ranges).severity == :warning
    assert hd(decoded.document_highlights).kind == :write
    assert hd(decoded.annotations).text == "hint"
  end

  test "encodes content epoch and pane geometry" do
    decoded =
      window(content_epoch: 42, geometry: geometry_model())
      |> WindowEncoder.encode_window_content()
      |> GUIWindowDecoder.decode()

    assert decoded.content_epoch == 42
    assert decoded.geometry.window_id == 1
    assert decoded.geometry.total_rect == {1, 2, 40, 12}
    assert decoded.geometry.text_rect == {2, 8, 33, 10}
    assert decoded.geometry.viewport.top == 5
    assert decoded.geometry.viewport.cols == 33
    assert decoded.geometry.gutter_metrics == %{line_number_width: 2, sign_col_width: 3}

    assert Enum.map(decoded.geometry.hit_regions, & &1.kind) == [
             :text,
             :gutter,
             :fold_control,
             :divider,
             :status_bar
           ]
  end

  test "encodes every selection type" do
    for type <- [:char, :line, :block] do
      decoded =
        window(
          selection: %Selection{type: type, start_row: 1, start_col: 2, end_row: 3, end_col: 4}
        )
        |> WindowEncoder.encode_window_content()
        |> GUIWindowDecoder.decode()

      assert decoded.selection.type == type
      assert decoded.selection.start_row == 1
      assert decoded.selection.end_col == 4
    end
  end

  test "encodes gutter, cursorline, and indent-guide opcodes from model fields" do
    model =
      window(
        gutter: gutter_model(),
        cursorline: %Cursorline{row: 6, bg_rgb: 0x112233},
        indent_guides: %IndentGuides{
          window_id: 1,
          tab_width: 2,
          active_guide_col: 2,
          guide_cols: [2, 4],
          line_indent_levels: [0, 1]
        }
      )

    commands = WindowEncoder.encode(model)
    opcodes = opcodes(commands)

    assert opcodes == [
             Opcodes.gui_window_content(),
             Opcodes.gui_gutter(),
             Opcodes.gui_indent_guides()
           ]

    decoded = commands |> hd() |> GUIWindowDecoder.decode()
    assert decoded.cursorline == %{row: 6, bg_rgb: 0x112233}
  end

  test "adapter re-emits per-frame gutter metadata when window content is cached" do
    model = window(gutter: gutter_model())

    {first_commands, caches} = AdapterGUI.encode_windows([model], Caches.new())
    {second_commands, _caches} = AdapterGUI.encode_windows([model], caches)

    assert opcodes(first_commands) == [Opcodes.gui_window_content(), Opcodes.gui_gutter()]
    assert opcodes(second_commands) == [Opcodes.gui_gutter()]
  end

  test "adapter cache reset re-emits unchanged window content after frontend recovery" do
    model = window(gutter: gutter_model(), content_epoch: 7, full_refresh: true)

    {_first_commands, caches} = AdapterGUI.encode_windows([model], Caches.new())
    {cached_commands, _caches} = AdapterGUI.encode_windows([model], caches)
    {recovered_commands, _caches} = AdapterGUI.encode_windows([model], Caches.new())

    assert opcodes(cached_commands) == [Opcodes.gui_gutter()]
    assert opcodes(recovered_commands) == [Opcodes.gui_window_content(), Opcodes.gui_gutter()]

    recovered_window = recovered_commands |> hd() |> GUIWindowDecoder.decode()
    assert recovered_window.full_refresh == true
    assert recovered_window.content_epoch == 7
  end

  test "adapter reports per-section byte metrics from emitted commands" do
    row = %Row{
      row_id: Row.stable_id(:normal, 7),
      row_type: :normal,
      buf_line: 7,
      text: "hello",
      spans: [%Span{start_col: 0, end_col: 5, fg: 0xFF0000, bg: 0x000000, attrs: 1}],
      content_hash: 123
    }

    model =
      window(
        rows: [row],
        selection: %Selection{type: :char, start_row: 0, start_col: 1, end_row: 0, end_col: 4},
        annotations: [%Annotation{row: 0, kind: :inline_text, text: "hint", fg: 0x123456, bg: 0}],
        gutter: gutter_model(),
        cursorline: %Cursorline{row: 0, bg_rgb: 0x112233}
      )

    {commands, caches, metrics} = AdapterGUI.encode_windows_with_metrics([model], Caches.new())

    assert metrics.row_bytes > 0
    assert metrics.overlay_bytes > 0
    assert metrics.gutter_bytes > 0
    assert metrics.annotation_bytes > 0
    assert metrics.metadata_bytes > 0

    assert IO.iodata_length(commands) ==
             metrics.row_bytes + metrics.overlay_bytes + metrics.gutter_bytes +
               metrics.annotation_bytes + metrics.metadata_bytes

    {cached_commands, _caches, cached_metrics} =
      AdapterGUI.encode_windows_with_metrics([model], caches)

    assert cached_metrics.row_bytes == 0
    assert cached_metrics.overlay_bytes == 0
    assert cached_metrics.annotation_bytes == 0
    assert cached_metrics.gutter_bytes > 0

    assert IO.iodata_length(cached_commands) ==
             cached_metrics.gutter_bytes + cached_metrics.metadata_bytes
  end

  test "adapter encodes first-class non-buffer window models" do
    model = window(content_kind: :agent_prompt, window_id: 65_534)

    {commands, _caches} = AdapterGUI.encode_windows([model], Caches.new())

    assert opcodes(commands) == [Opcodes.gui_window_content()]
    assert commands |> hd() |> GUIWindowDecoder.decode() |> Map.fetch!(:window_id) == 65_534
  end
end
