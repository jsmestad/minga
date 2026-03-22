defmodule Minga.Port.Protocol.GUIWindowContentTest do
  @moduledoc """
  Tests for the gui_window_content (0x80) encoder.

  Uses a test-only decoder for round-trip assertions, plus a few
  intentionally brittle wire format pinning tests that define the
  contract with the Swift decoder.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Editor.SemanticWindow
  alias Minga.Editor.SemanticWindow.DiagnosticRange
  alias Minga.Editor.SemanticWindow.ResolvedAnnotation
  alias Minga.Editor.SemanticWindow.SearchMatch
  alias Minga.Editor.SemanticWindow.Selection
  alias Minga.Editor.SemanticWindow.Span
  alias Minga.Editor.SemanticWindow.VisualRow
  alias Minga.Port.Protocol.GUIWindowContent
  alias Minga.Test.GUIWindowContentDecoder

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp minimal_window(opts) do
    %SemanticWindow{
      window_id: Keyword.get(opts, :window_id, 1),
      rows: Keyword.get(opts, :rows, []),
      cursor_row: Keyword.get(opts, :cursor_row, 0),
      cursor_col: Keyword.get(opts, :cursor_col, 0),
      cursor_shape: Keyword.get(opts, :cursor_shape, :block),
      cursor_visible: Keyword.get(opts, :cursor_visible, true),
      scroll_left: Keyword.get(opts, :scroll_left, 0),
      selection: Keyword.get(opts, :selection, nil),
      search_matches: Keyword.get(opts, :search_matches, []),
      diagnostic_ranges: Keyword.get(opts, :diagnostic_ranges, []),
      annotations: Keyword.get(opts, :annotations, []),
      full_refresh: Keyword.get(opts, :full_refresh, true)
    }
  end

  defp make_row(text, opts \\ []) do
    %VisualRow{
      row_type: Keyword.get(opts, :row_type, :normal),
      buf_line: Keyword.get(opts, :buf_line, 0),
      text: text,
      spans: Keyword.get(opts, :spans, []),
      content_hash: Keyword.get(opts, :content_hash, 12_345)
    }
  end

  defp make_span(start_col, end_col, opts) do
    %Span{
      start_col: start_col,
      end_col: end_col,
      fg: Keyword.get(opts, :fg, 0xFF6C6B),
      bg: Keyword.get(opts, :bg, 0x282C34),
      attrs: Keyword.get(opts, :attrs, 0),
      font_weight: Keyword.get(opts, :font_weight, 0),
      font_id: Keyword.get(opts, :font_id, 0)
    }
  end

  defp round_trip(sw) do
    sw |> GUIWindowContent.encode() |> GUIWindowContentDecoder.decode()
  end

  # ── Round-trip: header fields ──────────────────────────────────────────

  describe "round-trip: header fields" do
    test "all header fields survive round-trip" do
      sw =
        minimal_window(
          window_id: 42,
          cursor_row: 15,
          cursor_col: 33,
          cursor_shape: :beam,
          full_refresh: true
        )

      decoded = round_trip(sw)

      assert decoded.window_id == 42
      assert decoded.cursor_row == 15
      assert decoded.cursor_col == 33
      assert decoded.cursor_shape == :beam
      assert decoded.full_refresh == true
    end

    test "full_refresh false round-trips" do
      decoded = round_trip(minimal_window(full_refresh: false))
      assert decoded.full_refresh == false
    end

    test "cursor_visible true round-trips (default)" do
      decoded = round_trip(minimal_window([]))
      assert decoded.cursor_visible == true
    end

    test "cursor_visible false round-trips (minibuffer active)" do
      decoded = round_trip(minimal_window(cursor_visible: false))
      assert decoded.cursor_visible == false
    end

    test "cursor_visible and full_refresh are independent flag bits" do
      decoded = round_trip(minimal_window(full_refresh: false, cursor_visible: true))
      assert decoded.full_refresh == false
      assert decoded.cursor_visible == true

      decoded = round_trip(minimal_window(full_refresh: true, cursor_visible: false))
      assert decoded.full_refresh == true
      assert decoded.cursor_visible == false
    end

    test "all cursor shapes round-trip" do
      for shape <- [:block, :beam, :underline] do
        decoded = round_trip(minimal_window(cursor_shape: shape))
        assert decoded.cursor_shape == shape
      end
    end
  end

  # ── Round-trip: rows ───────────────────────────────────────────────────

  describe "round-trip: rows" do
    test "row text and buf_line survive round-trip" do
      rows = [make_row("hello", buf_line: 7), make_row("world", buf_line: 8)]
      decoded = round_trip(minimal_window(rows: rows))

      assert length(decoded.rows) == 2
      assert Enum.at(decoded.rows, 0).text == "hello"
      assert Enum.at(decoded.rows, 0).buf_line == 7
      assert Enum.at(decoded.rows, 1).text == "world"
      assert Enum.at(decoded.rows, 1).buf_line == 8
    end

    test "all row types round-trip to distinct values" do
      types = [:normal, :fold_start, :virtual_line, :block, :wrap_continuation]

      rows =
        Enum.with_index(types, fn type, i ->
          make_row("line #{i}", row_type: type, buf_line: i)
        end)

      decoded = round_trip(minimal_window(rows: rows))
      decoded_types = Enum.map(decoded.rows, & &1.row_type)

      assert decoded_types == types
    end

    test "content_hash round-trips" do
      decoded = round_trip(minimal_window(rows: [make_row("x", content_hash: 0xDEADBEEF)]))
      assert hd(decoded.rows).content_hash == 0xDEADBEEF
    end

    test "multi-byte UTF-8 text round-trips" do
      decoded = round_trip(minimal_window(rows: [make_row("🥨日本語héllo")]))
      assert hd(decoded.rows).text == "🥨日本語héllo"
    end

    test "empty text round-trips" do
      decoded = round_trip(minimal_window(rows: [make_row("")]))
      assert hd(decoded.rows).text == ""
    end

    test "row with zero spans round-trips" do
      decoded = round_trip(minimal_window(rows: [make_row("hello", spans: [])]))
      assert hd(decoded.rows).spans == []
    end
  end

  # ── Round-trip: spans ──────────────────────────────────────────────────

  describe "round-trip: spans" do
    test "span columns and colors round-trip" do
      span = make_span(3, 17, fg: 0xFF6C6B, bg: 0x282C34)
      decoded = round_trip(minimal_window(rows: [make_row("x", spans: [span])]))

      [dec_span] = hd(decoded.rows).spans
      assert dec_span.start_col == 3
      assert dec_span.end_col == 17
      assert dec_span.fg == 0xFF6C6B
      assert dec_span.bg == 0x282C34
    end

    test "span attrs and font fields round-trip" do
      span = make_span(0, 5, attrs: 0x0F, font_weight: 5, font_id: 2)
      decoded = round_trip(minimal_window(rows: [make_row("x", spans: [span])]))

      [dec_span] = hd(decoded.rows).spans
      assert dec_span.attrs == 0x0F
      assert dec_span.font_weight == 5
      assert dec_span.font_id == 2
    end

    test "multiple spans per row round-trip" do
      spans = [
        make_span(0, 5, fg: 0xFF0000),
        make_span(5, 10, fg: 0x00FF00),
        make_span(10, 20, fg: 0x0000FF)
      ]

      decoded = round_trip(minimal_window(rows: [make_row("x", spans: spans)]))
      dec_spans = hd(decoded.rows).spans

      assert length(dec_spans) == 3
      assert Enum.at(dec_spans, 0).fg == 0xFF0000
      assert Enum.at(dec_spans, 1).fg == 0x00FF00
      assert Enum.at(dec_spans, 2).fg == 0x0000FF
    end
  end

  # ── Round-trip: selection ──────────────────────────────────────────────

  describe "round-trip: selection" do
    test "nil selection round-trips" do
      decoded = round_trip(minimal_window(selection: nil))
      assert decoded.selection == nil
    end

    test "char selection round-trips" do
      sel = %Selection{type: :char, start_row: 2, start_col: 5, end_row: 7, end_col: 15}
      decoded = round_trip(minimal_window(selection: sel))

      assert decoded.selection.type == :char
      assert decoded.selection.start_row == 2
      assert decoded.selection.start_col == 5
      assert decoded.selection.end_row == 7
      assert decoded.selection.end_col == 15
    end

    test "line selection round-trips" do
      sel = %Selection{type: :line, start_row: 3, start_col: 0, end_row: 10, end_col: 0}
      decoded = round_trip(minimal_window(selection: sel))

      assert decoded.selection.type == :line
      assert decoded.selection.start_row == 3
      assert decoded.selection.end_row == 10
    end

    test "block selection round-trips" do
      sel = %Selection{type: :block, start_row: 1, start_col: 5, end_row: 4, end_col: 20}
      decoded = round_trip(minimal_window(selection: sel))

      assert decoded.selection.type == :block
    end
  end

  # ── Round-trip: search matches ─────────────────────────────────────────

  describe "round-trip: search matches" do
    test "empty matches round-trip" do
      decoded = round_trip(minimal_window(search_matches: []))
      assert decoded.search_matches == []
    end

    test "matches with is_current flag round-trip" do
      matches = [
        %SearchMatch{row: 5, start_col: 10, end_col: 15, is_current: false},
        %SearchMatch{row: 8, start_col: 0, end_col: 3, is_current: true}
      ]

      decoded = round_trip(minimal_window(search_matches: matches))

      assert length(decoded.search_matches) == 2
      [m1, m2] = decoded.search_matches
      assert {m1.row, m1.start_col, m1.end_col, m1.is_current} == {5, 10, 15, false}
      assert {m2.row, m2.start_col, m2.end_col, m2.is_current} == {8, 0, 3, true}
    end
  end

  # ── Round-trip: diagnostic ranges ──────────────────────────────────────

  describe "round-trip: diagnostic ranges" do
    test "empty diagnostics round-trip" do
      decoded = round_trip(minimal_window(diagnostic_ranges: []))
      assert decoded.diagnostic_ranges == []
    end

    test "all severity levels round-trip" do
      make_diag = fn sev ->
        %DiagnosticRange{start_row: 0, start_col: 0, end_row: 0, end_col: 5, severity: sev}
      end

      ranges = Enum.map([:error, :warning, :info, :hint], make_diag)
      decoded = round_trip(minimal_window(diagnostic_ranges: ranges))

      severities = Enum.map(decoded.diagnostic_ranges, & &1.severity)
      assert severities == [:error, :warning, :info, :hint]
    end

    test "diagnostic coordinates round-trip" do
      diag = %DiagnosticRange{
        start_row: 3,
        start_col: 5,
        end_row: 4,
        end_col: 20,
        severity: :warning
      }

      decoded = round_trip(minimal_window(diagnostic_ranges: [diag]))
      [d] = decoded.diagnostic_ranges

      assert {d.start_row, d.start_col, d.end_row, d.end_col} == {3, 5, 4, 20}
    end
  end

  # ── Full round-trip ────────────────────────────────────────────────────

  describe "full round-trip" do
    test "complete window with all sections round-trips" do
      spans = [make_span(0, 5, fg: 0xFF0000), make_span(5, 10, fg: 0x00FF00)]

      rows = [
        make_row("hello", buf_line: 0, spans: spans, row_type: :normal),
        make_row("world", buf_line: 1, row_type: :fold_start)
      ]

      sel = %Selection{type: :char, start_row: 0, start_col: 0, end_row: 0, end_col: 5}

      matches = [
        %SearchMatch{row: 1, start_col: 0, end_col: 5, is_current: true}
      ]

      diags = [
        %DiagnosticRange{
          start_row: 0,
          start_col: 0,
          end_row: 0,
          end_col: 5,
          severity: :error
        }
      ]

      sw =
        minimal_window(
          window_id: 7,
          rows: rows,
          cursor_row: 0,
          cursor_col: 3,
          cursor_shape: :beam,
          selection: sel,
          search_matches: matches,
          diagnostic_ranges: diags,
          full_refresh: true
        )

      decoded = round_trip(sw)

      assert decoded.window_id == 7
      assert decoded.cursor_shape == :beam
      assert length(decoded.rows) == 2
      assert hd(decoded.rows).text == "hello"
      assert length(hd(decoded.rows).spans) == 2
      assert decoded.selection.type == :char
      assert length(decoded.search_matches) == 1
      assert hd(decoded.search_matches).is_current == true
      assert length(decoded.diagnostic_ranges) == 1
      assert hd(decoded.diagnostic_ranges).severity == :error
    end

    test "empty window (0 rows, nil selection, 0 matches, 0 diagnostics) round-trips" do
      decoded = round_trip(minimal_window([]))

      assert decoded.rows == []
      assert decoded.selection == nil
      assert decoded.search_matches == []
      assert decoded.diagnostic_ranges == []
      assert decoded.annotations == []
    end
  end

  # ── Round-trip: line annotations ────────────────────────────────────────

  describe "round-trip: line annotations" do
    test "empty annotations round-trip" do
      decoded = round_trip(minimal_window(annotations: []))
      assert decoded.annotations == []
    end

    test "inline_pill annotation round-trips" do
      ann = %ResolvedAnnotation{
        row: 5,
        kind: :inline_pill,
        fg: 0xFF6C6B,
        bg: 0x3E4452,
        text: "3 errors"
      }

      decoded = round_trip(minimal_window(annotations: [ann]))

      assert length(decoded.annotations) == 1
      [d] = decoded.annotations
      assert d.row == 5
      assert d.kind == :inline_pill
      assert d.fg == 0xFF6C6B
      assert d.bg == 0x3E4452
      assert d.text == "3 errors"
    end

    test "all three annotation kinds round-trip" do
      anns = [
        %ResolvedAnnotation{row: 0, kind: :inline_pill, fg: 0xFFFFFF, bg: 0x6366F1, text: "pill"},
        %ResolvedAnnotation{row: 1, kind: :inline_text, fg: 0x888888, bg: 0x000000, text: "text"},
        %ResolvedAnnotation{row: 2, kind: :gutter_icon, fg: 0xFF0000, bg: 0x00FF00, text: "!"}
      ]

      decoded = round_trip(minimal_window(annotations: anns))

      assert length(decoded.annotations) == 3
      kinds = Enum.map(decoded.annotations, & &1.kind)
      assert kinds == [:inline_pill, :inline_text, :gutter_icon]
    end

    test "unicode annotation text round-trips" do
      ann = %ResolvedAnnotation{
        row: 0,
        kind: :inline_pill,
        fg: 0xFFFFFF,
        bg: 0x000000,
        text: "⚠ 日本語"
      }

      decoded = round_trip(minimal_window(annotations: [ann]))

      assert hd(decoded.annotations).text == "⚠ 日本語"
    end

    test "multiple annotations on same row round-trip" do
      anns = [
        %ResolvedAnnotation{row: 7, kind: :inline_pill, fg: 0xFFFFFF, bg: 0x6366F1, text: "work"},
        %ResolvedAnnotation{
          row: 7,
          kind: :inline_pill,
          fg: 0xFFFFFF,
          bg: 0xDC2626,
          text: "urgent"
        },
        %ResolvedAnnotation{
          row: 7,
          kind: :inline_text,
          fg: 0x888888,
          bg: 0x000000,
          text: "3 tags"
        }
      ]

      decoded = round_trip(minimal_window(annotations: anns))

      assert length(decoded.annotations) == 3
      assert Enum.all?(decoded.annotations, &(&1.row == 7))
    end

    test "empty text annotation round-trips" do
      ann = %ResolvedAnnotation{row: 0, kind: :inline_pill, fg: 0xFFFFFF, bg: 0x000000, text: ""}
      decoded = round_trip(minimal_window(annotations: [ann]))

      assert hd(decoded.annotations).text == ""
    end
  end

  # ── Wire format pinning (Swift compatibility contract) ─────────────────

  describe "wire format pinning" do
    test "header layout: opcode(1) + wid(2) + flags(1) + crow(2) + ccol(2) + shape(1) + count(2)" do
      sw = minimal_window(window_id: 1, cursor_row: 2, cursor_col: 3, cursor_shape: :block)
      binary = GUIWindowContent.encode(sw)

      # flags = 0x03: bit 0 = full_refresh, bit 1 = cursor_visible (both true by default)
      <<0x80, 0x00, 0x01, 0x03, 0x00, 0x02, 0x00, 0x03, 0x00, 0x00, 0x00, _rest::binary>> =
        binary
    end

    test "span layout: start_col(2) + end_col(2) + fg(3) + bg(3) + attrs(1) + fw(1) + fid(1)" do
      span =
        make_span(1, 10, fg: 0xAA_BB_CC, bg: 0x11_22_33, attrs: 0x07, font_weight: 3, font_id: 1)

      row = make_row("x", spans: [span], content_hash: 0)
      binary = GUIWindowContent.encode(minimal_window(rows: [row]))

      # header(13) + row fields(16) = 29
      # header: op(1) wid(2) flags(1) crow(2) ccol(2) shape(1) sleft(2) rows(2)
      <<_header::binary-size(29), 0x00, 0x01, 0x00, 0x0A, 0xAA, 0xBB, 0xCC, 0x11, 0x22, 0x33,
        0x07, 0x03, 0x01, _rest::binary>> = binary
    end

    test "opcode is 0x80" do
      <<opcode::8, _::binary>> = GUIWindowContent.encode(minimal_window([]))
      assert opcode == 0x80
    end
  end

  # ── Property tests ─────────────────────────────────────────────────────

  describe "property: encode/decode round-trip" do
    property "any SemanticWindow encodes to a binary the test decoder can fully consume" do
      check all(sw <- semantic_window_gen()) do
        binary = GUIWindowContent.encode(sw)
        assert is_binary(binary)

        decoded = GUIWindowContentDecoder.decode(binary)
        assert decoded.window_id == sw.window_id
        assert decoded.cursor_row == sw.cursor_row
        assert decoded.cursor_col == sw.cursor_col
        assert decoded.cursor_shape == sw.cursor_shape
        assert decoded.scroll_left == sw.scroll_left
        assert decoded.full_refresh == sw.full_refresh
        assert decoded.cursor_visible == sw.cursor_visible
        assert length(decoded.rows) == length(sw.rows)
      end
    end

    property "row text and buf_line survive round-trip for any input" do
      check all(sw <- semantic_window_gen()) do
        decoded = GUIWindowContentDecoder.decode(GUIWindowContent.encode(sw))

        for {orig, dec} <- Enum.zip(sw.rows, decoded.rows) do
          assert dec.text == orig.text
          assert dec.buf_line == orig.buf_line
          assert dec.row_type == orig.row_type
          assert length(dec.spans) == length(orig.spans)
        end
      end
    end

    property "span colors survive round-trip for any input" do
      check all(sw <- semantic_window_gen()) do
        decoded = GUIWindowContentDecoder.decode(GUIWindowContent.encode(sw))

        for {orig_row, dec_row} <- Enum.zip(sw.rows, decoded.rows) do
          for {orig_span, dec_span} <- Enum.zip(orig_row.spans, dec_row.spans) do
            assert dec_span.fg == orig_span.fg
            assert dec_span.bg == orig_span.bg
            assert dec_span.attrs == orig_span.attrs
          end
        end
      end
    end
  end

  # ── Generators ─────────────────────────────────────────────────────────

  defp semantic_window_gen do
    gen all(
          window_id <- integer(1..0xFFFF),
          row_count <- integer(0..10),
          rows <- list_of(visual_row_gen(), length: row_count),
          cursor_row <- integer(0..100),
          cursor_col <- integer(0..200),
          cursor_shape <- member_of([:block, :beam, :underline]),
          scroll_left <- integer(0..500),
          selection <- one_of([constant(nil), selection_gen()]),
          match_count <- integer(0..5),
          matches <- list_of(search_match_gen(), length: match_count),
          diag_count <- integer(0..5),
          diags <- list_of(diagnostic_range_gen(), length: diag_count),
          ann_count <- integer(0..5),
          anns <- list_of(annotation_gen(), length: ann_count),
          full_refresh <- boolean(),
          cursor_visible <- boolean()
        ) do
      %SemanticWindow{
        window_id: window_id,
        rows: rows,
        cursor_row: cursor_row,
        cursor_col: cursor_col,
        cursor_shape: cursor_shape,
        cursor_visible: cursor_visible,
        scroll_left: scroll_left,
        selection: selection,
        search_matches: matches,
        diagnostic_ranges: diags,
        annotations: anns,
        full_refresh: full_refresh
      }
    end
  end

  defp visual_row_gen do
    gen all(
          row_type <- member_of([:normal, :fold_start, :virtual_line, :block, :wrap_continuation]),
          buf_line <- integer(0..10_000),
          text <- string(:printable, max_length: 100),
          span_count <- integer(0..5),
          spans <- list_of(span_gen(), length: span_count)
        ) do
      %VisualRow{
        row_type: row_type,
        buf_line: buf_line,
        text: text,
        spans: spans,
        content_hash: :erlang.phash2({text, spans})
      }
    end
  end

  defp span_gen do
    gen all(
          start_col <- integer(0..200),
          width <- integer(1..50),
          fg <- integer(0..0xFFFFFF),
          bg <- integer(0..0xFFFFFF),
          attrs <- integer(0..0x1F),
          font_weight <- integer(0..6),
          font_id <- integer(0..10)
        ) do
      %Span{
        start_col: start_col,
        end_col: start_col + width,
        fg: fg,
        bg: bg,
        attrs: attrs,
        font_weight: font_weight,
        font_id: font_id
      }
    end
  end

  defp selection_gen do
    gen all(
          type <- member_of([:char, :line, :block]),
          start_row <- integer(0..100),
          start_col <- integer(0..200),
          end_row <- integer(0..100),
          end_col <- integer(0..200)
        ) do
      %Selection{
        type: type,
        start_row: start_row,
        start_col: start_col,
        end_row: end_row,
        end_col: end_col
      }
    end
  end

  defp search_match_gen do
    gen all(
          row <- integer(0..100),
          start_col <- integer(0..200),
          width <- integer(1..50),
          is_current <- boolean()
        ) do
      %SearchMatch{
        row: row,
        start_col: start_col,
        end_col: start_col + width,
        is_current: is_current
      }
    end
  end

  defp diagnostic_range_gen do
    gen all(
          start_row <- integer(0..100),
          start_col <- integer(0..200),
          end_row <- integer(0..100),
          end_col <- integer(0..200),
          severity <- member_of([:error, :warning, :info, :hint])
        ) do
      %DiagnosticRange{
        start_row: start_row,
        start_col: start_col,
        end_row: end_row,
        end_col: end_col,
        severity: severity
      }
    end
  end

  defp annotation_gen do
    gen all(
          row <- integer(0..100),
          kind <- member_of([:inline_pill, :inline_text, :gutter_icon]),
          fg <- integer(0..0xFFFFFF),
          bg <- integer(0..0xFFFFFF),
          text <- string(:printable, max_length: 50)
        ) do
      %ResolvedAnnotation{row: row, kind: kind, fg: fg, bg: bg, text: text}
    end
  end
end
