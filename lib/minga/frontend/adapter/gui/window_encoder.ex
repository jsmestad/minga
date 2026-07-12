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
  visible_row_count:    u32

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
  alias Minga.RenderModel.Window.RowDelta
  alias Minga.RenderModel.Window.RowSplice
  alias Minga.RenderModel.Window.ScrollPresentation
  alias Minga.RenderModel.Window.SearchMatch
  alias Minga.RenderModel.Window.Selection
  alias Minga.RenderModel.Window.Span
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.Opcodes

  @op_gui_window_content Opcodes.gui_window_content()
  @op_gui_window_overlay_delta Opcodes.gui_window_overlay_delta()
  @op_gui_window_viewport_delta Opcodes.gui_window_viewport_delta()
  @op_gui_window_rows_delta Opcodes.gui_window_rows_delta()
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
  @section_wc_scroll_presentation 0x0A
  @section_wc_row_splices 0x0B

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
  Encodes a `RenderWindow` into the 0x80 wire format (len32 sectioned).

  Returns a single binary suitable for sending via `MingaEditor.Frontend.send_commands/2`.
  """
  @spec encode(RenderWindow.t()) :: [binary()]
  def encode(%RenderWindow{} = window) do
    [encode_window_content(window)] ++ encode_frame_metadata(window)
  end

  @doc "Encodes a cursor and cursorline overlay delta for a retained GUI window."
  @spec encode_overlay_delta(RenderWindow.t()) :: binary()
  def encode_overlay_delta(%RenderWindow{} = window) do
    command = :gui_window_overlay_delta
    cursorline = encode_cursorline_section(window.cursorline, window.rect, command)

    flags =
      if(Map.get(window, :cursor_visible, true), do: 0x01, else: 0x00) |||
        if(cursorline != nil, do: 0x02, else: 0x00)

    command
    |> Writer.new()
    |> Writer.append(<<@op_gui_window_overlay_delta>>)
    |> Writer.uint16(:window_id, window.window_id)
    |> Writer.uint32(:content_epoch, window.content_epoch)
    |> Writer.uint8(:flags, flags)
    |> Writer.uint16(:cursor_row, window.cursor_row)
    |> Writer.uint16(:cursor_col, window.cursor_col)
    |> Writer.uint8(:cursor_shape, encode_cursor_shape(window.cursor_shape))
    |> Writer.append(cursorline || [])
    |> Writer.finish()
  end

  @doc "Encodes a retained viewport delta with ordered ref-or-full row entries."
  @spec encode_viewport_delta(RenderWindow.t(), %{non_neg_integer() => non_neg_integer()}) ::
          {binary(), boolean()}
  def encode_viewport_delta(%RenderWindow{} = window, previous_hashes)
      when is_map(previous_hashes) do
    encode_rows_snapshot_delta(@op_gui_window_viewport_delta, window, previous_hashes)
  end

  @doc "Encodes a validated A2 row-splice plan using retained refs where hashes match."
  @spec encode_rows_delta(
          RenderWindow.t(),
          RowDelta.t(),
          %{non_neg_integer() => non_neg_integer()}
        ) :: {binary(), boolean()}
  def encode_rows_delta(%RenderWindow{} = window, %RowDelta{} = delta, previous_hashes)
      when is_map(previous_hashes) do
    :ok = validate_row_delta!(delta)
    encode_row_splices_delta(window, delta, previous_hashes)
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
    command = :gui_window_content
    # Flags byte: bit 0 = full_refresh, bit 1 = cursor_visible
    flags =
      if(sw.full_refresh, do: 1, else: 0) |||
        if Map.get(sw, :cursor_visible, true), do: 0x02, else: 0

    header_payload =
      command
      |> Writer.new()
      |> Writer.uint16(:window_id, sw.window_id)
      |> Writer.uint8(:flags, flags)
      |> Writer.uint16(:cursor_row, sw.cursor_row)
      |> Writer.uint16(:cursor_col, sw.cursor_col)
      |> Writer.uint8(:cursor_shape, encode_cursor_shape(sw.cursor_shape))
      |> Writer.uint16(:scroll_left, sw.scroll_left)
      |> Writer.uint32(:content_epoch, sw.content_epoch)
      |> Writer.finish()

    rows_payload =
      command
      |> Writer.new()
      |> Writer.uint32(:row_count, Enum.count(sw.rows))
      |> Writer.append(encode_rows(sw.rows, command))
      |> Writer.finish()

    header_section = encode_section(command, @section_wc_header, header_payload)
    rows_section = encode_section(command, @section_wc_rows, rows_payload)
    overlay = overlay_sections(sw, command)

    sections =
      [header_section, rows_section | overlay.sections] ++
        overlay.geometry ++ overlay.cursorline ++ overlay.scroll_presentation

    sections_payload =
      command
      |> Writer.new()
      |> Writer.uint8(:section_count, Enum.count(sections))
      |> Writer.append(sections)
      |> Writer.finish()

    binary =
      command
      |> Writer.new()
      |> Writer.append(<<@op_gui_window_content>>)
      |> Writer.payload32(:payload, sections_payload)
      |> Writer.finish()

    metrics = %{
      row_bytes: byte_size(rows_section),
      overlay_bytes:
        byte_size(overlay.selection) + byte_size(overlay.search) +
          byte_size(overlay.diagnostics) + byte_size(overlay.highlights),
      gutter_bytes: 0,
      annotation_bytes: byte_size(overlay.annotations),
      metadata_bytes:
        6 + byte_size(header_section) + IO.iodata_length(overlay.geometry) +
          IO.iodata_length(overlay.cursorline) + IO.iodata_length(overlay.scroll_presentation)
    }

    {binary, metrics}
  end

  @spec encode_rows_snapshot_delta(non_neg_integer(), RenderWindow.t(), map()) ::
          {binary(), boolean()}
  defp encode_rows_snapshot_delta(opcode, %RenderWindow{} = sw, previous_hashes) do
    command = delta_command(opcode)
    {row_entries, has_refs?} = encode_delta_row_entries(sw.rows, previous_hashes, command)

    rows_payload =
      command
      |> Writer.new()
      |> Writer.uint32(:row_count, Enum.count(sw.rows))
      |> Writer.append(row_entries)
      |> Writer.finish()

    sections = delta_sections(sw, @section_wc_rows, rows_payload, command)

    binary =
      command
      |> Writer.new()
      |> Writer.append(<<opcode>>)
      |> Writer.uint8(:section_count, Enum.count(sections))
      |> Writer.append(sections)
      |> Writer.finish()

    {binary, has_refs?}
  end

  @spec encode_row_splices_delta(RenderWindow.t(), RowDelta.t(), map()) ::
          {binary(), boolean()}
  defp encode_row_splices_delta(%RenderWindow{} = sw, %RowDelta{} = delta, previous_hashes) do
    command = :gui_window_rows_delta

    {splice_entries, has_refs?} =
      Enum.map_reduce(delta.splices, false, fn %RowSplice{} = splice, has_refs? ->
        {insert_entries, splice_has_refs?} =
          encode_delta_row_entries(splice.insert_rows, previous_hashes, command)

        encoded =
          command
          |> Writer.new()
          |> Writer.uint32(:start_index, splice.start_index)
          |> Writer.uint32(:delete_count, splice.delete_count)
          |> Writer.uint32(:insert_count, RowSplice.insert_count(splice))
          |> Writer.append(insert_entries)
          |> Writer.finish()

        {[encoded], has_refs? or splice_has_refs?}
      end)

    splices_payload =
      command
      |> Writer.new()
      |> Writer.uint32(:base_row_count, delta.base_row_count)
      |> Writer.uint32(:result_row_count, delta.result_row_count)
      |> Writer.uint32(:splice_count, length(delta.splices))
      |> Writer.append(splice_entries)
      |> Writer.finish()

    sections = delta_sections(sw, @section_wc_row_splices, splices_payload, command)

    binary =
      command
      |> Writer.new()
      |> Writer.append(<<@op_gui_window_rows_delta>>)
      |> Writer.uint8(:section_count, length(sections))
      |> Writer.append(sections)
      |> Writer.finish()

    {binary, has_refs?}
  end

  @spec validate_row_delta!(RowDelta.t()) :: :ok
  defp validate_row_delta!(%RowDelta{} = delta) do
    case RowDelta.validate(delta) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "invalid row splice plan: #{reason}"
    end
  end

  @spec delta_sections(RenderWindow.t(), non_neg_integer(), binary(), atom()) :: [binary()]
  defp delta_sections(%RenderWindow{} = sw, row_section_id, rows_payload, command) do
    flags = if Map.get(sw, :cursor_visible, true), do: 0x01, else: 0x00

    header_payload =
      command
      |> Writer.new()
      |> Writer.uint16(:window_id, sw.window_id)
      |> Writer.uint32(:content_epoch, sw.content_epoch)
      |> Writer.uint8(:flags, flags)
      |> Writer.uint16(:cursor_row, sw.cursor_row)
      |> Writer.uint16(:cursor_col, sw.cursor_col)
      |> Writer.uint8(:cursor_shape, encode_cursor_shape(sw.cursor_shape))
      |> Writer.uint16(:scroll_left, sw.scroll_left)
      |> Writer.finish()

    header_section = encode_section(command, @section_wc_header, header_payload)
    rows_section = encode_section(command, row_section_id, rows_payload)
    overlay = overlay_sections(sw, command)

    [header_section, rows_section | overlay.sections] ++
      overlay.geometry ++ overlay.cursorline ++ overlay.scroll_presentation
  end

  @spec encode_delta_row_entries([Row.t()], map(), atom()) :: {iodata(), boolean()}
  defp encode_delta_row_entries(rows, previous_hashes, command) do
    Enum.map_reduce(rows, false, fn %Row{} = row, has_refs? ->
      if Map.get(previous_hashes, row.row_id) == row.content_hash do
        entry =
          command
          |> Writer.new()
          |> Writer.uint8(:row_entry_type, 0)
          |> Writer.uint64(:row_id, row.row_id)
          |> Writer.uint32(:content_hash, row.content_hash)
          |> Writer.finish()

        {[entry], true}
      else
        {[<<1>>, encode_row(row, command)], has_refs?}
      end
    end)
  end

  defp overlay_sections(%RenderWindow{} = sw, command) do
    section_encoder = fn section_id, payload -> encode_section(command, section_id, payload) end
    selection = section_encoder.(@section_wc_selection, encode_selection(sw.selection, command))

    search =
      section_encoder.(@section_wc_search, encode_search_matches(sw.search_matches, command))

    diagnostics =
      section_encoder.(
        @section_wc_diagnostics,
        encode_diagnostic_ranges(sw.diagnostic_ranges, command)
      )

    highlights =
      section_encoder.(
        @section_wc_highlights,
        encode_document_highlights(sw.document_highlights, command)
      )

    annotations =
      section_encoder.(@section_wc_annotations, encode_annotations(sw.annotations, command))

    geometry = geometry_sections(encode_geometry(sw.geometry, command), section_encoder)

    cursorline =
      cursorline_sections(
        encode_cursorline_section(sw.cursorline, sw.rect, command),
        section_encoder
      )

    scroll_presentation =
      scroll_presentation_sections(
        encode_scroll_presentation(ScrollPresentation.from_window(sw), command),
        section_encoder
      )

    %{
      sections: [selection, search, diagnostics, highlights, annotations],
      selection: selection,
      search: search,
      diagnostics: diagnostics,
      highlights: highlights,
      annotations: annotations,
      geometry: geometry,
      cursorline: cursorline,
      scroll_presentation: scroll_presentation
    }
  end

  @spec empty_metrics() :: metrics()
  defp empty_metrics do
    %{row_bytes: 0, overlay_bytes: 0, gutter_bytes: 0, annotation_bytes: 0, metadata_bytes: 0}
  end

  @spec encode_section(atom(), non_neg_integer(), binary()) :: binary()
  defp encode_section(command, section_id, payload) do
    command
    |> Writer.new()
    |> Writer.uint8(:section_id, section_id)
    |> Writer.payload32(:section_payload, payload)
    |> Writer.finish()
  end

  @spec geometry_sections(binary() | nil, function()) :: [binary()]
  defp geometry_sections(nil, _section_encoder), do: []

  defp geometry_sections(payload, section_encoder),
    do: [section_encoder.(@section_wc_geometry, payload)]

  @spec cursorline_sections(binary() | nil, function()) :: [binary()]
  defp cursorline_sections(nil, _section_encoder), do: []

  defp cursorline_sections(payload, section_encoder),
    do: [section_encoder.(@section_wc_cursorline, payload)]

  @spec scroll_presentation_sections(binary() | nil, function()) :: [binary()]
  defp scroll_presentation_sections(nil, _section_encoder), do: []

  defp scroll_presentation_sections(payload, section_encoder),
    do: [section_encoder.(@section_wc_scroll_presentation, payload)]

  @spec encode_geometry(PaneGeometry.t() | nil, atom()) :: binary() | nil
  defp encode_geometry(nil, _command), do: nil

  defp encode_geometry(%PaneGeometry{} = geometry, command) do
    command
    |> Writer.new()
    |> Writer.uint16(:geometry_window_id, geometry.window_id)
    |> Writer.append(encode_rect(geometry.total_rect, command))
    |> Writer.append(encode_rect(geometry.content_rect, command))
    |> Writer.append(encode_rect(geometry.text_rect, command))
    |> Writer.append(encode_rect(geometry.gutter_rect, command))
    |> Writer.append(encode_rect(geometry.clip_rect, command))
    |> Writer.uint32(:viewport_top, geometry.viewport.top)
    |> Writer.uint16(:viewport_left, geometry.viewport.left)
    |> Writer.uint16(:viewport_rows, geometry.viewport.rows)
    |> Writer.uint16(:viewport_cols, geometry.viewport.cols)
    |> Writer.uint32(:viewport_total_lines, geometry.viewport.total_lines)
    |> Writer.uint16(:viewport_visual_row_offset, geometry.viewport.visual_row_offset)
    |> Writer.uint32(:viewport_total_visual_rows, geometry.viewport.total_visual_rows)
    |> Writer.uint16(:gutter_line_number_width, geometry.gutter_metrics.line_number_width)
    |> Writer.uint16(:gutter_sign_col_width, geometry.gutter_metrics.sign_col_width)
    |> Writer.uint8(:hit_region_count, Enum.count(geometry.hit_regions))
    |> Writer.append(encode_hit_regions(geometry.hit_regions, command))
    |> Writer.finish()
  end

  @spec encode_scroll_presentation(ScrollPresentation.t() | nil, atom()) :: binary() | nil
  defp encode_scroll_presentation(nil, _command), do: nil

  defp encode_scroll_presentation(%ScrollPresentation{} = presentation, command) do
    flags = if presentation.reset_required, do: 0x01, else: 0x00

    command
    |> Writer.new()
    |> Writer.uint16(:scroll_window_id, presentation.window_id)
    |> Writer.uint8(:scroll_flags, flags)
    |> Writer.uint32(:anchor_top, presentation.anchor_top)
    |> Writer.uint16(:anchor_left, presentation.anchor_left)
    |> Writer.uint16(:anchor_visual_row_offset, presentation.anchor_visual_row_offset)
    |> Writer.uint32(:visible_start_line, presentation.visible_start_line)
    |> Writer.uint32(:visible_end_line, presentation.visible_end_line)
    |> Writer.uint32(:overscan_start_line, presentation.overscan_start_line)
    |> Writer.uint32(:overscan_end_line, presentation.overscan_end_line)
    |> Writer.uint32(:scroll_content_epoch, presentation.content_epoch)
    |> Writer.uint32(:layout_generation, presentation.layout_generation)
    |> Writer.uint32(:scroll_seq, presentation.scroll_seq)
    |> Writer.finish()
  end

  @spec encode_rect(PaneGeometry.rect(), atom()) :: binary()
  defp encode_rect({row, col, width, height}, command) do
    command
    |> Writer.new()
    |> Writer.uint16(:rect_row, row)
    |> Writer.uint16(:rect_col, col)
    |> Writer.uint16(:rect_width, width)
    |> Writer.uint16(:rect_height, height)
    |> Writer.finish()
  end

  @spec encode_hit_regions([HitRegion.t()], atom()) :: iodata()
  defp encode_hit_regions(hit_regions, command) do
    Enum.map(hit_regions, fn %HitRegion{} = region ->
      command
      |> Writer.new()
      |> Writer.uint8(:hit_region_kind, encode_hit_kind(region.kind))
      |> Writer.append(encode_rect(region.rect, command))
      |> Writer.uint16(:hit_region_window_id, region.window_id)
      |> Writer.finish()
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

  @spec encode_rows([Row.t()], atom()) :: iodata()
  defp encode_rows(rows, command), do: Enum.map(rows, &encode_row(&1, command))

  @spec encode_row(Row.t(), atom()) :: binary()
  defp encode_row(%Row{} = row, command) do
    command
    |> Writer.new()
    |> Writer.uint8(:row_type, encode_row_type(row.row_type))
    |> Writer.uint64(:row_id, row.row_id)
    |> Writer.uint32(:buf_line, row.buf_line)
    |> Writer.uint32(:content_hash, row.content_hash)
    |> Writer.string32(:row_text, row.text)
    |> Writer.uint16(:span_count, Enum.count(row.spans))
    |> Writer.append(Enum.map(row.spans, &encode_span(&1, command)))
    |> Writer.finish()
  end

  @spec encode_row_type(Row.row_type()) :: non_neg_integer()
  defp encode_row_type(:normal), do: 0
  defp encode_row_type(:fold_start), do: 1
  defp encode_row_type(:virtual_line), do: 2
  defp encode_row_type(:block), do: 3
  defp encode_row_type(:wrap_continuation), do: 4

  # ── Spans ────────────────────────────────────────────────────────────────

  @spec encode_span(Span.t(), atom()) :: binary()
  defp encode_span(%Span{} = span, command) do
    command
    |> Writer.new()
    |> Writer.uint16(:span_start_col, span.start_col)
    |> Writer.uint16(:span_end_col, span.end_col)
    |> Writer.rgb24(:span_fg, span.fg)
    |> Writer.rgb24(:span_bg, span.bg)
    |> Writer.uint8(:span_attrs, span.attrs)
    |> Writer.uint8(:span_font_weight, span.font_weight)
    |> Writer.uint8(:span_font_id, span.font_id)
    |> Writer.finish()
  end

  # ── Selection ────────────────────────────────────────────────────────────

  @spec encode_selection(Selection.t() | nil, atom()) :: binary()
  defp encode_selection(nil, _command), do: <<0>>

  defp encode_selection(%Selection{} = sel, command) do
    command
    |> Writer.new()
    |> Writer.uint8(:selection_type, encode_selection_type(sel.type))
    |> Writer.uint16(:selection_start_row, sel.start_row)
    |> Writer.uint16(:selection_start_col, sel.start_col)
    |> Writer.uint16(:selection_end_row, sel.end_row)
    |> Writer.uint16(:selection_end_col, sel.end_col)
    |> Writer.finish()
  end

  @spec encode_selection_type(Selection.selection_type()) :: non_neg_integer()
  defp encode_selection_type(:char), do: 1
  defp encode_selection_type(:line), do: 2
  defp encode_selection_type(:block), do: 3

  # ── Search matches ──────────────────────────────────────────────────────

  @spec encode_search_matches([SearchMatch.t()], atom()) :: binary()
  defp encode_search_matches(matches, command) do
    command
    |> Writer.new()
    |> Writer.uint16(:search_match_count, Enum.count(matches))
    |> Writer.append(Enum.map(matches, &encode_search_match(&1, command)))
    |> Writer.finish()
  end

  @spec encode_search_match(SearchMatch.t(), atom()) :: binary()
  defp encode_search_match(%SearchMatch{} = match, command) do
    command
    |> Writer.new()
    |> Writer.uint16(:search_match_row, match.row)
    |> Writer.uint16(:search_match_start_col, match.start_col)
    |> Writer.uint16(:search_match_end_col, match.end_col)
    |> Writer.uint8(:search_match_current, if(match.is_current, do: 1, else: 0))
    |> Writer.finish()
  end

  # ── Diagnostic ranges ──────────────────────────────────────────────────

  @spec encode_diagnostic_ranges([DiagnosticRange.t()], atom()) :: binary()
  defp encode_diagnostic_ranges(ranges, command) do
    command
    |> Writer.new()
    |> Writer.uint16(:diagnostic_range_count, Enum.count(ranges))
    |> Writer.append(Enum.map(ranges, &encode_diagnostic_range(&1, command)))
    |> Writer.finish()
  end

  @spec encode_diagnostic_range(DiagnosticRange.t(), atom()) :: binary()
  defp encode_diagnostic_range(%DiagnosticRange{} = diagnostic, command) do
    command
    |> Writer.new()
    |> Writer.uint16(:diagnostic_start_row, diagnostic.start_row)
    |> Writer.uint16(:diagnostic_start_col, diagnostic.start_col)
    |> Writer.uint16(:diagnostic_end_row, diagnostic.end_row)
    |> Writer.uint16(:diagnostic_end_col, diagnostic.end_col)
    |> Writer.uint8(:diagnostic_severity, encode_severity(diagnostic.severity))
    |> Writer.finish()
  end

  @spec encode_severity(atom()) :: non_neg_integer()
  defp encode_severity(:error), do: 0
  defp encode_severity(:warning), do: 1
  defp encode_severity(:info), do: 2
  defp encode_severity(:hint), do: 3

  # ── Document highlights ─────────────────────────────────────────────────

  @spec encode_document_highlights([DocumentHighlight.t()], atom()) :: binary()
  defp encode_document_highlights(highlights, command) do
    command
    |> Writer.new()
    |> Writer.uint16(:document_highlight_count, Enum.count(highlights))
    |> Writer.append(Enum.map(highlights, &encode_document_highlight(&1, command)))
    |> Writer.finish()
  end

  @spec encode_document_highlight(DocumentHighlight.t(), atom()) :: binary()
  defp encode_document_highlight(%DocumentHighlight{} = highlight, command) do
    command
    |> Writer.new()
    |> Writer.uint16(:highlight_start_row, highlight.start_row)
    |> Writer.uint16(:highlight_start_col, highlight.start_col)
    |> Writer.uint16(:highlight_end_row, highlight.end_row)
    |> Writer.uint16(:highlight_end_col, highlight.end_col)
    |> Writer.uint8(:highlight_kind, encode_highlight_kind(highlight.kind))
    |> Writer.finish()
  end

  @spec encode_highlight_kind(DocumentHighlight.kind()) :: non_neg_integer()
  defp encode_highlight_kind(:text), do: 1
  defp encode_highlight_kind(:read), do: 2
  defp encode_highlight_kind(:write), do: 3

  # ── Line annotations ─────────────────────────────────────────────────────

  @spec encode_annotations([Annotation.t()], atom()) :: binary()
  defp encode_annotations(annotations, command) do
    command
    |> Writer.new()
    |> Writer.uint16(:annotation_count, Enum.count(annotations))
    |> Writer.append(Enum.map(annotations, &encode_annotation(&1, command)))
    |> Writer.finish()
  end

  @spec encode_annotation(Annotation.t(), atom()) :: binary()
  defp encode_annotation(%Annotation{} = annotation, command) do
    command
    |> Writer.new()
    |> Writer.uint16(:annotation_row, annotation.row)
    |> Writer.uint8(:annotation_kind, encode_annotation_kind(annotation.kind))
    |> Writer.rgb24(:annotation_fg, annotation.fg)
    |> Writer.rgb24(:annotation_bg, annotation.bg)
    |> Writer.string16(:annotation_text, annotation.text)
    |> Writer.finish()
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
    command = :gui_gutter

    entries_payload =
      command
      |> Writer.new()
      |> Writer.uint16(:entry_count, Enum.count(gutter.entries))
      |> Writer.append(Enum.map(gutter.entries, &encode_gutter_entry/1))
      |> Writer.finish()

    window_payload =
      command
      |> Writer.new()
      |> Writer.uint16(:window_id, gutter.window_id)
      |> Writer.uint16(:content_row, gutter.content_row)
      |> Writer.uint16(:content_col, gutter.content_col)
      |> Writer.uint16(:content_height, gutter.content_height)
      |> Writer.uint8(:is_active, if(gutter.is_active, do: 1, else: 0))
      |> Writer.uint16(:content_width, gutter.content_width)
      |> Writer.finish()

    config_payload =
      command
      |> Writer.new()
      |> Writer.uint32(:cursor_line, gutter.cursor_line)
      |> Writer.uint8(:line_number_style, encode_line_number_style(gutter.line_number_style))
      |> Writer.uint8(:line_number_width, gutter.line_number_width)
      |> Writer.uint8(:sign_col_width, gutter.sign_col_width)
      |> Writer.finish()

    sections = [
      encode_gutter_section(@section_gutter_window, window_payload),
      encode_gutter_section(@section_gutter_config, config_payload),
      encode_gutter_section(@section_gutter_entries, entries_payload)
    ]

    command
    |> Writer.new()
    |> Writer.append(<<@op_gui_gutter>>)
    |> Writer.uint8(:section_count, Enum.count(sections))
    |> Writer.append(sections)
    |> Writer.finish()
  end

  @spec encode_gutter_section(non_neg_integer(), binary()) :: binary()
  defp encode_gutter_section(section_id, payload) do
    :gui_gutter
    |> Writer.new()
    |> Writer.uint8(:section_id, section_id)
    |> Writer.payload16(:section_payload, payload)
    |> Writer.finish()
  end

  @spec encode_gutter_entry(GutterEntry.t()) :: binary()
  defp encode_gutter_entry(%GutterEntry{} = entry) do
    writer =
      :gui_gutter
      |> Writer.new()
      |> Writer.uint32(:buf_line, entry.buf_line)
      |> Writer.uint8(:display_type, encode_display_type(entry.display_type))
      |> Writer.uint8(:sign_type, encode_sign_type(entry.sign_type))
      |> Writer.uint32(:fold_end_line, entry.fold_end_line || @no_fold_range)

    encode_gutter_annotation(writer, entry)
  end

  @spec encode_gutter_annotation(Writer.t(), GutterEntry.t()) :: binary()
  defp encode_gutter_annotation(writer, %GutterEntry{sign_type: :annotation} = entry) do
    writer
    |> Writer.rgb24(:annotation_fg, entry.sign_fg || 0)
    |> Writer.string8(:annotation_text, entry.sign_text || "")
    |> Writer.finish()
  end

  defp encode_gutter_annotation(writer, %GutterEntry{}), do: Writer.finish(writer)

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
  defp encode_sign_type(:diag_advisory), do: 10

  # ── Cursorline ─────────────────────────────────────────────────────────

  @spec encode_cursorline(Cursorline.t() | nil) :: [binary()]
  defp encode_cursorline(_cursorline), do: []

  @spec encode_cursorline_section(Cursorline.t() | nil, RenderWindow.rect(), atom()) ::
          binary() | nil
  defp encode_cursorline_section(nil, _rect, _command), do: nil
  defp encode_cursorline_section(%Cursorline{bg_rgb: 0}, _rect, _command), do: nil
  defp encode_cursorline_section(%Cursorline{row: 0xFFFF}, _rect, _command), do: nil

  defp encode_cursorline_section(
         %Cursorline{row: row, bg_rgb: bg_rgb},
         {rect_row, _col, _width, height},
         command
       ) do
    # Cursorline rows are window-relative on the wire, so geometry clipping is intentional.
    local_row = clip_cursorline_row(row - rect_row, height)

    command
    |> Writer.new()
    |> Writer.uint16(:cursorline_row, local_row)
    |> Writer.rgb24(:cursorline_bg, bg_rgb)
    |> Writer.finish()
  end

  @spec clip_cursorline_row(integer(), integer()) :: non_neg_integer()
  defp clip_cursorline_row(_local_row, height) when height <= 0, do: 0
  defp clip_cursorline_row(local_row, _height) when local_row < 0, do: 0
  defp clip_cursorline_row(local_row, height) when local_row >= height, do: height - 1
  defp clip_cursorline_row(local_row, _height), do: local_row

  # ── Indent guides ──────────────────────────────────────────────────────

  @spec encode_indent_guides(IndentGuides.t() | nil) :: [binary()]
  defp encode_indent_guides(nil), do: []

  defp encode_indent_guides(%IndentGuides{guide_cols: []} = guides) do
    command = :gui_indent_guides

    payload =
      command
      |> Writer.new()
      |> Writer.uint16(:window_id, guides.window_id)
      |> Writer.uint8(:tab_width, guides.tab_width)
      |> Writer.uint16(:active_guide_col, guides.active_guide_col)
      |> Writer.uint8(:guide_count, 0)
      |> Writer.finish()

    [
      command
      |> Writer.new()
      |> Writer.append(<<@op_gui_indent_guides>>)
      |> Writer.payload16(:payload, payload)
      |> Writer.finish()
    ]
  end

  defp encode_indent_guides(%IndentGuides{} = guides) do
    command = :gui_indent_guides

    payload =
      command
      |> Writer.new()
      |> Writer.uint16(:window_id, guides.window_id)
      |> Writer.uint8(:tab_width, guides.tab_width)
      |> Writer.uint16(:active_guide_col, guides.active_guide_col)
      |> Writer.uint8(:guide_count, Enum.count(guides.guide_cols))
      |> Writer.append(encode_guide_cols(guides.guide_cols))
      |> Writer.uint16(:line_count, Enum.count(guides.line_indent_levels))
      |> Writer.append(encode_indent_levels(guides.line_indent_levels))
      |> Writer.finish()

    encoded =
      command
      |> Writer.new()
      |> Writer.append(<<@op_gui_indent_guides>>)
      |> Writer.payload16(:payload, payload)
      |> Writer.finish()

    [encoded]
  end

  @spec encode_guide_cols([non_neg_integer()]) :: binary()
  defp encode_guide_cols(cols) do
    Enum.reduce(cols, Writer.new(:gui_indent_guides), fn col, writer ->
      Writer.uint16(writer, :guide_col, col)
    end)
    |> Writer.finish()
  end

  @spec encode_indent_levels([non_neg_integer()]) :: binary()
  defp encode_indent_levels(levels) do
    Enum.reduce(levels, Writer.new(:gui_indent_guides), fn level, writer ->
      Writer.uint8(writer, :indent_level, level)
    end)
    |> Writer.finish()
  end

  # ── Cursor shape ────────────────────────────────────────────────────────

  @spec encode_cursor_shape(RenderWindow.cursor_shape()) :: non_neg_integer()
  defp encode_cursor_shape(:block), do: 0
  defp encode_cursor_shape(:beam), do: 1
  defp encode_cursor_shape(:underline), do: 2

  @spec delta_command(non_neg_integer()) :: atom()
  defp delta_command(@op_gui_window_viewport_delta), do: :gui_window_viewport_delta
end
