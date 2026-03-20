defmodule Minga.Editor.SemanticWindowTest do
  @moduledoc """
  Tests for SemanticWindow struct building and data capture.

  Verifies that the semantic window captures the same visible content
  as the draw-based rendering pipeline. This is the core validation
  for Phase 1 of #828.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.DisplayList.Cursor
  alias Minga.Editor.Layout
  alias Minga.Editor.RenderPipeline
  alias Minga.Editor.RenderPipeline.Content
  alias Minga.Editor.RenderPipeline.Scroll
  alias Minga.Editor.SemanticWindow
  alias Minga.Editor.SemanticWindow.DiagnosticRange
  alias Minga.Editor.SemanticWindow.SearchMatch
  alias Minga.Editor.SemanticWindow.Selection
  alias Minga.Editor.SemanticWindow.Span
  alias Minga.Editor.SemanticWindow.VisualRow
  alias Minga.Editor.State, as: EditorState
  alias Minga.Face

  alias Minga.Search.Match, as: SearchMatchStruct

  import Minga.Editor.RenderPipeline.TestHelpers

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

  # ── GUI vs TUI gating ─────────────────────────────────────────────────

  describe "GUI/TUI gating" do
    test "WindowFrame.semantic is nil for TUI frontends" do
      state = base_state(content: "hello\nworld")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.semantic == nil
    end

    test "WindowFrame.semantic is populated for GUI frontends" do
      state = gui_state(content: "hello\nworld")
      {[wf], _cursor, _state} = build_content(state)

      assert %SemanticWindow{} = wf.semantic
    end

    test "semantic window has correct window_id" do
      state = gui_state(content: "hello")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.semantic.window_id == state.windows.active
    end
  end

  # ── Core: semantic text matches draw text ──────────────────────────────

  describe "semantic text matches draw text" do
    test "semantic row text matches draw text for plain content" do
      content = "line one\nline two\nline three"
      state = gui_state(content: content)
      {[wf], _cursor, _state} = build_content(state)

      semantic_texts = Enum.map(wf.semantic.rows, & &1.text)
      draw_texts = extract_draw_texts(wf.lines)

      assert semantic_texts == draw_texts
    end

    test "semantic row text matches for single-line buffer" do
      state = gui_state(content: "hello world")
      {[wf], _cursor, _state} = build_content(state)

      [row] = wf.semantic.rows
      [draw_text] = extract_draw_texts(wf.lines)

      assert row.text == draw_text
    end

    test "semantic row text matches for multiline content" do
      content = "alpha\nbeta\ngamma\ndelta\nepsilon"
      state = gui_state(content: content)
      {[wf], _cursor, _state} = build_content(state)

      semantic_texts = Enum.map(wf.semantic.rows, & &1.text)
      assert semantic_texts == ["alpha", "beta", "gamma", "delta", "epsilon"]
    end

    test "empty buffer produces valid semantic window" do
      state = gui_state(content: "")
      {[wf], _cursor, _state} = build_content(state)

      assert %SemanticWindow{} = wf.semantic
      # Empty buffer still has one line (the empty line)
      assert is_list(wf.semantic.rows)
      assert wf.semantic.cursor_row >= 0
      assert wf.semantic.cursor_col >= 0
    end
  end

  # ── Visual rows ────────────────────────────────────────────────────────

  describe "visual rows" do
    test "each row has row_type :normal for regular lines" do
      state = gui_state(content: "a\nb\nc")
      {[wf], _cursor, _state} = build_content(state)

      types = Enum.map(wf.semantic.rows, & &1.row_type)
      assert types == [:normal, :normal, :normal]
    end

    test "buf_line is correctly assigned" do
      state = gui_state(content: "a\nb\nc\nd")
      {[wf], _cursor, _state} = build_content(state)

      buf_lines = Enum.map(wf.semantic.rows, & &1.buf_line)
      assert buf_lines == [0, 1, 2, 3]
    end

    test "content_hash is non-zero for non-empty lines" do
      state = gui_state(content: "hello world")
      {[wf], _cursor, _state} = build_content(state)

      [row] = wf.semantic.rows
      assert row.content_hash != 0
    end

    test "different lines produce different hashes" do
      state = gui_state(content: "hello\nworld")
      {[wf], _cursor, _state} = build_content(state)

      [row1, row2] = wf.semantic.rows
      assert row1.content_hash != row2.content_hash
    end

    test "identical lines produce identical hashes" do
      state = gui_state(content: "same\nsame")
      {[wf], _cursor, _state} = build_content(state)

      [row1, row2] = wf.semantic.rows
      assert row1.content_hash == row2.content_hash
    end

    test "semantic row count matches draw line count" do
      content = "one\ntwo\nthree\nfour\nfive"
      state = gui_state(content: content)
      {[wf], _cursor, _state} = build_content(state)

      assert length(wf.semantic.rows) == map_size(wf.lines)
    end
  end

  # ── Cursor ─────────────────────────────────────────────────────────────

  describe "cursor" do
    test "cursor at row 0, col 0 for new buffer" do
      state = gui_state(content: "hello")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.semantic.cursor_row == 0
      assert wf.semantic.cursor_col == 0
    end

    test "cursor shape is :block in normal mode" do
      state = gui_state(content: "hello")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.semantic.cursor_shape == :block
    end

    test "semantic cursor row is consistent with draw cursor" do
      content = "hello\nworld"
      state = gui_state(content: content)
      {[wf], %Cursor{} = cursor, _state} = build_content(state)

      # Both should be on the first line (row 0 in window-relative coords)
      assert wf.semantic.cursor_row == 0
      assert is_integer(cursor.row)
    end
  end

  # ── Span.from_face/3 ──────────────────────────────────────────────────

  describe "Span.from_face/3" do
    test "encodes bold flag in bit 0" do
      face = Face.new(bold: true)
      span = Span.from_face(face, 0, 10)

      import Bitwise
      assert (span.attrs &&& 1) == 1
    end

    test "encodes italic flag in bit 1" do
      face = Face.new(italic: true)
      span = Span.from_face(face, 0, 10)

      import Bitwise
      assert (span.attrs >>> 1 &&& 1) == 1
    end

    test "encodes underline flag in bit 2" do
      face = Face.new(underline: true)
      span = Span.from_face(face, 0, 10)

      import Bitwise
      assert (span.attrs >>> 2 &&& 1) == 1
    end

    test "encodes strikethrough flag in bit 3" do
      face = Face.new(strikethrough: true)
      span = Span.from_face(face, 0, 10)

      import Bitwise
      assert (span.attrs >>> 3 &&& 1) == 1
    end

    test "encodes curl underline in bit 4" do
      face = Face.new(underline: true, underline_style: :curl)
      span = Span.from_face(face, 0, 5)

      import Bitwise
      assert (span.attrs >>> 4 &&& 1) == 1
    end

    test "packs all attrs into one byte correctly" do
      face = Face.new(bold: true, italic: true, underline: true, strikethrough: true)
      span = Span.from_face(face, 0, 10)

      import Bitwise
      assert (span.attrs &&& 0x0F) == 0x0F
    end

    test "preserves fg and bg colors" do
      face = Face.new(fg: 0xFF6C6B, bg: 0x282C34)
      span = Span.from_face(face, 0, 10)

      assert span.fg == 0xFF6C6B
      assert span.bg == 0x282C34
    end

    test "nil colors default to 0" do
      face = Face.new()
      span = Span.from_face(face, 0, 1)

      assert span.fg == 0
      assert span.bg == 0
    end

    test "preserves column range" do
      face = Face.new(fg: 0xABCDEF)
      span = Span.from_face(face, 3, 17)

      assert span.start_col == 3
      assert span.end_col == 17
    end

    test "encodes font weight" do
      face = Face.new(font_weight: :bold)
      span = Span.from_face(face, 0, 10)

      assert span.font_weight == 5
    end

    test "nil font weight defaults to 0" do
      face = Face.new()
      span = Span.from_face(face, 0, 10)

      assert span.font_weight == 0
    end
  end

  # ── Selection.from_visual_selection/2 ──────────────────────────────────

  describe "Selection.from_visual_selection/2" do
    test "returns nil for no selection" do
      assert Selection.from_visual_selection(nil, 0) == nil
    end

    test "converts char selection to display coordinates" do
      sel = Selection.from_visual_selection({:char, {5, 3}, {7, 10}}, 0)

      assert sel.type == :char
      assert sel.start_row == 5
      assert sel.start_col == 3
      assert sel.end_row == 7
      assert sel.end_col == 10
    end

    test "char selection adjusts for viewport scroll offset" do
      sel = Selection.from_visual_selection({:char, {5, 3}, {7, 10}}, 2)

      assert sel.start_row == 3
      assert sel.end_row == 5
    end

    test "converts line selection to display coordinates" do
      sel = Selection.from_visual_selection({:line, 10, 15}, 5)

      assert sel.type == :line
      assert sel.start_row == 5
      assert sel.end_row == 10
    end
  end

  # ── SearchMatch.from_context_matches/4 ─────────────────────────────────

  describe "SearchMatch.from_context_matches/4" do
    test "filters matches to visible viewport range" do
      matches = [
        %SearchMatchStruct{line: 0, col: 5, length: 3},
        %SearchMatchStruct{line: 3, col: 2, length: 4},
        %SearchMatchStruct{line: 5, col: 0, length: 2},
        %SearchMatchStruct{line: 8, col: 1, length: 3},
        %SearchMatchStruct{line: 12, col: 0, length: 5}
      ]

      result = SearchMatch.from_context_matches(matches, nil, 3, 10)

      lines = Enum.map(result, & &1.row)
      # Lines 3, 5, 8 are in viewport [3, 10). Converted to display rows: 0, 2, 5
      assert lines == [0, 2, 5]
    end

    test "converts buffer line to display row" do
      matches = [%SearchMatchStruct{line: 5, col: 10, length: 3}]

      [match] = SearchMatch.from_context_matches(matches, nil, 3, 10)

      assert match.row == 2
      assert match.start_col == 10
      assert match.end_col == 13
    end

    test "marks exactly one match as current" do
      confirm = %SearchMatchStruct{line: 5, col: 2, length: 4}

      matches = [
        %SearchMatchStruct{line: 3, col: 0, length: 2},
        confirm,
        %SearchMatchStruct{line: 7, col: 1, length: 3}
      ]

      result = SearchMatch.from_context_matches(matches, confirm, 0, 10)

      current_flags = Enum.map(result, & &1.is_current)
      assert current_flags == [false, true, false]
    end

    test "empty matches produces empty result" do
      assert SearchMatch.from_context_matches([], nil, 0, 24) == []
    end

    test "all matches outside viewport produces empty result" do
      matches = [
        %SearchMatchStruct{line: 100, col: 0, length: 5},
        %SearchMatchStruct{line: 200, col: 0, length: 3}
      ]

      assert SearchMatch.from_context_matches(matches, nil, 0, 24) == []
    end
  end

  # ── DiagnosticRange.from_diagnostics/3 ─────────────────────────────────

  describe "DiagnosticRange.from_diagnostics/3" do
    test "filters diagnostics to visible line range" do
      diagnostics = [
        %Minga.Diagnostics.Diagnostic{
          range: %{start_line: 1, start_col: 0, end_line: 1, end_col: 5},
          severity: :error,
          message: "err"
        },
        %Minga.Diagnostics.Diagnostic{
          range: %{start_line: 5, start_col: 0, end_line: 5, end_col: 10},
          severity: :warning,
          message: "warn"
        },
        %Minga.Diagnostics.Diagnostic{
          range: %{start_line: 30, start_col: 0, end_line: 30, end_col: 3},
          severity: :info,
          message: "info"
        }
      ]

      result = DiagnosticRange.from_diagnostics(diagnostics, 0, 10)

      # Lines 1 and 5 in viewport [0, 10), line 30 is out
      assert length(result) == 2
    end

    test "converts buffer coordinates to display coordinates" do
      diagnostics = [
        %Minga.Diagnostics.Diagnostic{
          range: %{start_line: 5, start_col: 3, end_line: 5, end_col: 10},
          severity: :error,
          message: "err"
        }
      ]

      [range] = DiagnosticRange.from_diagnostics(diagnostics, 2, 10)

      assert range.start_row == 3
      assert range.start_col == 3
      assert range.end_row == 3
      assert range.end_col == 10
    end

    test "maps all severity levels correctly" do
      make_diag = fn line, severity ->
        %Minga.Diagnostics.Diagnostic{
          range: %{start_line: line, start_col: 0, end_line: line, end_col: 5},
          severity: severity,
          message: "msg"
        }
      end

      diagnostics = [
        make_diag.(0, :error),
        make_diag.(1, :warning),
        make_diag.(2, :info),
        make_diag.(3, :hint)
      ]

      result = DiagnosticRange.from_diagnostics(diagnostics, 0, 10)

      severities = Enum.map(result, & &1.severity)
      assert severities == [:error, :warning, :info, :hint]
    end

    test "empty diagnostics produces empty result" do
      assert DiagnosticRange.from_diagnostics([], 0, 24) == []
    end

    test "all diagnostics outside viewport produces empty result" do
      diagnostics = [
        %Minga.Diagnostics.Diagnostic{
          range: %{start_line: 50, start_col: 0, end_line: 50, end_col: 5},
          severity: :error,
          message: "err"
        }
      ]

      assert DiagnosticRange.from_diagnostics(diagnostics, 0, 24) == []
    end
  end

  # ── VisualRow.compute_hash/2 ───────────────────────────────────────────

  describe "VisualRow.compute_hash/2" do
    test "same inputs produce same hash" do
      h1 = VisualRow.compute_hash("hello", [])
      h2 = VisualRow.compute_hash("hello", [])
      assert h1 == h2
    end

    test "different text produces different hash" do
      h1 = VisualRow.compute_hash("hello", [])
      h2 = VisualRow.compute_hash("world", [])
      assert h1 != h2
    end

    test "same text with different spans produces different hash" do
      span_bold = %Span{start_col: 0, end_col: 5, fg: 0xFF0000, bg: 0, attrs: 1}
      span_italic = %Span{start_col: 0, end_col: 5, fg: 0xFF0000, bg: 0, attrs: 2}

      h1 = VisualRow.compute_hash("hello", [span_bold])
      h2 = VisualRow.compute_hash("hello", [span_italic])
      assert h1 != h2
    end
  end

  # ── Integration: semantic window in render pipeline ────────────────────

  describe "integration: semantic window in full pipeline" do
    test "semantic selection is nil when not in visual mode" do
      state = gui_state(content: "hello\nworld")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.semantic.selection == nil
    end

    test "semantic search_matches is empty when no search" do
      state = gui_state(content: "hello world")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.semantic.search_matches == []
    end

    test "semantic diagnostic_ranges is empty when no diagnostics" do
      state = gui_state(content: "hello world")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.semantic.diagnostic_ranges == []
    end

    test "full_refresh is true on initial render" do
      state = gui_state(content: "hello")
      {[wf], _cursor, _state} = build_content(state)

      assert wf.semantic.full_refresh == true
    end
  end
end
