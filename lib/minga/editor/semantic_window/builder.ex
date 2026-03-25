defmodule Minga.Editor.SemanticWindow.Builder do
  @moduledoc """
  Builds a `SemanticWindow` from the same data the Content stage uses.

  Called during `build_window_content/2` when the frontend has GUI
  capabilities. Captures the pre-resolved semantic data that the GUI
  needs, without duplicating the draw logic.

  The builder reads from:
  - `WindowScroll` (viewport, lines, cursor, fold map, visible_line_map)
  - `Context.t()` (visual selection, search matches, highlight, decorations)
  - Buffer diagnostics (for inline ranges)

  All positions are converted to display coordinates (relative to the
  window's content rect, with fold/wrap adjustments applied).
  """

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Decorations.BlockDecoration
  alias Minga.Buffer.Decorations.FoldRegion
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Diagnostics
  alias Minga.Editor.DisplayMap
  alias Minga.Editor.FoldMap

  alias Minga.Editor.Renderer.Composition
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.RenderPipeline.Scroll.WindowScroll
  alias Minga.Editor.SemanticWindow
  alias Minga.Editor.SemanticWindow.DiagnosticRange
  alias Minga.Editor.SemanticWindow.DocumentHighlightRange
  alias Minga.Editor.SemanticWindow.ResolvedAnnotation
  alias Minga.Editor.SemanticWindow.SearchMatch
  alias Minga.Editor.SemanticWindow.Selection
  alias Minga.Editor.SemanticWindow.Span
  alias Minga.Editor.SemanticWindow.VisualRow
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Highlight
  alias Minga.LSP.SyncServer

  @type state :: EditorState.t()

  @doc """
  Builds a `SemanticWindow` for one editor window.

  Called from the Content stage with the same `WindowScroll` and
  `Context` that drive the draw-based rendering.
  """
  @spec build(state(), WindowScroll.t(), Context.t()) :: SemanticWindow.t()
  def build(state, scroll, ctx) do
    %WindowScroll{
      win_id: win_id,
      is_active: is_active,
      viewport: viewport,
      cursor_line: cursor_line,
      cursor_col: cursor_col,
      first_line: first_line,
      lines: lines,
      snapshot: snapshot,
      window: window,
      visible_line_map: visible_line_map,
      wrap_on: wrap_on
    } = scroll

    visible_rows = Viewport.content_rows(viewport)

    # Build visual rows from the same data the draw path uses
    visual_rows =
      build_visual_rows(
        lines,
        first_line,
        visible_line_map,
        wrap_on,
        ctx,
        snapshot
      )

    # Cursor in display coordinates
    {display_cursor_row, display_cursor_col} =
      compute_display_cursor(
        cursor_line,
        cursor_col,
        viewport,
        window.fold_map,
        ctx.decorations
      )

    cursor_shape =
      if is_active do
        Minga.Editor.Editing.cursor_shape(state)
      else
        :block
      end

    # Hide the editor cursor when the minibuffer has focus (command, search,
    # eval, search_prompt modes). The native SwiftUI minibuffer shows its
    # own cursor; having two cursors visible is confusing.
    cursor_visible =
      if is_active do
        not Minga.Editor.Editing.minibuffer_mode?(state)
      else
        true
      end

    # Selection in display coordinates
    selection = Selection.from_visual_selection(ctx.visual_selection, viewport.top)

    # Search matches in display coordinates
    viewport_bottom = viewport.top + visible_rows

    search_matches =
      SearchMatch.from_context_matches(
        ctx.search_matches,
        ctx.confirm_match,
        viewport.top,
        viewport_bottom
      )

    # Diagnostic inline ranges in display coordinates
    diagnostic_ranges = build_diagnostic_ranges(window, viewport, visible_rows)

    # Document highlights in display coordinates
    doc_highlights =
      build_document_highlights(
        state.workspace.document_highlights,
        viewport.top,
        viewport_bottom
      )

    # Line annotations in display coordinates
    annotations =
      build_annotations(ctx.decorations, viewport.top, viewport_bottom)

    %SemanticWindow{
      window_id: win_id,
      rows: visual_rows,
      cursor_row: display_cursor_row,
      cursor_col: display_cursor_col,
      cursor_shape: cursor_shape,
      cursor_visible: cursor_visible,
      scroll_left: viewport.left,
      selection: selection,
      search_matches: search_matches,
      diagnostic_ranges: diagnostic_ranges,
      document_highlights: doc_highlights,
      annotations: annotations,
      full_refresh: true
    }
  end

  # ── Visual row building ────────────────────────────────────────────────

  @spec build_visual_rows(
          [String.t()],
          non_neg_integer(),
          [DisplayMap.entry()] | nil,
          boolean(),
          Context.t(),
          map()
        ) :: [VisualRow.t()]
  defp build_visual_rows(lines, first_line, visible_line_map, _wrap_on, ctx, snapshot) do
    if visible_line_map != nil do
      build_visual_rows_folded(lines, first_line, visible_line_map, ctx, snapshot)
    else
      build_visual_rows_sequential(lines, first_line, ctx, snapshot)
    end
  end

  # Sequential path (no folds): one visual row per line
  @spec build_visual_rows_sequential(
          [String.t()],
          non_neg_integer(),
          Context.t(),
          map()
        ) :: [VisualRow.t()]
  defp build_visual_rows_sequential(lines, first_line, ctx, snapshot) do
    first_byte_off = snapshot.first_line_byte_offset

    # Pre-compute highlight segments for all visible lines
    highlight_segments_list =
      if ctx.highlight do
        lines_with_offsets = build_lines_with_offsets(lines, first_byte_off)
        Highlight.styles_for_visible_lines(ctx.highlight, lines_with_offsets)
      else
        List.duplicate(nil, length(lines))
      end

    lines
    |> Enum.zip(highlight_segments_list)
    |> Enum.with_index()
    |> Enum.map(fn {{line_text, hl_segments}, idx} ->
      buf_line = first_line + idx
      {composed_text, spans} = compose_line(line_text, hl_segments, ctx.decorations, buf_line)

      %VisualRow{
        row_type: :normal,
        buf_line: buf_line,
        text: composed_text,
        spans: spans,
        content_hash: VisualRow.compute_hash(composed_text, spans)
      }
    end)
  end

  # Fold-aware path: walks visible_line_map entries
  @spec build_visual_rows_folded(
          [String.t()],
          non_neg_integer(),
          [DisplayMap.entry()],
          Context.t(),
          map()
        ) :: [VisualRow.t()]
  defp build_visual_rows_folded(lines, first_line, visible_line_map, ctx, _snapshot) do
    Enum.map(visible_line_map, fn {buf_line, entry_type} ->
      build_visual_row_entry(buf_line, entry_type, lines, first_line, ctx)
    end)
  end

  @spec build_visual_row_entry(
          non_neg_integer(),
          DisplayMap.entry() | atom(),
          [String.t()],
          non_neg_integer(),
          Context.t()
        ) :: VisualRow.t()
  defp build_visual_row_entry(buf_line, :normal, lines, first_line, ctx) do
    line_text = line_at(lines, buf_line, first_line)
    {composed, spans} = compose_line(line_text, nil, ctx.decorations, buf_line)

    %VisualRow{
      row_type: :normal,
      buf_line: buf_line,
      text: composed,
      spans: spans,
      content_hash: VisualRow.compute_hash(composed, spans)
    }
  end

  defp build_visual_row_entry(buf_line, {:fold_start, hidden_count}, lines, first_line, ctx) do
    line_text = line_at(lines, buf_line, first_line)
    fold_text = line_text <> " ··· #{hidden_count} lines"
    {composed, spans} = compose_line(fold_text, nil, ctx.decorations, buf_line)

    %VisualRow{
      row_type: :fold_start,
      buf_line: buf_line,
      text: composed,
      spans: spans,
      content_hash: VisualRow.compute_hash(composed, spans)
    }
  end

  defp build_visual_row_entry(buf_line, {:virtual_line, vt}, _lines, _first_line, _ctx) do
    text = virtual_text_to_string(vt)

    %VisualRow{
      row_type: :virtual_line,
      buf_line: buf_line,
      text: text,
      spans: virtual_text_spans(vt),
      content_hash: VisualRow.compute_hash(text, [])
    }
  end

  defp build_visual_row_entry(buf_line, {:block, block, line_idx}, _lines, _first_line, _ctx) do
    # Block decorations render via callback; capture the rendered text
    rendered_lines = block.render.(80)
    normalized = BlockDecoration.normalize_render_result(rendered_lines)
    segments = Enum.at(normalized, line_idx, [])
    text = Enum.map_join(segments, fn {t, _style} -> t end)
    spans = segments_to_spans(segments)

    %VisualRow{
      row_type: :block,
      buf_line: buf_line,
      text: text,
      spans: spans,
      content_hash: VisualRow.compute_hash(text, spans)
    }
  end

  defp build_visual_row_entry(buf_line, {:decoration_fold, fold}, _lines, _first_line, _ctx) do
    hidden = FoldRegion.hidden_count(fold)
    text = " ··· #{hidden} lines"

    %VisualRow{
      row_type: :fold_start,
      buf_line: buf_line,
      text: text,
      spans: [],
      content_hash: VisualRow.compute_hash(text, [])
    }
  end

  # ── Line composition ───────────────────────────────────────────────────

  # Composes the final display text and highlight spans for a line.
  #
  # Runs the shared composition pipeline: highlight segments are merged
  # with decorations, conceals are applied, and inline virtual text is
  # spliced in. The resulting segments are then converted to composed
  # text + Span structs.
  #
  # Both the draw path (Line.ex) and the semantic path (this builder)
  # use the same composition functions from Renderer.Composition,
  # guaranteeing identical output for the same input.
  @spec compose_line(
          String.t(),
          [Highlight.styled_segment()] | nil,
          Decorations.t(),
          non_neg_integer()
        ) :: {String.t(), [Span.t()]}
  defp compose_line(line_text, hl_segments, decorations, buf_line) do
    # Start with highlight segments or plain text
    segments =
      case hl_segments do
        nil -> [{line_text, Minga.Face.new()}]
        segs -> segs
      end

    # Merge decoration highlights (search matches, etc.)
    line_highlights = Decorations.highlights_for_line(decorations, buf_line)
    segments = Decorations.merge_highlights(segments, line_highlights, buf_line)

    # Apply conceals and inject inline virtual text (shared pipeline)
    segments = Composition.compose_segments(segments, decorations, buf_line)

    # Convert to composed text + spans
    Composition.segments_to_text_and_spans(segments)
  end

  # ── Cursor display coordinates ─────────────────────────────────────────

  @spec compute_display_cursor(
          non_neg_integer(),
          non_neg_integer(),
          Viewport.t(),
          FoldMap.t(),
          Decorations.t()
        ) :: {non_neg_integer(), non_neg_integer()}
  defp compute_display_cursor(cursor_line, cursor_col, viewport, fold_map, decorations) do
    visible_cursor =
      if FoldMap.empty?(fold_map) do
        cursor_line
      else
        FoldMap.buffer_to_visible(fold_map, cursor_line)
      end

    row = max(visible_cursor - viewport.top, 0)
    col = Decorations.buf_col_to_display_col(decorations, cursor_line, cursor_col)
    {row, col}
  end

  # ── Diagnostics ────────────────────────────────────────────────────────

  @spec build_diagnostic_ranges(
          Minga.Editor.Window.t(),
          Viewport.t(),
          pos_integer()
        ) :: [DiagnosticRange.t()]
  defp build_diagnostic_ranges(window, viewport, visible_rows) do
    buf = window.buffer

    if is_pid(buf) do
      case BufferServer.file_path(buf) do
        nil ->
          []

        path ->
          uri = SyncServer.path_to_uri(path)
          diagnostics = Diagnostics.for_uri(uri)
          viewport_bottom = viewport.top + visible_rows
          DiagnosticRange.from_diagnostics(diagnostics, viewport.top, viewport_bottom)
      end
    else
      []
    end
  catch
    :exit, _ -> []
  end

  # ── Document highlights ─────────────────────────────────────────────────

  @spec build_document_highlights(
          [Minga.LSP.DocumentHighlight.t()] | nil,
          non_neg_integer(),
          non_neg_integer()
        ) :: [DocumentHighlightRange.t()]
  defp build_document_highlights(nil, _top, _bottom), do: []
  defp build_document_highlights([], _top, _bottom), do: []

  defp build_document_highlights(highlights, viewport_top, viewport_bottom) do
    highlights
    |> Enum.filter(fn hl ->
      hl.start_line < viewport_bottom and hl.end_line >= viewport_top
    end)
    |> Enum.map(fn hl ->
      %DocumentHighlightRange{
        start_row: hl.start_line - viewport_top,
        start_col: hl.start_col,
        end_row: hl.end_line - viewport_top,
        end_col: hl.end_col,
        kind: hl.kind
      }
    end)
  end

  # ── Line annotations ──────────────────────────────────────────────────

  @spec build_annotations(Decorations.t(), non_neg_integer(), non_neg_integer()) ::
          [ResolvedAnnotation.t()]
  defp build_annotations(%Decorations{annotations: []}, _top, _bottom), do: []

  defp build_annotations(%Decorations{} = decorations, viewport_top, viewport_bottom) do
    decorations.annotations
    |> Enum.filter(fn ann ->
      ann.line >= viewport_top and ann.line < viewport_bottom
    end)
    |> Enum.sort_by(fn ann -> {ann.line, ann.priority} end)
    |> Enum.map(fn ann ->
      %ResolvedAnnotation{
        row: ann.line - viewport_top,
        kind: ann.kind,
        fg: ann.fg,
        bg: ann.bg,
        text: ann.text
      }
    end)
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  @spec line_at([String.t()], non_neg_integer(), non_neg_integer()) :: String.t()
  defp line_at(lines, buf_line, first_line) do
    idx = buf_line - first_line

    if idx >= 0 and idx < length(lines) do
      Enum.at(lines, idx, "")
    else
      ""
    end
  end

  @spec build_lines_with_offsets([String.t()], non_neg_integer()) ::
          [{String.t(), non_neg_integer()}]
  defp build_lines_with_offsets(lines, first_byte_off) do
    {pairs_rev, _} =
      Enum.reduce(lines, {[], first_byte_off}, fn line, {acc, off} ->
        {[{line, off} | acc], off + byte_size(line) + 1}
      end)

    Enum.reverse(pairs_rev)
  end

  @spec virtual_text_to_string(Decorations.VirtualText.t()) :: String.t()
  defp virtual_text_to_string(%{segments: segments}) do
    Enum.map_join(segments, fn {text, _style} -> text end)
  end

  @spec virtual_text_spans(Decorations.VirtualText.t()) :: [Span.t()]
  defp virtual_text_spans(%{segments: segments}) do
    segments_to_spans(segments)
  end

  @spec segments_to_spans([{String.t(), Minga.Face.t()}]) :: [Span.t()]
  defp segments_to_spans(segments) do
    {spans, _col} =
      Enum.reduce(segments, {[], 0}, fn {text, style}, {acc, col} ->
        width = Unicode.display_width(text)

        if width > 0 do
          span = Span.from_face(style, col, col + width)
          {[span | acc], col + width}
        else
          {acc, col}
        end
      end)

    Enum.reverse(spans)
  end
end
