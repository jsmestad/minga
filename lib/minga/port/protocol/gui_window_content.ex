defmodule Minga.Port.Protocol.GUIWindowContent do
  @moduledoc """
  Binary protocol encoder for the `gui_window_content` opcode (0x80).

  Encodes a `SemanticWindow` struct into the wire format for GUI frontends.
  This replaces draw_text commands for buffer windows, sending pre-resolved
  semantic data that Swift renders directly via CoreText.

  ## Wire Format

  ```
  opcode:               u8 = 0x80
  window_id:            u16
  flags:                u8       (bit 0 = full_refresh, bit 1 = cursor_visible)
  cursor_row:           u16      (display row, fold/wrap adjusted)
  cursor_col:           u16      (display col, virtual text adjusted)
  cursor_shape:         u8
  scroll_left:          u16      (horizontal scroll offset in display cols)
  visible_row_count:    u16

  per visible row:
    row_type:           u8       (0=normal, 1=fold_start, 2=virtual_line,
                                  3=block, 4=wrap_continuation)
    buf_line:           u32
    content_hash:       u32      (for CTLine cache invalidation)
    text_len:           u32
    text:               [text_len]  UTF-8
    span_count:         u16
    per span:
      start_col:        u16
      end_col:          u16
      fg:               u24
      bg:               u24
      attrs:            u8
      font_weight:      u8
      font_id:          u8

  selection_type:       u8       0=none, 1=char, 2=line, 3=block
  if != 0: start_row(u16), start_col(u16), end_row(u16), end_col(u16)

  match_count:          u16
  per match: row(u16), start_col(u16), end_col(u16), is_current(u8)

  diag_range_count:     u16
  per range: start_row(u16), start_col(u16), end_row(u16), end_col(u16),
             severity(u8)

  highlight_count:      u16
  per highlight: start_row(u16), start_col(u16), end_row(u16), end_col(u16),
                 kind(u8)
  Kind: 1=text, 2=read, 3=write
  ```
  """

  import Bitwise

  alias Minga.Editor.SemanticWindow
  alias Minga.Editor.SemanticWindow.DiagnosticRange
  alias Minga.Editor.SemanticWindow.DocumentHighlightRange
  alias Minga.Editor.SemanticWindow.SearchMatch
  alias Minga.Editor.SemanticWindow.Selection
  alias Minga.Editor.SemanticWindow.Span
  alias Minga.Editor.SemanticWindow.VisualRow

  @op_gui_window_content 0x80

  @doc """
  Encodes a `SemanticWindow` into the 0x80 wire format.

  Returns a single binary suitable for sending via `PortManager.send_commands/2`.
  """
  @spec encode(SemanticWindow.t()) :: binary()
  def encode(%SemanticWindow{} = sw) do
    # Flags byte: bit 0 = full_refresh, bit 1 = cursor_visible
    flags =
      if(sw.full_refresh, do: 1, else: 0) |||
        if Map.get(sw, :cursor_visible, true), do: 0x02, else: 0

    cursor_shape = encode_cursor_shape(sw.cursor_shape)
    row_count = length(sw.rows)

    header =
      <<@op_gui_window_content, sw.window_id::16, flags::8, sw.cursor_row::16, sw.cursor_col::16,
        cursor_shape::8, sw.scroll_left::16, row_count::16>>

    rows_binary = encode_rows(sw.rows)
    selection_binary = encode_selection(sw.selection)
    matches_binary = encode_search_matches(sw.search_matches)
    diag_binary = encode_diagnostic_ranges(sw.diagnostic_ranges)
    highlight_binary = encode_document_highlights(sw.document_highlights)

    IO.iodata_to_binary([
      header,
      rows_binary,
      selection_binary,
      matches_binary,
      diag_binary,
      highlight_binary
    ])
  end

  @doc """
  Returns the opcode constant for gui_window_content.
  """
  @spec opcode() :: non_neg_integer()
  def opcode, do: @op_gui_window_content

  # ── Rows ─────────────────────────────────────────────────────────────────

  @spec encode_rows([VisualRow.t()]) :: iodata()
  defp encode_rows(rows) do
    Enum.map(rows, &encode_row/1)
  end

  @spec encode_row(VisualRow.t()) :: binary()
  defp encode_row(%VisualRow{} = row) do
    row_type = encode_row_type(row.row_type)
    text_bytes = row.text
    text_len = byte_size(text_bytes)
    span_count = length(row.spans)

    spans_binary = Enum.map(row.spans, &encode_span/1)

    IO.iodata_to_binary([
      <<row_type::8, row.buf_line::32, row.content_hash::32, text_len::32, text_bytes::binary,
        span_count::16>>
      | spans_binary
    ])
  end

  @spec encode_row_type(VisualRow.row_type()) :: non_neg_integer()
  defp encode_row_type(:normal), do: 0
  defp encode_row_type(:fold_start), do: 1
  defp encode_row_type(:virtual_line), do: 2
  defp encode_row_type(:block), do: 3
  defp encode_row_type(:wrap_continuation), do: 4

  # ── Spans ────────────────────────────────────────────────────────────────

  @spec encode_span(Span.t()) :: binary()
  defp encode_span(%Span{} = span) do
    fg_r = span.fg >>> 16 &&& 0xFF
    fg_g = span.fg >>> 8 &&& 0xFF
    fg_b = span.fg &&& 0xFF
    bg_r = span.bg >>> 16 &&& 0xFF
    bg_g = span.bg >>> 8 &&& 0xFF
    bg_b = span.bg &&& 0xFF

    <<span.start_col::16, span.end_col::16, fg_r::8, fg_g::8, fg_b::8, bg_r::8, bg_g::8, bg_b::8,
      span.attrs::8, span.font_weight::8, span.font_id::8>>
  end

  # ── Selection ────────────────────────────────────────────────────────────

  @spec encode_selection(Selection.t() | nil) :: binary()
  defp encode_selection(nil), do: <<0::8>>

  defp encode_selection(%Selection{} = sel) do
    type_byte = encode_selection_type(sel.type)

    <<type_byte::8, sel.start_row::16, sel.start_col::16, sel.end_row::16, sel.end_col::16>>
  end

  @spec encode_selection_type(Selection.selection_type()) :: non_neg_integer()
  defp encode_selection_type(:char), do: 1
  defp encode_selection_type(:line), do: 2
  defp encode_selection_type(:block), do: 3

  # ── Search matches ──────────────────────────────────────────────────────

  @spec encode_search_matches([SearchMatch.t()]) :: binary()
  defp encode_search_matches(matches) do
    count = length(matches)
    entries = Enum.map(matches, &encode_search_match/1)
    IO.iodata_to_binary([<<count::16>> | entries])
  end

  @spec encode_search_match(SearchMatch.t()) :: binary()
  defp encode_search_match(%SearchMatch{} = m) do
    is_current = if m.is_current, do: 1, else: 0
    <<m.row::16, m.start_col::16, m.end_col::16, is_current::8>>
  end

  # ── Diagnostic ranges ──────────────────────────────────────────────────

  @spec encode_diagnostic_ranges([DiagnosticRange.t()]) :: binary()
  defp encode_diagnostic_ranges(ranges) do
    count = length(ranges)
    entries = Enum.map(ranges, &encode_diagnostic_range/1)
    IO.iodata_to_binary([<<count::16>> | entries])
  end

  @spec encode_diagnostic_range(DiagnosticRange.t()) :: binary()
  defp encode_diagnostic_range(%DiagnosticRange{} = d) do
    severity = encode_severity(d.severity)

    <<d.start_row::16, d.start_col::16, d.end_row::16, d.end_col::16, severity::8>>
  end

  @spec encode_severity(atom()) :: non_neg_integer()
  defp encode_severity(:error), do: 0
  defp encode_severity(:warning), do: 1
  defp encode_severity(:info), do: 2
  defp encode_severity(:hint), do: 3

  # ── Document highlights ─────────────────────────────────────────────────

  @spec encode_document_highlights([DocumentHighlightRange.t()]) :: binary()
  defp encode_document_highlights(highlights) do
    count = length(highlights)
    entries = Enum.map(highlights, &encode_document_highlight/1)
    IO.iodata_to_binary([<<count::16>> | entries])
  end

  @spec encode_document_highlight(DocumentHighlightRange.t()) :: binary()
  defp encode_document_highlight(%DocumentHighlightRange{} = h) do
    kind = encode_highlight_kind(h.kind)

    <<h.start_row::16, h.start_col::16, h.end_row::16, h.end_col::16, kind::8>>
  end

  @spec encode_highlight_kind(DocumentHighlightRange.kind()) :: non_neg_integer()
  defp encode_highlight_kind(:text), do: 1
  defp encode_highlight_kind(:read), do: 2
  defp encode_highlight_kind(:write), do: 3

  # ── Cursor shape ────────────────────────────────────────────────────────

  @spec encode_cursor_shape(SemanticWindow.cursor_shape()) :: non_neg_integer()
  defp encode_cursor_shape(:block), do: 0
  defp encode_cursor_shape(:beam), do: 1
  defp encode_cursor_shape(:underline), do: 2
end
