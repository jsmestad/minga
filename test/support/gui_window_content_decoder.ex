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
  def decode(
        <<0x80, window_id::16, flags::8, cursor_row::16, cursor_col::16, cursor_shape::8,
          scroll_left::16, row_count::16, rest::binary>>
      ) do
    {rows, rest} = decode_rows(rest, row_count, [])
    {selection, rest} = decode_selection(rest)
    {search_matches, rest} = decode_search_matches(rest)
    {diagnostic_ranges, rest} = decode_diagnostic_ranges(rest)
    {document_highlights, <<>>} = decode_document_highlights(rest)

    %{
      window_id: window_id,
      full_refresh: (flags &&& 1) == 1,
      cursor_row: cursor_row,
      cursor_col: cursor_col,
      cursor_shape: decode_cursor_shape(cursor_shape),
      scroll_left: scroll_left,
      rows: rows,
      selection: selection,
      search_matches: search_matches,
      diagnostic_ranges: diagnostic_ranges,
      document_highlights: document_highlights
    }
  end

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

  # ── Cursor shape ────────────────────────────────────────────────────────

  defp decode_cursor_shape(0), do: :block
  defp decode_cursor_shape(1), do: :beam
  defp decode_cursor_shape(2), do: :underline
end
