defmodule Minga.Test.GUIWindowContentDecoder do
  @moduledoc """
  Test-only decoder for the gui_window_content (0x80) wire format.

  Parses an encoded binary back into a map so tests can do round-trip
  assertions without fragile byte-offset pattern matching. The decoder
  must consume the entire binary (ending with `<<>>`) to catch encoder
  bugs that emit extra or missing bytes.
  """

  import Bitwise

  @doc "Decodes an 0x80 binary back into a map for test assertions."
  @spec decode(binary()) :: map()
  def decode(<<0x80, section_count::8, rest::binary>>) do
    result = %{
      window_id: 0,
      full_refresh: true,
      cursor_visible: true,
      cursor_row: 0,
      cursor_col: 0,
      cursor_shape: :block,
      scroll_left: 0,
      rows: [],
      selection: nil,
      search_matches: [],
      diagnostic_ranges: [],
      document_highlights: [],
      annotations: []
    }

    {result, <<>>} = decode_sections(rest, section_count, result)
    result
  end

  defp decode_sections(rest, 0, result), do: {result, rest}

  defp decode_sections(
         <<section_id::8, section_len::16, payload::binary-size(section_len), rest::binary>>,
         remaining,
         result
       ) do
    result = decode_section(section_id, payload, result)
    decode_sections(rest, remaining - 1, result)
  end

  defp decode_section(0x01, payload, result) do
    <<window_id::16, flags::8, cursor_row::16, cursor_col::16, cursor_shape::8, scroll_left::16>> =
      payload

    %{
      result
      | window_id: window_id,
        full_refresh: (flags &&& 1) == 1,
        cursor_visible: (flags &&& 2) == 2,
        cursor_row: cursor_row,
        cursor_col: cursor_col,
        cursor_shape: decode_cursor_shape(cursor_shape),
        scroll_left: scroll_left
    }
  end

  defp decode_section(0x02, <<row_count::16, rest::binary>>, result) do
    {rows, <<>>} = decode_rows(rest, row_count, [])
    %{result | rows: rows}
  end

  defp decode_section(0x03, payload, result) do
    {selection, <<>>} = decode_selection(payload)
    %{result | selection: selection}
  end

  defp decode_section(0x04, payload, result) do
    {search_matches, <<>>} = decode_search_matches(payload)
    %{result | search_matches: search_matches}
  end

  defp decode_section(0x05, payload, result) do
    {diagnostic_ranges, <<>>} = decode_diagnostic_ranges(payload)
    %{result | diagnostic_ranges: diagnostic_ranges}
  end

  defp decode_section(0x06, payload, result) do
    {document_highlights, <<>>} = decode_document_highlights(payload)
    %{result | document_highlights: document_highlights}
  end

  defp decode_section(0x07, payload, result) do
    {annotations, <<>>} = decode_annotations(payload)
    %{result | annotations: annotations}
  end

  defp decode_section(_unknown, _payload, result), do: result

  # ── Rows ─────────────────────────────────────────────────────────────────

  defp decode_rows(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_rows(
         <<row_type::8, buf_line::32, content_hash::32, text_len::32, text::binary-size(text_len),
           span_count::16, rest::binary>>,
         remaining,
         acc
       ) do
    {spans, rest} = decode_spans(rest, span_count, [])

    row = %{
      row_type: decode_row_type(row_type),
      buf_line: buf_line,
      content_hash: content_hash,
      text: text,
      spans: spans
    }

    decode_rows(rest, remaining - 1, [row | acc])
  end

  defp decode_row_type(0), do: :normal
  defp decode_row_type(1), do: :fold_start
  defp decode_row_type(2), do: :virtual_line
  defp decode_row_type(3), do: :block
  defp decode_row_type(4), do: :wrap_continuation

  # ── Spans ────────────────────────────────────────────────────────────────

  defp decode_spans(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_spans(
         <<start_col::16, end_col::16, fg_r::8, fg_g::8, fg_b::8, bg_r::8, bg_g::8, bg_b::8,
           attrs::8, font_weight::8, font_id::8, rest::binary>>,
         remaining,
         acc
       ) do
    span = %{
      start_col: start_col,
      end_col: end_col,
      fg: fg_r <<< 16 ||| fg_g <<< 8 ||| fg_b,
      bg: bg_r <<< 16 ||| bg_g <<< 8 ||| bg_b,
      attrs: attrs,
      font_weight: font_weight,
      font_id: font_id
    }

    decode_spans(rest, remaining - 1, [span | acc])
  end

  # ── Selection ────────────────────────────────────────────────────────────

  defp decode_selection(<<0::8, rest::binary>>), do: {nil, rest}

  defp decode_selection(
         <<type::8, start_row::16, start_col::16, end_row::16, end_col::16, rest::binary>>
       ) do
    sel = %{
      type: decode_selection_type(type),
      start_row: start_row,
      start_col: start_col,
      end_row: end_row,
      end_col: end_col
    }

    {sel, rest}
  end

  defp decode_selection_type(1), do: :char
  defp decode_selection_type(2), do: :line
  defp decode_selection_type(3), do: :block

  # ── Search matches ──────────────────────────────────────────────────────

  defp decode_search_matches(<<count::16, rest::binary>>) do
    decode_search_match_entries(rest, count, [])
  end

  defp decode_search_match_entries(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_search_match_entries(
         <<row::16, start_col::16, end_col::16, is_current::8, rest::binary>>,
         remaining,
         acc
       ) do
    match = %{
      row: row,
      start_col: start_col,
      end_col: end_col,
      is_current: is_current == 1
    }

    decode_search_match_entries(rest, remaining - 1, [match | acc])
  end

  # ── Diagnostic ranges ──────────────────────────────────────────────────

  defp decode_diagnostic_ranges(<<count::16, rest::binary>>) do
    decode_diag_entries(rest, count, [])
  end

  defp decode_diag_entries(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_diag_entries(
         <<start_row::16, start_col::16, end_row::16, end_col::16, severity::8, rest::binary>>,
         remaining,
         acc
       ) do
    diag = %{
      start_row: start_row,
      start_col: start_col,
      end_row: end_row,
      end_col: end_col,
      severity: decode_severity(severity)
    }

    decode_diag_entries(rest, remaining - 1, [diag | acc])
  end

  defp decode_severity(0), do: :error
  defp decode_severity(1), do: :warning
  defp decode_severity(2), do: :info
  defp decode_severity(3), do: :hint

  # ── Document highlights ─────────────────────────────────────────────────

  defp decode_document_highlights(<<count::16, rest::binary>>) do
    decode_highlight_entries(rest, count, [])
  end

  defp decode_highlight_entries(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_highlight_entries(
         <<start_row::16, start_col::16, end_row::16, end_col::16, kind::8, rest::binary>>,
         remaining,
         acc
       ) do
    highlight = %{
      start_row: start_row,
      start_col: start_col,
      end_row: end_row,
      end_col: end_col,
      kind: decode_highlight_kind(kind)
    }

    decode_highlight_entries(rest, remaining - 1, [highlight | acc])
  end

  defp decode_highlight_kind(1), do: :text
  defp decode_highlight_kind(2), do: :read
  defp decode_highlight_kind(3), do: :write

  # ── Line annotations ─────────────────────────────────────────────────────

  defp decode_annotations(<<count::16, rest::binary>>) do
    decode_annotation_entries(rest, count, [])
  end

  defp decode_annotation_entries(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_annotation_entries(
         <<row::16, kind::8, fg_r::8, fg_g::8, fg_b::8, bg_r::8, bg_g::8, bg_b::8, text_len::16,
           text::binary-size(text_len), rest::binary>>,
         remaining,
         acc
       ) do
    annotation = %{
      row: row,
      kind: decode_annotation_kind(kind),
      fg: fg_r <<< 16 ||| fg_g <<< 8 ||| fg_b,
      bg: bg_r <<< 16 ||| bg_g <<< 8 ||| bg_b,
      text: text
    }

    decode_annotation_entries(rest, remaining - 1, [annotation | acc])
  end

  defp decode_annotation_kind(0), do: :inline_pill
  defp decode_annotation_kind(1), do: :inline_text
  defp decode_annotation_kind(2), do: :gutter_icon

  # ── Cursor shape ────────────────────────────────────────────────────────

  defp decode_cursor_shape(0), do: :block
  defp decode_cursor_shape(1), do: :beam
  defp decode_cursor_shape(2), do: :underline
end
