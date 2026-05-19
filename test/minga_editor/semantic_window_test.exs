defmodule MingaEditor.SemanticWindowTest do
  @moduledoc """
  Tests for SemanticWindow struct building and data capture.

  Verifies that the semantic window captures the same visible content
  as the draw-based rendering pipeline. This is the core validation
  for Phase 1 of #828.
  """

  use ExUnit.Case, async: true

  alias MingaEditor.DisplayList.Cursor
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.SemanticWindow
  alias MingaEditor.SemanticWindow.DiagnosticRange
  alias MingaEditor.SemanticWindow.SearchMatch
  alias MingaEditor.SemanticWindow.Selection
  alias MingaEditor.SemanticWindow.Span
  alias MingaEditor.SemanticWindow.VisualRow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Renderer.Context
  alias MingaEditor.UI.FontRegistry
  alias MingaEditor.UI.Highlight
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Decorations
  alias Minga.Core.Face

  alias Minga.Editing.Search.Match, as: SearchMatchStruct

  import MingaEditor.RenderPipeline.TestHelpers

  # Runs through scroll + content stages, returns {frames, cursor, state}
  defp build_content(state) do
    state = EditorState.sync_active_window_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)
    Content.build_content(state, scrolls)
  end

  # Extracts text from draw layer (render_layer is %{row => [{col, text, style}]})
  defp extract_draw_texts(render_layer) do
    render_layer
    |> Enum.sort_by(fn {row, _runs} -> row end)
    |> Enum.map(fn {_row, runs} ->
      runs
      |> Enum.sort_by(fn {col, _text, _style} -> col end)
      |> Enum.map_join(fn {_col, text, _style} -> text end)
    end)
  end

  defp gui_frame(content) do
    state = gui_state(content: content)
    {[wf], cursor, state} = build_content(state)
    {wf, cursor, state}
  end

  defp semantic_row_texts(wf), do: Enum.map(wf.semantic.rows, & &1.text)

  defp diagnostic(line, severity \\ :error) do
    %Minga.Diagnostics.Diagnostic{
      range: %{start_line: line, start_col: 0, end_line: line, end_col: 5},
      severity: severity,
      message: "msg"
    }
  end

  # ── Font registry ─────────────────────────────────────────────────────

  describe "font registry" do
    test "semantic spans allocate font ids through the render-local registry" do
      face = %Face{name: "semantic-font", fg: 0xFFFFFF, bg: 0x000000, font_family: "Fira Code"}

      span =
        FontRegistry.with_process_registry(FontRegistry.new(), fn ->
          span = Span.from_face(face, 0, 5)
          registry = FontRegistry.process_registry()
          assert FontRegistry.pending_registrations(registry) == [{1, "Fira Code"}]
          span
        end)

      assert span.font_id == 1
      assert FontRegistry.process_registry() == nil
    end
  end

  # ── GUI vs TUI gating ─────────────────────────────────────────────────

  describe "GUI/TUI gating" do
    test "semantic window follows frontend capability and records the active window id" do
      tui_state = base_state(content: "hello\nworld")
      {[tui_frame], _cursor, _state} = build_content(tui_state)
      assert tui_frame.semantic == nil

      state = gui_state(content: "hello\nworld")
      {[wf], _cursor, _state} = build_content(state)

      assert %SemanticWindow{} = wf.semantic
      assert wf.semantic.window_id == state.workspace.windows.active
    end
  end

  # ── Core: semantic text matches draw text ──────────────────────────────

  describe "semantic text matches draw text" do
    test "semantic row text matches draw text for plain content shapes" do
      for content <- [
            "hello world",
            "line one\nline two\nline three",
            "alpha\nbeta\ngamma\ndelta\nepsilon"
          ] do
        {wf, _cursor, _state} = gui_frame(content)

        assert semantic_row_texts(wf) == extract_draw_texts(wf.lines)
      end
    end

    test "semantic spans include TODO keyword faces" do
      state = gui_state(content: "# TODO ship")
      {[wf], _cursor, _state} = build_content(state)

      [row] = wf.semantic.rows
      todo_span = Enum.find(row.spans, fn span -> span.start_col == 2 and span.end_col == 6 end)

      assert row.text == "# TODO ship"
      assert todo_span.fg == 0xECBE7B
      assert Bitwise.band(todo_span.attrs, 1) == 1
    end

    test "folded semantic rows keep the fold suffix neutral when hidden lines contain TODOs" do
      full_lines = ["alpha", "  # TODO hidden", "  # TODO visible"]
      state = gui_state(content: Enum.join(full_lines, "\n"))
      buffer = state.workspace.buffers.active
      win_id = state.workspace.windows.active
      window = Map.fetch!(state.workspace.windows.map, win_id)
      layout = Layout.get(state)
      win_layout = Map.fetch!(layout.window_layouts, win_id)
      snapshot = BufferProcess.render_snapshot(buffer, 0, 3)
      line1_off = Highlight.byte_offset_for_line(full_lines, 1)
      line2_off = Highlight.byte_offset_for_line(full_lines, 2)
      todo_face = Face.new(fg: 0xECBE7B, bold: true)
      comment_face = [fg: 0x6A737D]

      hl =
        Highlight.new(%{"comment" => comment_face})
        |> Highlight.put_names(["comment"])
        |> Highlight.put_spans(1, [
          %{
            start_byte: line1_off,
            end_byte: line1_off + byte_size(Enum.at(full_lines, 1)),
            capture_id: 0
          },
          %{
            start_byte: line2_off,
            end_byte: line2_off + byte_size(Enum.at(full_lines, 2)),
            capture_id: 0
          }
        ])

      scroll = %WindowScroll{
        win_id: win_id,
        window: window,
        win_layout: win_layout,
        is_active: true,
        viewport: state.workspace.viewport,
        cursor_line: 0,
        cursor_byte_col: 0,
        cursor_col: 0,
        first_line: 0,
        lines: snapshot.lines,
        snapshot: snapshot,
        gutter_w: 4,
        content_w: state.workspace.viewport.cols - 4,
        has_sign_column: false,
        preview_matches: [],
        line_number_style: :absolute,
        wrap_on: false,
        buf_version: snapshot.version,
        width_oracle: %Minga.Core.WidthOracle.Monospace{},
        visible_line_map: [{0, {:fold_start, 1}}, {2, :normal}]
      }

      ctx = %Context{
        viewport: state.workspace.viewport,
        gutter_w: 4,
        content_w: state.workspace.viewport.cols - 4,
        highlight: hl,
        decorations: Decorations.new(),
        hl_todo_faces: %{todo: todo_face}
      }

      semantic = SemanticWindow.Builder.build(state, scroll, ctx)

      [fold_row, visible_row] = semantic.rows
      suffix = " ··· 1 lines"

      assert fold_row.row_type == :fold_start
      assert visible_row.row_type == :normal
      assert fold_row.text == "alpha#{suffix}"
      assert visible_row.text =~ "TODO"

      assert Enum.any?(fold_row.spans, fn span ->
               span.start_col == String.length("alpha") and span.fg == ctx.gutter_colors.fold_fg and
                 Bitwise.band(span.attrs, 1) == 0
             end)

      assert Enum.any?(visible_row.spans, fn span ->
               span.fg == todo_face.fg and Bitwise.band(span.attrs, 1) == 1
             end)
    end

    test "semantic row text includes invisible markers when enabled" do
      state = gui_state(content: "\thello   ")

      assert {:ok, true} =
               BufferProcess.set_option(state.workspace.buffers.active, :show_invisible, true)

      {[wf], _cursor, _state} = build_content(state)

      [row] = wf.semantic.rows
      [draw_text] = extract_draw_texts(wf.lines)
      assert row.text == draw_text
      assert row.text =~ "→"
      assert row.text =~ "hello···"
    end

    test "empty buffer produces valid semantic window" do
      {wf, _cursor, _state} = gui_frame("")

      assert %SemanticWindow{} = wf.semantic
      assert is_list(wf.semantic.rows)
      assert wf.semantic.cursor_row >= 0
      assert wf.semantic.cursor_col >= 0
    end
  end

  # ── Visual rows ────────────────────────────────────────────────────────

  describe "visual rows" do
    test "rows carry normal type, buffer line, and draw row count" do
      {wf, _cursor, _state} = gui_frame("a\nb\nc\nd")

      assert Enum.map(wf.semantic.rows, & &1.row_type) == [:normal, :normal, :normal, :normal]
      assert Enum.map(wf.semantic.rows, & &1.buf_line) == [0, 1, 2, 3]
      assert length(wf.semantic.rows) == map_size(wf.lines)
    end

    test "content hashes reflect row content" do
      {wf, _cursor, _state} = gui_frame("hello world")
      [row] = wf.semantic.rows
      assert row.content_hash != 0

      {wf, _cursor, _state} = gui_frame("hello\nworld")
      [row1, row2] = wf.semantic.rows
      assert row1.content_hash != row2.content_hash

      {wf, _cursor, _state} = gui_frame("same\nsame")
      [row1, row2] = wf.semantic.rows
      assert row1.content_hash == row2.content_hash
    end
  end

  # ── Cursor ─────────────────────────────────────────────────────────────

  describe "cursor" do
    test "new buffer cursor metadata matches normal-mode draw cursor" do
      {wf, %Cursor{} = cursor, _state} = gui_frame("hello\nworld")

      assert wf.semantic.cursor_row == 0
      assert wf.semantic.cursor_col == 0
      assert wf.semantic.cursor_shape == :block
      assert is_integer(cursor.row)
    end

    test "block cursor at end of line renders over the final character cell" do
      state = gui_state(content: "this")
      :ok = BufferProcess.move_to(state.workspace.buffers.active, {0, byte_size("this")})

      {[wf], _cursor, _state} = build_content(state)

      assert [%{text: "this"}] = wf.semantic.rows
      assert wf.semantic.cursor_shape == :block
      assert wf.semantic.cursor_col == 3
    end
  end

  # ── Span.from_face/3 ──────────────────────────────────────────────────

  describe "Span.from_face/3" do
    test "encodes face attributes into protocol bits" do
      cases = [
        {Face.new(bold: true), 0},
        {Face.new(italic: true), 1},
        {Face.new(underline: true), 2},
        {Face.new(strikethrough: true), 3},
        {Face.new(underline: true, underline_style: :curl), 4}
      ]

      for {face, bit} <- cases do
        span = Span.from_face(face, 0, 10)
        assert Bitwise.band(Bitwise.bsr(span.attrs, bit), 1) == 1
      end

      packed =
        Span.from_face(
          Face.new(bold: true, italic: true, underline: true, strikethrough: true),
          0,
          10
        )

      assert Bitwise.band(packed.attrs, 0x0F) == 0x0F
    end

    test "preserves colors and column range with nil color defaults" do
      span = Span.from_face(Face.new(fg: 0xFF6C6B, bg: 0x282C34), 3, 17)

      assert span.fg == 0xFF6C6B
      assert span.bg == 0x282C34
      assert span.start_col == 3
      assert span.end_col == 17

      default_span = Span.from_face(Face.new(), 0, 1)
      assert default_span.fg == 0
      assert default_span.bg == 0
    end

    test "encodes font weight using shared frontend protocol values" do
      cases = [
        thin: 0,
        light: 1,
        regular: 2,
        medium: 3,
        semibold: 4,
        bold: 5,
        heavy: 6,
        black: 7
      ]

      for {weight, value} <- cases do
        assert Span.from_face(Face.new(font_weight: weight), 0, 10).font_weight == value
      end

      assert Span.from_face(Face.new(), 0, 10).font_weight == 2
      assert Span.from_face(Face.new(bold: true), 0, 10).font_weight == 5
    end
  end

  # ── Selection.from_visual_selection ────────────────────────────────────

  describe "Selection.from_visual_selection/2" do
    test "converts basic selections into display coordinates" do
      assert Selection.from_visual_selection(nil, 0) == nil

      char = Selection.from_visual_selection({:char, {5, 3}, {7, 10}}, 0)

      assert {char.type, char.start_row, char.start_col, char.end_row, char.end_col} ==
               {:char, 5, 3, 7, 10}

      scrolled = Selection.from_visual_selection({:char, {5, 3}, {7, 10}}, 2)
      assert {scrolled.start_row, scrolled.end_row} == {3, 5}

      line = Selection.from_visual_selection({:line, 10, 15}, 5)
      assert {line.type, line.start_row, line.end_row} == {:line, 5, 10}
    end
  end

  describe "Selection.from_visual_selection/5" do
    test "clips visible selections to the viewport" do
      cases = [
        {{:char, {2, 4}, {7, 10}}, 5, 4, 0, 80, {:char, 0, 0, 2, 10}},
        {{:char, {5, 4}, {12, 10}}, 5, 4, 2, 80, {:char, 0, 4, 3, 82}},
        {{:char, {8, 0}, {8, 5}}, 5, 4, 0, 80, {:char, 3, 0, 3, 5}},
        {{:char, {5, 2}, {5, 20}}, 5, 4, 10, 80, {:char, 0, 10, 0, 20}},
        {{:char, {5, 4}, {5, 200}}, 5, 4, 0, 80, {:char, 0, 4, 0, 80}},
        {{:line, 1, 10}, 5, 4, 0, 80, {:line, 0, 0, 3, 0}}
      ]

      for {selection, first_line, row_count, viewport_left, content_w, expected} <- cases do
        sel =
          Selection.from_visual_selection(
            selection,
            first_line,
            row_count,
            viewport_left,
            content_w
          )

        assert {sel.type, sel.start_row, sel.start_col, sel.end_row, sel.end_col} == expected
      end
    end

    test "drops selections entirely outside the viewport" do
      cases = [
        {:char, {1, 0}, {3, 4}},
        {:char, {20, 0}, {25, 4}},
        {:char, {9, 0}, {9, 5}}
      ]

      for selection <- cases do
        assert Selection.from_visual_selection(selection, 5, 4, 0, 80) == nil
      end
    end
  end

  # ── SearchMatch.from_context_matches/4 ─────────────────────────────────

  describe "SearchMatch.from_context_matches/4" do
    test "filters visible matches and converts buffer coordinates" do
      matches = [
        %SearchMatchStruct{line: 0, col: 5, length: 3},
        %SearchMatchStruct{line: 3, col: 2, length: 4},
        %SearchMatchStruct{line: 5, col: 10, length: 3},
        %SearchMatchStruct{line: 8, col: 1, length: 3},
        %SearchMatchStruct{line: 12, col: 0, length: 5}
      ]

      result = SearchMatch.from_context_matches(matches, nil, 3, 10)

      assert Enum.map(result, & &1.row) == [0, 2, 5]
      assert Enum.map(result, &{&1.start_col, &1.end_col}) == [{2, 6}, {10, 13}, {1, 4}]
    end

    test "marks the confirmed match as current" do
      confirm = %SearchMatchStruct{line: 5, col: 2, length: 4}

      matches = [
        %SearchMatchStruct{line: 3, col: 0, length: 2},
        confirm,
        %SearchMatchStruct{line: 7, col: 1, length: 3}
      ]

      result = SearchMatch.from_context_matches(matches, confirm, 0, 10)

      assert Enum.map(result, & &1.is_current) == [false, true, false]
    end

    test "returns empty when there are no visible matches" do
      outside = [
        %SearchMatchStruct{line: 100, col: 0, length: 5},
        %SearchMatchStruct{line: 200, col: 0, length: 3}
      ]

      assert SearchMatch.from_context_matches([], nil, 0, 24) == []
      assert SearchMatch.from_context_matches(outside, nil, 0, 24) == []
    end
  end

  # ── DiagnosticRange.from_diagnostics/3 ─────────────────────────────────

  describe "DiagnosticRange.from_diagnostics/3" do
    test "filters visible diagnostics and converts coordinates" do
      diagnostics = [
        diagnostic(1, :error),
        diagnostic(5, :warning),
        diagnostic(30, :info)
      ]

      result = DiagnosticRange.from_diagnostics(diagnostics, 0, 10)
      assert Enum.map(result, & &1.severity) == [:error, :warning]

      precise = %Minga.Diagnostics.Diagnostic{
        range: %{start_line: 5, start_col: 3, end_line: 5, end_col: 10},
        severity: :error,
        message: "err"
      }

      [range] = DiagnosticRange.from_diagnostics([precise], 2, 10)
      assert {range.start_row, range.start_col, range.end_row, range.end_col} == {3, 3, 3, 10}
    end

    test "maps severity levels and returns empty without visible diagnostics" do
      diagnostics = Enum.with_index([:error, :warning, :info, :hint], &diagnostic(&2, &1))

      assert DiagnosticRange.from_diagnostics(diagnostics, 0, 10) |> Enum.map(& &1.severity) == [
               :error,
               :warning,
               :info,
               :hint
             ]

      assert DiagnosticRange.from_diagnostics([], 0, 24) == []
      assert DiagnosticRange.from_diagnostics([diagnostic(50)], 0, 24) == []
    end
  end

  # ── VisualRow.compute_hash/2 ───────────────────────────────────────────

  describe "VisualRow.compute_hash/2" do
    test "hashes are stable and reflect text or span changes" do
      assert VisualRow.compute_hash("hello", []) == VisualRow.compute_hash("hello", [])
      assert VisualRow.compute_hash("hello", []) != VisualRow.compute_hash("world", [])

      span_bold = %Span{start_col: 0, end_col: 5, fg: 0xFF0000, bg: 0, attrs: 1}
      span_italic = %Span{start_col: 0, end_col: 5, fg: 0xFF0000, bg: 0, attrs: 2}

      assert VisualRow.compute_hash("hello", [span_bold]) !=
               VisualRow.compute_hash("hello", [span_italic])
    end
  end

  # ── Integration: semantic window in render pipeline ────────────────────

  describe "integration: semantic window in full pipeline" do
    test "initial semantic metadata is empty and marked as full refresh" do
      {wf, _cursor, _state} = gui_frame("hello\nworld")

      assert wf.semantic.selection == nil
      assert wf.semantic.search_matches == []
      assert wf.semantic.diagnostic_ranges == []
      assert wf.semantic.full_refresh == true
    end
  end
end
