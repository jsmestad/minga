defmodule Minga.Frontend.Adapter.GUI.WindowEncoder do
  @moduledoc """
  Binary protocol encoder for the `gui_window_content` opcode (0x80).

  Encodes a `RenderWindow` struct into the wire format for GUI frontends.
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
    row_id:             u64      (stable retained-render identity)
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

  annotation_count:     u16
  per annotation:
    row:                u16      (display row)
    kind:               u8       (0=inline_pill, 1=inline_text, 2=gutter_icon)
    fg:                 u24
    bg:                 u24
    text_len:           u16
    text:               [text_len] UTF-8
  ```
  """

  import Bitwise

  alias Minga.RenderModel.Window, as: RenderWindow
  alias Minga.RenderModel.Window.Annotation
  alias Minga.RenderModel.Window.Cursorline
  alias Minga.RenderModel.Window.DiagnosticRange
  alias Minga.RenderModel.Window.DocumentHighlight
  alias Minga.RenderModel.Window.Gutter
  alias Minga.RenderModel.Window.GutterEntry
  alias Minga.RenderModel.Window.HitRegion
  alias Minga.RenderModel.Window.IndentGuides
  alias Minga.RenderModel.Window.PaneGeometry
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.SearchMatch
  alias Minga.RenderModel.Window.Selection
  alias Minga.RenderModel.Window.Span

  alias Minga.Protocol.Opcodes

  @op_gui_window_content Opcodes.gui_window_content()
  @op_gui_window_overlay_delta Opcodes.gui_window_overlay_delta()
  @op_gui_gutter Opcodes.gui_gutter()
  @op_gui_indent_guides Opcodes.gui_indent_guides()

  # Sectioned format section IDs
  @section_wc_header 0x01
  @section_wc_rows 0x02
  @section_wc_selection 0x03
  @section_wc_search 0x04
  @section_wc_diagnostics 0x05
  @section_wc_highlights 0x06
  @section_wc_annotations 0x07
  @section_wc_geometry 0x08
  @section_wc_cursorline 0x09

  @section_gutter_window 0x01
  @section_gutter_config 0x02
  @section_gutter_entries 0x03
  @no_fold_range 0xFFFF_FFFF

  @typedoc "Per-section byte metrics for encoded window content."
  @type metrics :: %{
          row_bytes: non_neg_integer(),
          overlay_bytes: non_neg_integer(),
          gutter_bytes: non_neg_integer(),
          annotation_bytes: non_neg_integer(),
          metadata_bytes: non_neg_integer()
        }

  @doc """
  Encodes a `RenderWindow` into the 0x80 wire format (sectioned).

  Returns a single binary suitable for sending via `MingaEditor.Frontend.send_commands/2`.
  """
  @spec encode(RenderWindow.t()) :: [binary()]
  def encode(%RenderWindow{} = window) do
    [encode_window_content(window)] ++ encode_frame_metadata(window)
  end

  @doc "Encodes a cursor and cursorline overlay delta for a retained GUI window."
  @spec encode_overlay_delta(RenderWindow.t()) :: binary()
  def encode_overlay_delta(%RenderWindow{} = window) do
    cursorline = encode_cursorline_section(window.cursorline, window.rect)

    flags =
      if(Map.get(window, :cursor_visible, true), do: 0x01, else: 0x00) |||
        if(cursorline != nil, do: 0x02, else: 0x00)

    cursor_shape = encode_cursor_shape(window.cursor_shape)

    header =
      <<window.window_id::16, window.content_epoch::32, flags::8, window.cursor_row::16,
        window.cursor_col::16, cursor_shape::8>>

    IO.iodata_to_binary([<<@op_gui_window_overlay_delta>>, header, cursorline || []])
  end

  @doc "Encodes per-frame window metadata that the GUI clears and rebuilds every batch."
  @spec encode_frame_metadata(RenderWindow.t()) :: [binary()]
  def encode_frame_metadata(%RenderWindow{} = window) do
    {commands, _metrics} = encode_frame_metadata_with_metrics(window)
    commands
  end

  @doc "Encodes per-frame window metadata with byte metrics."
  @spec encode_frame_metadata_with_metrics(RenderWindow.t()) :: {[binary()], metrics()}
  def encode_frame_metadata_with_metrics(%RenderWindow{} = window) do
    gutter = encode_gutter(window.gutter)
    metadata = encode_cursorline(window.cursorline) ++ encode_indent_guides(window.indent_guides)

    {gutter ++ metadata,
     empty_metrics()
     |> Map.put(:gutter_bytes, IO.iodata_length(gutter))
     |> Map.put(:metadata_bytes, IO.iodata_length(metadata))}
  end

  @spec encode_window_content(RenderWindow.t()) :: binary()
  def encode_window_content(%RenderWindow{} = sw) do
    {binary, _metrics} = encode_window_content_with_metrics(sw)
    binary
  end

  @doc "Encodes window content with per-section byte metrics."
  @spec encode_window_content_with_metrics(RenderWindow.t()) :: {binary(), metrics()}
  def encode_window_content_with_metrics(%RenderWindow{} = sw) do
    # Flags byte: bit 0 = full_refresh, bit 1 = cursor_visible
    flags =
      if(sw.full_refresh, do: 1, else: 0) |||
        if Map.get(sw, :cursor_visible, true), do: 0x02, else: 0

    cursor_shape = encode_cursor_shape(sw.cursor_shape)
    row_count = length(sw.rows)

    header_payload =
      <<sw.window_id::16, flags::8, sw.cursor_row::16, sw.cursor_col::16, cursor_shape::8,
        sw.scroll_left::16, sw.content_epoch::32>>

    rows_payload = IO.iodata_to_binary([<<row_count::16>> | encode_rows(sw.rows)])
    selection_payload = IO.iodata_to_binary(encode_selection(sw.selection))
    matches_payload = IO.iodata_to_binary(encode_search_matches(sw.search_matches))
    diag_payload = IO.iodata_to_binary(encode_diagnostic_ranges(sw.diagnostic_ranges))
    highlight_payload = IO.iodata_to_binary(encode_document_highlights(sw.document_highlights))
    annotation_payload = IO.iodata_to_binary(encode_annotations(sw.annotations))
    geometry_payload = encode_geometry(sw.geometry)
    cursorline_payload = encode_cursorline_section(sw.cursorline, sw.rect)

    header_section = encode_section(@section_wc_header, header_payload)
    rows_section = encode_section(@section_wc_rows, rows_payload)
    selection_section = encode_section(@section_wc_selection, selection_payload)
    search_section = encode_section(@section_wc_search, matches_payload)
    diagnostic_section = encode_section(@section_wc_diagnostics, diag_payload)
    highlight_section = encode_section(@section_wc_highlights, highlight_payload)
    annotation_section = encode_section(@section_wc_annotations, annotation_payload)
    geometry_sections = geometry_sections(geometry_payload)
    cursorline_sections = cursorline_sections(cursorline_payload)

    sections =
      [
        header_section,
        rows_section,
        selection_section,
        search_section,
        diagnostic_section,
        highlight_section,
        annotation_section
      ] ++ geometry_sections ++ cursorline_sections

    binary = IO.iodata_to_binary([<<@op_gui_window_content, length(sections)::8>> | sections])

    metrics = %{
      row_bytes: byte_size(rows_section),
      overlay_bytes:
        byte_size(selection_section) + byte_size(search_section) + byte_size(diagnostic_section) +
          byte_size(highlight_section),
      gutter_bytes: 0,
      annotation_bytes: byte_size(annotation_section),
      metadata_bytes:
        2 + byte_size(header_section) + IO.iodata_length(geometry_sections) +
          IO.iodata_length(cursorline_sections)
    }

    {binary, metrics}
  end

  @spec empty_metrics() :: metrics()
  defp empty_metrics do
    %{row_bytes: 0, overlay_bytes: 0, gutter_bytes: 0, annotation_bytes: 0, metadata_bytes: 0}
  end

  @spec encode_section(non_neg_integer(), binary()) :: binary()
  defp encode_section(section_id, payload) do
    <<section_id::8, byte_size(payload)::16, payload::binary>>
  end

  @spec geometry_sections(binary() | nil) :: [binary()]
  defp geometry_sections(nil), do: []
  defp geometry_sections(payload), do: [encode_section(@section_wc_geometry, payload)]

  @spec cursorline_sections(binary() | nil) :: [binary()]
  defp cursorline_sections(nil), do: []
  defp cursorline_sections(payload), do: [encode_section(@section_wc_cursorline, payload)]

  @spec encode_geometry(PaneGeometry.t() | nil) :: binary() | nil
  defp encode_geometry(nil), do: nil

  defp encode_geometry(%PaneGeometry{} = geometry) do
    hit_regions = encode_hit_regions(geometry.hit_regions)

    IO.iodata_to_binary([
      <<geometry.window_id::16>>,
      encode_rect(geometry.total_rect),
      encode_rect(geometry.content_rect),
      encode_rect(geometry.text_rect),
      encode_rect(geometry.gutter_rect),
      encode_rect(geometry.clip_rect),
      <<geometry.viewport.top::32, geometry.viewport.left::16, geometry.viewport.rows::16,
        geometry.viewport.cols::16, geometry.viewport.total_lines::32,
        geometry.viewport.visual_row_offset::16, geometry.viewport.total_visual_rows::32,
        geometry.gutter_metrics.line_number_width::16, geometry.gutter_metrics.sign_col_width::16,
        length(geometry.hit_regions)::8>>,
      hit_regions
    ])
  end

  @spec encode_rect(PaneGeometry.rect()) :: binary()
  defp encode_rect({row, col, width, height}) do
    <<row::16, col::16, width::16, height::16>>
  end

  @spec encode_hit_regions([HitRegion.t()]) :: iodata()
  defp encode_hit_regions(hit_regions) do
    Enum.map(hit_regions, fn %HitRegion{} = region ->
      [<<encode_hit_kind(region.kind)::8>>, encode_rect(region.rect), <<region.window_id::16>>]
    end)
  end

  @spec encode_hit_kind(HitRegion.kind()) :: non_neg_integer()
  defp encode_hit_kind(:text), do: 1
  defp encode_hit_kind(:gutter), do: 2
  defp encode_hit_kind(:fold_control), do: 3
  defp encode_hit_kind(:modeline), do: 4
  defp encode_hit_kind(:divider), do: 5
  defp encode_hit_kind(:status_bar), do: 6

  @doc """
  Returns the opcode constant for gui_window_content.
  """
  @spec opcode() :: non_neg_integer()
  def opcode, do: @op_gui_window_content

  # ── Rows ─────────────────────────────────────────────────────────────────

  @spec encode_rows([Row.t()]) :: iodata()
  defp encode_rows(rows) do
    Enum.map(rows, &encode_row/1)
  end

  @spec encode_row(Row.t()) :: binary()
  defp encode_row(%Row{} = row) do
    row_type = encode_row_type(row.row_type)
    text_bytes = row.text
    text_len = byte_size(text_bytes)
    span_count = length(row.spans)

    spans_binary = Enum.map(row.spans, &encode_span/1)

    IO.iodata_to_binary([
      <<row_type::8, row.row_id::64, row.buf_line::32, row.content_hash::32, text_len::32,
        text_bytes::binary, span_count::16>>
      | spans_binary
    ])
  end

  @spec encode_row_type(Row.row_type()) :: non_neg_integer()
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

  @spec encode_document_highlights([DocumentHighlight.t()]) :: binary()
  defp encode_document_highlights(highlights) do
    count = length(highlights)
    entries = Enum.map(highlights, &encode_document_highlight/1)
    IO.iodata_to_binary([<<count::16>> | entries])
  end

  @spec encode_document_highlight(DocumentHighlight.t()) :: binary()
  defp encode_document_highlight(%DocumentHighlight{} = h) do
    kind = encode_highlight_kind(h.kind)

    <<h.start_row::16, h.start_col::16, h.end_row::16, h.end_col::16, kind::8>>
  end

  @spec encode_highlight_kind(DocumentHighlight.kind()) :: non_neg_integer()
  defp encode_highlight_kind(:text), do: 1
  defp encode_highlight_kind(:read), do: 2
  defp encode_highlight_kind(:write), do: 3

  # ── Line annotations ─────────────────────────────────────────────────────

  @spec encode_annotations([Annotation.t()]) :: binary()
  defp encode_annotations(annotations) do
    count = length(annotations)
    entries = Enum.map(annotations, &encode_annotation/1)
    IO.iodata_to_binary([<<count::16>> | entries])
  end

  @spec encode_annotation(Annotation.t()) :: binary()
  defp encode_annotation(%Annotation{} = ann) do
    kind = encode_annotation_kind(ann.kind)
    fg_r = ann.fg >>> 16 &&& 0xFF
    fg_g = ann.fg >>> 8 &&& 0xFF
    fg_b = ann.fg &&& 0xFF
    bg_r = ann.bg >>> 16 &&& 0xFF
    bg_g = ann.bg >>> 8 &&& 0xFF
    bg_b = ann.bg &&& 0xFF
    text_bytes = ann.text
    text_len = byte_size(text_bytes)

    <<ann.row::16, kind::8, fg_r::8, fg_g::8, fg_b::8, bg_r::8, bg_g::8, bg_b::8, text_len::16,
      text_bytes::binary>>
  end

  @spec encode_annotation_kind(Minga.Core.Decorations.LineAnnotation.kind()) ::
          non_neg_integer()
  defp encode_annotation_kind(:inline_pill), do: 0
  defp encode_annotation_kind(:inline_text), do: 1
  defp encode_annotation_kind(:gutter_icon), do: 2

  # ── Gutter ──────────────────────────────────────────────────────────────

  @spec encode_gutter(Gutter.t() | nil) :: [binary()]
  defp encode_gutter(nil), do: []
  defp encode_gutter(%Gutter{} = gutter), do: [encode_gutter_binary(gutter)]

  @spec encode_gutter_binary(Gutter.t()) :: binary()
  defp encode_gutter_binary(%Gutter{} = gutter) do
    entries_payload =
      IO.iodata_to_binary([
        <<length(gutter.entries)::16>> | Enum.map(gutter.entries, &encode_gutter_entry/1)
      ])

    active_byte = if gutter.is_active, do: 1, else: 0

    sections = [
      encode_section(
        @section_gutter_window,
        <<gutter.window_id::16, gutter.content_row::16, gutter.content_col::16,
          gutter.content_height::16, active_byte::8, gutter.content_width::16>>
      ),
      encode_section(
        @section_gutter_config,
        <<gutter.cursor_line::32, encode_line_number_style(gutter.line_number_style)::8,
          gutter.line_number_width::8, gutter.sign_col_width::8>>
      ),
      encode_section(@section_gutter_entries, entries_payload)
    ]

    IO.iodata_to_binary([<<@op_gui_gutter, length(sections)::8>> | sections])
  end

  @spec encode_gutter_entry(GutterEntry.t()) :: binary()
  defp encode_gutter_entry(%GutterEntry{} = entry) do
    fold_end_line = entry.fold_end_line || @no_fold_range

    base =
      <<entry.buf_line::32, encode_display_type(entry.display_type)::8,
        encode_sign_type(entry.sign_type)::8, fold_end_line::32>>

    case entry.sign_type do
      :annotation ->
        fg = entry.sign_fg || 0
        text = entry.sign_text || ""
        <<base::binary, red(fg)::8, green(fg)::8, blue(fg)::8, byte_size(text)::8, text::binary>>

      _ ->
        base
    end
  end

  @spec encode_line_number_style(Gutter.line_number_style()) :: non_neg_integer()
  defp encode_line_number_style(:hybrid), do: 0
  defp encode_line_number_style(:absolute), do: 1
  defp encode_line_number_style(:relative), do: 2
  defp encode_line_number_style(:none), do: 3

  @spec encode_display_type(GutterEntry.display_type()) :: non_neg_integer()
  defp encode_display_type(:normal), do: 0
  defp encode_display_type(:fold_start), do: 1
  defp encode_display_type(:fold_continuation), do: 2
  defp encode_display_type(:wrap_continuation), do: 3
  defp encode_display_type(:fold_open), do: 4
  defp encode_display_type(:blank), do: 5

  @spec encode_sign_type(GutterEntry.sign_type()) :: non_neg_integer()
  defp encode_sign_type(:none), do: 0
  defp encode_sign_type(:git_added), do: 1
  defp encode_sign_type(:git_modified), do: 2
  defp encode_sign_type(:git_deleted), do: 3
  defp encode_sign_type(:diag_error), do: 4
  defp encode_sign_type(:diag_warning), do: 5
  defp encode_sign_type(:diag_info), do: 6
  defp encode_sign_type(:diag_hint), do: 7
  defp encode_sign_type(:annotation), do: 8
  defp encode_sign_type(:git_removed), do: 9

  # ── Cursorline ─────────────────────────────────────────────────────────

  @spec encode_cursorline(Cursorline.t() | nil) :: [binary()]
  defp encode_cursorline(_cursorline), do: []

  @spec encode_cursorline_section(Cursorline.t() | nil, RenderWindow.rect()) :: binary() | nil
  defp encode_cursorline_section(nil, _rect), do: nil
  defp encode_cursorline_section(%Cursorline{bg_rgb: 0}, _rect), do: nil
  defp encode_cursorline_section(%Cursorline{row: 0xFFFF}, _rect), do: nil

  defp encode_cursorline_section(
         %Cursorline{row: row, bg_rgb: bg_rgb},
         {rect_row, _col, _width, height}
       ) do
    local_row = row |> Kernel.-(rect_row) |> max(0) |> min(max(height - 1, 0))
    <<local_row::16, red(bg_rgb)::8, green(bg_rgb)::8, blue(bg_rgb)::8>>
  end

  # ── Indent guides ──────────────────────────────────────────────────────

  @spec encode_indent_guides(IndentGuides.t() | nil) :: [binary()]
  defp encode_indent_guides(nil), do: []

  defp encode_indent_guides(%IndentGuides{guide_cols: []} = guides) do
    [
      <<@op_gui_indent_guides, 6::16, guides.window_id::16, guides.tab_width::8, 0xFFFF::16,
        0::8>>
    ]
  end

  defp encode_indent_guides(%IndentGuides{} = guides) do
    guide_count = length(guides.guide_cols)
    guide_bytes = for col <- guides.guide_cols, into: <<>>, do: <<col::16>>
    line_count = length(guides.line_indent_levels)
    level_bytes = for level <- guides.line_indent_levels, into: <<>>, do: <<min(level, 255)::8>>
    payload_len = 6 + 2 * guide_count + 2 + line_count

    [
      <<@op_gui_indent_guides, payload_len::16, guides.window_id::16, guides.tab_width::8,
        guides.active_guide_col::16, guide_count::8, guide_bytes::binary, line_count::16,
        level_bytes::binary>>
    ]
  end

  # ── Color helpers ──────────────────────────────────────────────────────

  @spec red(non_neg_integer()) :: non_neg_integer()
  defp red(rgb), do: rgb >>> 16 &&& 0xFF

  @spec green(non_neg_integer()) :: non_neg_integer()
  defp green(rgb), do: rgb >>> 8 &&& 0xFF

  @spec blue(non_neg_integer()) :: non_neg_integer()
  defp blue(rgb), do: rgb &&& 0xFF

  # ── Cursor shape ────────────────────────────────────────────────────────

  @spec encode_cursor_shape(RenderWindow.cursor_shape()) :: non_neg_integer()
  defp encode_cursor_shape(:block), do: 0
  defp encode_cursor_shape(:beam), do: 1
  defp encode_cursor_shape(:underline), do: 2
end
