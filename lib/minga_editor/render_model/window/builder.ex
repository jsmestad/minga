defmodule MingaEditor.RenderModel.Window.Builder do
  @moduledoc """
  Builds a `RenderWindow` from the same data the Content stage uses.

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

  alias Minga.Config
  alias Minga.Core.Decorations
  alias Minga.Core.Decorations.BlockDecoration
  alias Minga.Core.Decorations.FoldRegion
  alias Minga.Core.Decorations.HighlightRange
  alias Minga.Core.HlTodo
  alias Minga.Core.IndentGuide
  alias Minga.Core.Unicode
  alias Minga.Core.WrapMap
  alias Minga.Diagnostics
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline.Scroll.WindowScroll
  alias MingaEditor.Renderer.Composition
  alias MingaEditor.Renderer.Context
  alias Minga.RenderModel.Window, as: RenderWindow
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
  alias Minga.RenderModel.Window.Viewport, as: RenderViewport
  alias MingaEditor.Renderer.Gutter, as: EditorGutter
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport
  alias MingaEditor.WindowTree
  alias Minga.LSP.SyncServer
  alias MingaEditor.UI.Highlight

  @type state :: EditorState.t() | MingaEditor.RenderPipeline.Input.t()
  @typep visual_row_entry :: %{
           row: Row.t(),
           buf_line: non_neg_integer(),
           visual_index: non_neg_integer(),
           display_row: non_neg_integer(),
           source_text: String.t(),
           source_start_byte: non_neg_integer(),
           source_end_byte: non_neg_integer(),
           source_start_col: non_neg_integer(),
           source_end_col: non_neg_integer(),
           indent_width: non_neg_integer(),
           row_width: non_neg_integer()
         }

  @doc """
  Builds a `RenderWindow` for one editor window.

  Called from the Content stage with the same `WindowScroll` and
  `Context` that drive the draw-based rendering.
  """
  @spec build(state(), WindowScroll.t(), Context.t(), keyword()) :: RenderWindow.t()
  def build(state, scroll, ctx, opts \\ []) do
    %WindowScroll{
      win_id: win_id,
      is_active: is_active,
      viewport: viewport,
      cursor_line: cursor_line,
      cursor_byte_col: _cursor_byte_col,
      cursor_col: cursor_col,
      first_line: first_line,
      lines: lines,
      snapshot: snapshot,
      window: window,
      win_layout: win_layout,
      visible_line_map: visible_line_map,
      wrap_on: wrap_on
    } = scroll

    visible_row_count = Viewport.content_rows(viewport)
    content_kind = Keyword.get(opts, :content_kind, :buffer)
    rect = win_layout.content
    {content_row, _content_col, _content_width, _content_height} = rect

    # Build visual rows from the same data the draw path uses.
    visual_entries =
      lines
      |> build_visual_entries(first_line, visible_line_map, wrap_on, ctx, snapshot)
      |> trim_visual_entries(viewport.visual_row_offset, visible_row_count)

    visual_rows = Enum.map(visual_entries, & &1.row)
    wrapped_coordinates? = wrap_on and visible_line_map == nil

    # Cursor in display coordinates
    {display_cursor_row, display_cursor_col} =
      compute_display_cursor(
        cursor_line,
        cursor_col,
        viewport,
        window.fold_map,
        ctx.decorations,
        visual_entries,
        wrapped_coordinates?
      )

    cursor_shape =
      if is_active do
        Minga.Editing.cursor_shape(state)
      else
        :block
      end

    display_cursor_col =
      adjust_cursor_col_for_shape(
        display_cursor_row,
        display_cursor_col,
        cursor_shape,
        visual_rows
      )

    # Hide the editor cursor when the minibuffer has focus (command, search,
    # eval, search_prompt modes). The native SwiftUI minibuffer shows its
    # own cursor; having two cursors visible is confusing.
    cursor_visible =
      if is_active do
        not Minga.Editing.minibuffer_mode?(state)
      else
        true
      end

    # Selection in display coordinates
    selection =
      build_selection(
        ctx.visual_selection,
        viewport,
        visible_row_count,
        visual_entries,
        wrapped_coordinates?
      )

    # Search matches in display coordinates
    viewport_bottom = viewport.top + visible_row_count

    search_matches =
      build_search_matches(
        ctx.search_matches,
        ctx.confirm_match,
        viewport,
        viewport_bottom,
        visual_entries,
        wrapped_coordinates?
      )

    # Diagnostic inline ranges in display coordinates
    diagnostic_ranges =
      build_diagnostic_ranges(
        snapshot.file_path,
        viewport,
        visible_row_count,
        visual_entries,
        wrapped_coordinates?
      )

    # Document highlights in display coordinates
    doc_highlights =
      build_document_highlights(
        state.workspace.document_highlights,
        viewport,
        viewport_bottom,
        visual_entries,
        wrapped_coordinates?
      )

    # Line annotations in display coordinates
    annotations =
      build_annotations(
        ctx.decorations,
        viewport.top,
        viewport_bottom,
        visual_entries,
        wrapped_coordinates?
      )

    %RenderWindow{
      window_id: win_id,
      content_kind: content_kind,
      rect: rect,
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
      gutter: build_gutter(scroll, ctx, content_kind),
      cursorline: build_cursorline(content_row, display_cursor_row, is_active, ctx),
      indent_guides: build_indent_guides(scroll, ctx, content_kind),
      geometry: build_geometry(state, scroll, content_kind),
      content_epoch: scroll.content_epoch,
      full_refresh: scroll.full_refresh
    }
  end

  @doc "Returns the source buffer position for a click in wrapped composed rows."
  @spec wrapped_source_position(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Context.t(),
          map()
        ) :: {:ok, non_neg_integer(), non_neg_integer()} | :error
  def wrapped_source_position(
        lines,
        first_line,
        visual_row,
        display_col,
        %Context{} = ctx,
        options
      )
      when is_list(lines) and is_integer(first_line) and is_integer(visual_row) and
             is_integer(display_col) and is_map(options) do
    lines
    |> build_visual_entries_wrapped(first_line, ctx, %{
      first_line_byte_offset: 0,
      options: options
    })
    |> Enum.at(visual_row)
    |> source_position_from_visual_entry(display_col, ctx.decorations)
  end

  @spec source_position_from_visual_entry(
          visual_row_entry() | nil,
          non_neg_integer(),
          Decorations.t()
        ) ::
          {:ok, non_neg_integer(), non_neg_integer()} | :error
  defp source_position_from_visual_entry(nil, _display_col, _decorations), do: :error

  defp source_position_from_visual_entry(entry, display_col, decorations) do
    composed_col = entry.source_start_col + max(display_col - entry.indent_width, 0)
    buffer_col = Decorations.display_col_to_buf_col(decorations, entry.buf_line, composed_col)
    {:ok, entry.buf_line, buffer_col}
  end

  # ── Visual row building ────────────────────────────────────────────────

  @spec build_visual_entries(
          [String.t()],
          non_neg_integer(),
          [DisplayMap.entry()] | nil,
          boolean(),
          Context.t(),
          map()
        ) :: [visual_row_entry()]
  defp build_visual_entries(lines, first_line, visible_line_map, wrap_on, ctx, snapshot) do
    build_visual_entries_for_mode(lines, first_line, visible_line_map, wrap_on, ctx, snapshot)
  end

  @spec build_visual_entries_for_mode(
          [String.t()],
          non_neg_integer(),
          [DisplayMap.entry()] | nil,
          boolean(),
          Context.t(),
          map()
        ) :: [visual_row_entry()]
  defp build_visual_entries_for_mode(lines, first_line, visible_line_map, _wrap_on, ctx, snapshot)
       when is_list(visible_line_map) do
    build_visual_entries_folded(lines, first_line, visible_line_map, ctx, snapshot)
  end

  defp build_visual_entries_for_mode(lines, first_line, nil, true, ctx, snapshot) do
    build_visual_entries_wrapped(lines, first_line, ctx, snapshot)
  end

  defp build_visual_entries_for_mode(lines, first_line, nil, false, ctx, snapshot) do
    build_visual_entries_sequential(lines, first_line, ctx, snapshot)
  end

  # Sequential path (no folds): one visual row per line.
  @spec build_visual_entries_sequential(
          [String.t()],
          non_neg_integer(),
          Context.t(),
          map()
        ) :: [visual_row_entry()]
  defp build_visual_entries_sequential(lines, first_line, ctx, snapshot) do
    first_byte_off = snapshot.first_line_byte_offset

    lines_with_offsets = build_lines_with_offsets(lines, first_byte_off)

    highlight_segments_list =
      if ctx.highlight do
        Highlight.styles_for_visible_lines(ctx.highlight, lines_with_offsets)
      else
        List.duplicate(nil, length(lines))
      end

    lines_with_offsets
    |> Enum.zip(highlight_segments_list)
    |> Enum.with_index()
    |> Enum.map(fn {{{line_text, line_byte_offset}, hl_segments}, idx} ->
      buf_line = first_line + idx

      {composed_text, spans} =
        compose_line(line_text, hl_segments, ctx, buf_line, line_byte_offset)

      row = %Row{
        row_id: Row.stable_id(:normal, buf_line),
        row_type: :normal,
        buf_line: buf_line,
        text: composed_text,
        spans: spans,
        content_hash: Row.compute_hash(composed_text, spans)
      }

      visual_entry(row, 0, Unicode.display_width(composed_text), 0)
    end)
  end

  @spec build_visual_entries_wrapped([String.t()], non_neg_integer(), Context.t(), map()) :: [
          visual_row_entry()
        ]
  defp build_visual_entries_wrapped(lines, first_line, ctx, snapshot) do
    first_byte_off = snapshot.first_line_byte_offset
    lines_with_offsets = build_lines_with_offsets(lines, first_byte_off)

    highlight_segments_list =
      if ctx.highlight do
        Highlight.styles_for_visible_lines(ctx.highlight, lines_with_offsets)
      else
        List.duplicate(nil, length(lines))
      end

    lines_with_offsets
    |> Enum.zip(highlight_segments_list)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{{line_text, line_byte_offset}, hl_segments}, idx} ->
      buf_line = first_line + idx

      {composed_text, spans} =
        compose_line(line_text, hl_segments, ctx, buf_line, line_byte_offset)

      wrap_composed_entries(composed_text, spans, buf_line, wrap_options(ctx, snapshot.options))
    end)
  end

  @spec wrap_composed_entries(String.t(), [Span.t()], non_neg_integer(), keyword()) :: [
          visual_row_entry()
        ]
  defp wrap_composed_entries(composed_text, spans, buf_line, opts) do
    [visual_rows] = WrapMap.compute([composed_text], Keyword.fetch!(opts, :content_width), opts)

    visual_rows
    |> Enum.with_index()
    |> Enum.map(fn {visual_row, visual_index} ->
      text = WrapMap.display_text(visual_row)
      row_type = if visual_index == 0, do: :normal, else: :wrap_continuation
      row_spans = spans_for_visual_row(spans, composed_text, visual_row)
      source_start = visual_row_source_start(composed_text, visual_row)
      source_end = visual_row_source_end(source_start, visual_row)
      source_start_byte = Map.get(visual_row, :byte_offset, 0)

      source_end_byte =
        source_start_byte +
          byte_size(Map.get(visual_row, :source_text, Map.get(visual_row, :text, "")))

      indent_width = Map.get(visual_row, :indent_width, 0)

      row = %Row{
        row_id: Row.stable_id(row_type, buf_line, visual_index),
        row_type: row_type,
        buf_line: buf_line,
        visual_index: visual_index,
        text: text,
        spans: row_spans,
        content_hash: Row.compute_hash(text, row_spans)
      }

      visual_entry(
        row,
        composed_text,
        source_start,
        source_end,
        source_start_byte,
        source_end_byte,
        indent_width
      )
    end)
  end

  @spec wrap_options(Context.t(), map()) :: keyword()
  defp wrap_options(%Context{} = ctx, options) do
    [
      content_width: max(ctx.content_w, 1),
      breakindent: Map.get(options, :breakindent, true),
      linebreak: Map.get(options, :linebreak, true),
      oracle: ctx.width_oracle,
      tab_width: ctx.tab_width
    ]
  end

  @spec trim_visual_entries([visual_row_entry()], non_neg_integer(), non_neg_integer()) :: [
          visual_row_entry()
        ]
  defp trim_visual_entries(entries, offset, row_count) do
    entries
    |> drop_visual_entry_offset(offset)
    |> Enum.take(row_count)
    |> Enum.with_index()
    |> Enum.map(fn {entry, display_row} -> %{entry | display_row: display_row} end)
  end

  @spec drop_visual_entry_offset([visual_row_entry()], non_neg_integer()) :: [visual_row_entry()]
  defp drop_visual_entry_offset(entries, 0), do: entries

  defp drop_visual_entry_offset(entries, offset) do
    case Enum.drop(entries, offset) do
      [] -> entries |> List.last() |> List.wrap()
      visible -> visible
    end
  end

  @spec visual_entry(Row.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          visual_row_entry()
  defp visual_entry(%Row{} = row, source_start_col, source_end_col, indent_width) do
    visual_entry(
      row,
      row.text,
      source_start_col,
      source_end_col,
      0,
      byte_size(row.text),
      indent_width
    )
  end

  @spec visual_entry(
          Row.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: visual_row_entry()
  defp visual_entry(
         %Row{} = row,
         source_text,
         source_start_col,
         source_end_col,
         source_start_byte,
         source_end_byte,
         indent_width
       ) do
    %{
      row: row,
      buf_line: row.buf_line,
      visual_index: row.visual_index,
      display_row: 0,
      source_text: source_text,
      source_start_byte: source_start_byte,
      source_end_byte: source_end_byte,
      source_start_col: source_start_col,
      source_end_col: source_end_col,
      indent_width: indent_width,
      row_width: Unicode.display_width(row.text)
    }
  end

  @spec spans_for_visual_row([Span.t()], String.t(), WrapMap.visual_row()) :: [Span.t()]
  defp spans_for_visual_row(spans, composed_text, visual_row) do
    source_start = visual_row_source_start(composed_text, visual_row)
    source_end = visual_row_source_end(source_start, visual_row)
    indent_width = Map.get(visual_row, :indent_width, 0)

    spans
    |> Enum.flat_map(&Span.rebase_to_visual_row(&1, source_start, source_end, indent_width))
  end

  @spec visual_row_source_start(String.t(), WrapMap.visual_row()) :: non_neg_integer()
  defp visual_row_source_start(composed_text, visual_row) do
    Unicode.display_col(composed_text, Map.get(visual_row, :byte_offset, 0))
  end

  @spec visual_row_source_end(non_neg_integer(), WrapMap.visual_row()) :: non_neg_integer()
  defp visual_row_source_end(source_start, visual_row) do
    source_text = Map.get(visual_row, :source_text, Map.get(visual_row, :text, ""))
    source_start + Unicode.display_width(source_text)
  end

  # Fold-aware path: walks visible_line_map entries.
  @spec build_visual_entries_folded(
          [String.t()],
          non_neg_integer(),
          [DisplayMap.entry()],
          Context.t(),
          map()
        ) :: [visual_row_entry()]
  defp build_visual_entries_folded(lines, first_line, visible_line_map, ctx, snapshot) do
    line_byte_offsets =
      build_line_byte_offsets(lines, first_line, snapshot.first_line_byte_offset)

    {entries, _counters} =
      Enum.map_reduce(visible_line_map, %{}, fn {buf_line, entry_type}, counters ->
        {visual_identity_index, counters} = next_visual_identity(buf_line, entry_type, counters)

        row =
          build_visual_row_entry(
            buf_line,
            entry_type,
            lines,
            first_line,
            ctx,
            line_byte_offsets,
            visual_identity_index
          )

        {visual_entry(row, 0, Unicode.display_width(row.text), 0), counters}
      end)

    entries
  end

  @spec next_visual_identity(non_neg_integer(), term(), map()) :: {non_neg_integer(), map()}
  defp next_visual_identity(buf_line, entry_type, counters) do
    case visual_identity_key(buf_line, entry_type) do
      nil ->
        {0, counters}

      key ->
        index = Map.get(counters, key, 0)
        {index, Map.put(counters, key, index + 1)}
    end
  end

  @spec visual_identity_key(non_neg_integer(), term()) :: term() | nil
  defp visual_identity_key(buf_line, {:virtual_line, _vt}), do: {buf_line, :virtual_line}
  defp visual_identity_key(buf_line, {:block, _block, _line_idx}), do: {buf_line, :block}
  defp visual_identity_key(_buf_line, _entry_type), do: nil

  @spec build_visual_row_entry(
          non_neg_integer(),
          term(),
          [String.t()],
          non_neg_integer(),
          Context.t(),
          %{non_neg_integer() => non_neg_integer()},
          non_neg_integer()
        ) :: Row.t()
  defp build_visual_row_entry(
         buf_line,
         :normal,
         lines,
         first_line,
         ctx,
         line_byte_offsets,
         _index
       ) do
    line_text = line_at(lines, buf_line, first_line)
    line_byte_offset = Map.get(line_byte_offsets, buf_line, 0)
    {composed, spans} = compose_line(line_text, nil, ctx, buf_line, line_byte_offset)

    %Row{
      row_id: Row.stable_id(:normal, buf_line),
      row_type: :normal,
      buf_line: buf_line,
      text: composed,
      spans: spans,
      content_hash: Row.compute_hash(composed, spans)
    }
  end

  defp build_visual_row_entry(
         buf_line,
         {:fold_start, hidden_count},
         lines,
         first_line,
         ctx,
         line_byte_offsets,
         _index
       ) do
    line_text = line_at(lines, buf_line, first_line)
    line_byte_offset = Map.get(line_byte_offsets, buf_line, 0)
    {composed, spans} = compose_line(line_text, nil, ctx, buf_line, line_byte_offset)
    {composed, spans} = append_fold_summary(composed, spans, hidden_count, ctx)

    %Row{
      row_id: Row.stable_id(:fold_start, buf_line, 0, hidden_count),
      row_type: :fold_start,
      buf_line: buf_line,
      text: composed,
      spans: spans,
      content_hash: Row.compute_hash(composed, spans)
    }
  end

  defp build_visual_row_entry(
         buf_line,
         {:virtual_line, vt},
         _lines,
         _first_line,
         _ctx,
         _line_byte_offsets,
         visual_identity_index
       ) do
    text = virtual_text_to_string(vt)

    spans = virtual_text_spans(vt)

    %Row{
      row_id: Row.stable_id(:virtual_line, buf_line, visual_identity_index),
      row_type: :virtual_line,
      buf_line: buf_line,
      visual_index: visual_identity_index,
      text: text,
      spans: spans,
      content_hash: Row.compute_hash(text, spans)
    }
  end

  defp build_visual_row_entry(
         buf_line,
         {:block, block, line_idx},
         _lines,
         _first_line,
         ctx,
         _line_byte_offsets,
         visual_identity_index
       ) do
    # Block decorations render via callback; capture the rendered text using the same text width as the draw path.
    rendered_lines = block.render.(ctx.content_w)
    normalized = BlockDecoration.normalize_render_result(rendered_lines)
    segments = Enum.at(normalized, line_idx, [])
    text = Enum.map_join(segments, fn {t, _style} -> t end)
    spans = segments_to_spans(segments)

    %Row{
      row_id: Row.stable_id(:block, buf_line, visual_identity_index),
      row_type: :block,
      buf_line: buf_line,
      visual_index: visual_identity_index,
      text: text,
      spans: spans,
      content_hash: Row.compute_hash(text, spans)
    }
  end

  defp build_visual_row_entry(
         buf_line,
         {:decoration_fold, fold},
         _lines,
         _first_line,
         _ctx,
         _line_byte_offsets,
         _index
       ) do
    hidden = FoldRegion.hidden_count(fold)
    text = " ··· #{hidden} lines"

    %Row{
      row_id: Row.stable_id(:fold_start, buf_line, 0, Row.discriminator(fold.id)),
      row_type: :fold_start,
      buf_line: buf_line,
      text: text,
      spans: [],
      content_hash: Row.compute_hash(text, [])
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
          Context.t(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {String.t(), [Span.t()]}
  defp compose_line(line_text, hl_segments, ctx, buf_line, line_byte_offset) do
    # Start with highlight segments or plain text
    segments =
      case hl_segments do
        nil -> [{line_text, Minga.Core.Face.new()}]
        segs -> segs
      end

    # Merge decoration highlights (search matches, etc.)
    line_highlights = Decorations.highlights_for_line(ctx.decorations, buf_line)

    line_highlights =
      line_highlights ++ todo_highlight_ranges(line_text, buf_line, ctx, line_byte_offset)

    segments = Decorations.merge_highlights(segments, line_highlights, buf_line)

    # Apply conceals and inject inline virtual text (shared pipeline)
    segments = Composition.compose_segments(segments, ctx.decorations, buf_line)

    segments =
      if ctx.show_invisible,
        do: Composition.apply_invisible_chars(segments, ctx.tab_width, ctx.whitespace_face),
        else: segments

    # Convert to composed text + spans
    Composition.segments_to_text_and_spans(segments)
  end

  @spec append_fold_summary(String.t(), [Span.t()], non_neg_integer(), Context.t()) ::
          {String.t(), [Span.t()]}
  defp append_fold_summary(composed, spans, hidden_count, ctx) do
    suffix = " ··· #{hidden_count} lines"
    start_col = Unicode.display_width(composed)
    end_col = start_col + Unicode.display_width(suffix)

    fold_span =
      Span.from_face(Minga.Core.Face.new(fg: ctx.gutter_colors.fold_fg), start_col, end_col)

    {composed <> suffix, spans ++ [fold_span]}
  end

  @spec todo_highlight_ranges(String.t(), non_neg_integer(), Context.t(), non_neg_integer()) :: [
          HighlightRange.t()
        ]
  defp todo_highlight_ranges(line_text, buf_line, ctx, line_byte_offset) do
    line_text
    |> HlTodo.scan_line()
    |> Enum.filter(&todo_match_in_scope?(&1, ctx, line_text, line_byte_offset))
    |> Enum.map(&todo_highlight_range(&1, buf_line, ctx, line_text))
  end

  @spec todo_match_in_scope?(HlTodo.match(), Context.t(), String.t(), non_neg_integer()) ::
          boolean()
  defp todo_match_in_scope?(_match, %{highlight: nil}, _line_text, _line_byte_offset), do: true

  defp todo_match_in_scope?(
         {start_byte, end_byte, _keyword},
         %{highlight: highlight},
         line_text,
         line_byte_offset
       ) do
    if Highlight.has_spans?(highlight) do
      highlight
      |> Highlight.comment_ranges_for_line(line_text, line_byte_offset)
      |> Enum.any?(fn {comment_start, comment_end} ->
        start_byte >= comment_start and end_byte <= comment_end
      end)
    else
      true
    end
  end

  @spec todo_highlight_range(HlTodo.match(), non_neg_integer(), Context.t(), String.t()) ::
          HighlightRange.t()
  defp todo_highlight_range({start_byte, end_byte, keyword}, buf_line, ctx, line_text) do
    %HighlightRange{
      id: make_ref(),
      start: {buf_line, byte_offset_to_grapheme_index(line_text, start_byte)},
      end_: {buf_line, byte_offset_to_grapheme_index(line_text, end_byte)},
      style: Map.get(ctx.hl_todo_faces, keyword, Minga.Core.Face.new(bold: true)),
      priority: 10,
      group: :hl_todo
    }
  end

  @spec byte_offset_to_grapheme_index(String.t(), non_neg_integer()) :: non_neg_integer()
  defp byte_offset_to_grapheme_index(text, byte_offset) do
    text
    |> binary_part(0, min(byte_offset, byte_size(text)))
    |> String.length()
  rescue
    ArgumentError -> String.length(text)
  end

  # ── Cursor display coordinates ─────────────────────────────────────────

  @spec compute_display_cursor(
          non_neg_integer(),
          non_neg_integer(),
          Viewport.t(),
          FoldMap.t(),
          Decorations.t(),
          [visual_row_entry()],
          boolean()
        ) :: {non_neg_integer(), non_neg_integer()}
  defp compute_display_cursor(
         cursor_line,
         cursor_col,
         _viewport,
         _fold_map,
         decorations,
         visual_entries,
         true
       ) do
    compute_wrapped_display_cursor(cursor_line, cursor_col, decorations, visual_entries)
  end

  defp compute_display_cursor(
         cursor_line,
         cursor_col,
         viewport,
         fold_map,
         decorations,
         _visual_entries,
         false
       ) do
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

  @spec compute_wrapped_display_cursor(
          non_neg_integer(),
          non_neg_integer(),
          Decorations.t(),
          [visual_row_entry()]
        ) :: {non_neg_integer(), non_neg_integer()}
  defp compute_wrapped_display_cursor(cursor_line, cursor_col, decorations, visual_entries) do
    cursor_display_col = Decorations.buf_col_to_display_col(decorations, cursor_line, cursor_col)

    visual_entries
    |> Enum.filter(&(&1.buf_line == cursor_line))
    |> visual_entry_for_source_col(cursor_display_col)
    |> cursor_position_from_visual_entry(cursor_display_col)
  end

  @spec visual_entry_for_source_col([visual_row_entry()], non_neg_integer()) ::
          visual_row_entry() | nil
  defp visual_entry_for_source_col([], _cursor_display_col), do: nil

  defp visual_entry_for_source_col(entries, cursor_display_col) do
    Enum.find(entries, fn entry ->
      cursor_display_col >= entry.source_start_col and cursor_display_col < entry.source_end_col
    end) || List.last(entries)
  end

  @spec cursor_position_from_visual_entry(visual_row_entry() | nil, non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp cursor_position_from_visual_entry(nil, cursor_display_col), do: {0, cursor_display_col}

  defp cursor_position_from_visual_entry(entry, cursor_display_col) do
    col = max(cursor_display_col - entry.source_start_col + entry.indent_width, 0)
    {entry.display_row, col}
  end

  @spec adjust_cursor_col_for_shape(
          non_neg_integer(),
          non_neg_integer(),
          RenderWindow.cursor_shape(),
          [Row.t()]
        ) :: non_neg_integer()
  defp adjust_cursor_col_for_shape(row, col, :block, visual_rows) do
    row_width = visual_rows |> Enum.at(row) |> visual_row_width()

    if row_width > 0 and col >= row_width do
      row_width - 1
    else
      col
    end
  end

  defp adjust_cursor_col_for_shape(_row, col, _shape, _visual_rows), do: col

  @spec visual_row_width(Row.t() | nil) :: non_neg_integer()
  defp visual_row_width(nil), do: 0
  defp visual_row_width(%Row{text: text}), do: Unicode.display_width(text)

  # ── Gutter ─────────────────────────────────────────────────────────────

  @spec build_gutter(WindowScroll.t(), Context.t(), RenderWindow.content_kind()) ::
          Gutter.t() | nil
  defp build_gutter(%WindowScroll{} = scroll, %Context{} = ctx, content_kind)
       when content_kind in [:buffer, :agent_chat] do
    %WindowScroll{
      win_id: win_id,
      win_layout: %{content: {content_row, content_col, full_width, content_height}},
      cursor_line: cursor_line,
      snapshot: snapshot,
      content_w: _content_w,
      line_number_style: line_number_style,
      is_active: is_active
    } = scroll

    line_count = max(snapshot.line_count, 0)

    metrics = gutter_metrics(scroll, :buffer)
    line_number_width = metrics.line_number_width
    sign_col_width = metrics.sign_col_width

    %Gutter{
      window_id: win_id,
      content_row: content_row,
      content_col: content_col,
      content_height: content_height,
      is_active: is_active,
      content_width: full_width,
      cursor_line: max(cursor_line, 0),
      line_number_style: line_number_style,
      line_number_width: line_number_width,
      sign_col_width: sign_col_width,
      entries: build_gutter_entries(scroll, ctx, line_count)
    }
  end

  defp build_gutter(_scroll, _ctx, _content_kind), do: nil

  @spec build_geometry(state(), WindowScroll.t(), RenderWindow.content_kind()) :: PaneGeometry.t()
  defp build_geometry(state, %WindowScroll{} = scroll, content_kind) do
    metrics = gutter_metrics(scroll, content_kind)
    gutter_width = GutterMetrics.total_width(metrics)
    content_rect = scroll.win_layout.content
    total_rect = Map.get(scroll.win_layout, :total, content_rect)
    {row, col, width, height} = content_rect
    gutter_rect = {row, col, min(gutter_width, width), height}
    text_col = col + min(gutter_width, width)
    text_width = max(width - gutter_width, 0)
    text_rect = {row, text_col, text_width, height}

    %PaneGeometry{
      window_id: scroll.win_id,
      total_rect: total_rect,
      content_rect: content_rect,
      text_rect: text_rect,
      gutter_rect: gutter_rect,
      clip_rect: text_rect,
      viewport: viewport_summary(scroll, text_width),
      gutter_metrics: metrics,
      hit_regions: hit_regions(state, scroll.win_id, text_rect, gutter_rect, metrics)
    }
  end

  @spec gutter_metrics(WindowScroll.t(), RenderWindow.content_kind()) :: GutterMetrics.t()
  defp gutter_metrics(%WindowScroll{} = scroll, content_kind)
       when content_kind in [:buffer, :agent_chat] do
    line_count = max(scroll.snapshot.line_count, 0)

    line_number_width =
      if scroll.line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    %GutterMetrics{
      line_number_width: line_number_width,
      sign_col_width: EditorGutter.sign_column_width() + EditorGutter.fold_column_width()
    }
  end

  defp gutter_metrics(_scroll, _content_kind) do
    %GutterMetrics{line_number_width: 0, sign_col_width: 0}
  end

  @spec viewport_summary(WindowScroll.t(), non_neg_integer()) :: RenderViewport.t()
  defp viewport_summary(%WindowScroll{} = scroll, text_width) do
    %RenderViewport{
      top: scroll.viewport.top,
      left: scroll.viewport.left,
      rows: Viewport.content_rows(scroll.viewport),
      cols: text_width,
      total_lines: max(scroll.snapshot.line_count, 0),
      visual_row_offset: scroll.viewport.visual_row_offset,
      total_visual_rows: total_visual_rows(scroll)
    }
  end

  @spec total_visual_rows(WindowScroll.t()) :: non_neg_integer()
  defp total_visual_rows(%WindowScroll{total_visual_rows: total})
       when is_integer(total) and total > 0,
       do: total

  defp total_visual_rows(%WindowScroll{wrap_on: false, snapshot: snapshot}),
    do: max(snapshot.line_count, 0)

  defp total_visual_rows(%WindowScroll{} = scroll) do
    scroll.lines
    |> WrapMap.compute(max(scroll.content_w, 1),
      breakindent: Map.get(scroll.snapshot.options, :breakindent, true),
      linebreak: Map.get(scroll.snapshot.options, :linebreak, true),
      oracle: scroll.width_oracle,
      tab_width: Map.get(scroll.snapshot.options, :tab_width, 2)
    )
    |> WrapMap.visual_row_count()
  end

  @spec hit_regions(
          state(),
          non_neg_integer(),
          PaneGeometry.rect(),
          PaneGeometry.rect(),
          GutterMetrics.t()
        ) :: [HitRegion.t()]
  defp hit_regions(state, window_id, text_rect, gutter_rect, %GutterMetrics{} = metrics) do
    [text_hit_region(window_id, text_rect)] ++
      gutter_hit_regions(window_id, gutter_rect, metrics) ++
      modeline_hit_regions(state, window_id) ++
      status_bar_hit_regions(state, window_id) ++
      divider_hit_regions(state, window_id)
  end

  @spec text_hit_region(non_neg_integer(), PaneGeometry.rect()) :: HitRegion.t()
  defp text_hit_region(window_id, rect) do
    %HitRegion{kind: :text, rect: rect, window_id: window_id, target: %{window_id: window_id}}
  end

  @spec gutter_hit_regions(non_neg_integer(), PaneGeometry.rect(), GutterMetrics.t()) :: [
          HitRegion.t()
        ]
  defp gutter_hit_regions(_window_id, {_row, _col, 0, _height}, _metrics), do: []

  defp gutter_hit_regions(
         window_id,
         {row, col, width, height} = gutter_rect,
         %GutterMetrics{} = metrics
       ) do
    fold_col = col + max(metrics.sign_col_width - 1, 0)
    fold_width = if metrics.sign_col_width > 0 and fold_col < col + width, do: 1, else: 0

    [
      %HitRegion{
        kind: :gutter,
        rect: gutter_rect,
        window_id: window_id,
        target: %{window_id: window_id}
      },
      %HitRegion{
        kind: :fold_control,
        rect: {row, fold_col, fold_width, height},
        window_id: window_id,
        target: %{window_id: window_id}
      }
    ]
    |> Enum.reject(fn %HitRegion{rect: {_row, _col, region_width, region_height}} ->
      region_width == 0 or region_height == 0
    end)
  end

  @spec modeline_hit_regions(state(), non_neg_integer()) :: [HitRegion.t()]
  defp modeline_hit_regions(state, window_id) do
    state
    |> Layout.get()
    |> Map.get(:window_layouts, %{})
    |> Map.get(window_id)
    |> modeline_hit_region(window_id)
  end

  @spec modeline_hit_region(map() | nil, non_neg_integer()) :: [HitRegion.t()]
  defp modeline_hit_region(%{modeline: {_row, _col, _width, 0}}, _window_id), do: []
  defp modeline_hit_region(nil, _window_id), do: []

  defp modeline_hit_region(%{modeline: rect}, window_id) do
    [
      %HitRegion{
        kind: :modeline,
        rect: rect,
        window_id: window_id,
        target: %{window_id: window_id}
      }
    ]
  end

  @spec status_bar_hit_regions(state(), non_neg_integer()) :: [HitRegion.t()]
  defp status_bar_hit_regions(state, window_id) do
    case Layout.get(state).status_bar do
      nil ->
        []

      rect ->
        [
          %HitRegion{
            kind: :status_bar,
            rect: rect,
            window_id: window_id,
            target: %{window_id: window_id}
          }
        ]
    end
  end

  @spec divider_hit_regions(state(), non_neg_integer()) :: [HitRegion.t()]
  defp divider_hit_regions(state, window_id) do
    layout = Layout.get(state)
    windows = state.workspace.windows

    verticals =
      if windows.tree == nil do
        []
      else
        collect_vertical_dividers(windows.tree, layout.editor_area)
      end

    horizontals =
      Enum.map(layout.horizontal_separators, fn {row, col, width, _filename} ->
        {row, col, width, 1}
      end)

    Enum.map(verticals ++ horizontals, fn rect ->
      %HitRegion{
        kind: :divider,
        rect: rect,
        window_id: window_id,
        target: %{window_id: window_id}
      }
    end)
  end

  @spec collect_vertical_dividers(WindowTree.t(), Layout.rect()) :: [PaneGeometry.rect()]
  defp collect_vertical_dividers({:leaf, _id}, _rect), do: []

  defp collect_vertical_dividers(
         {:split, :vertical, left, right, size},
         {row, col, width, height}
       ) do
    usable = width - 1
    left_width = WindowTree.clamp_size(size, usable)
    right_width = max(usable - left_width, 1)
    separator_col = col + left_width

    [{row, separator_col, 1, height}] ++
      collect_vertical_dividers(left, {row, col, left_width, height}) ++
      collect_vertical_dividers(right, {row, separator_col + 1, right_width, height})
  end

  defp collect_vertical_dividers(
         {:split, :horizontal, top, bottom, size},
         {row, col, width, height}
       ) do
    top_height = WindowTree.clamp_size(size, height)
    bottom_height = max(height - top_height, 1)

    collect_vertical_dividers(top, {row, col, width, top_height}) ++
      collect_vertical_dividers(bottom, {row + top_height, col, width, bottom_height})
  end

  @spec build_gutter_entries(WindowScroll.t(), Context.t(), non_neg_integer()) :: [
          GutterEntry.t()
        ]
  defp build_gutter_entries(_scroll, _ctx, 0), do: []

  defp build_gutter_entries(%WindowScroll{} = scroll, %Context{} = ctx, line_count) do
    fold_ranges = scroll.window.fold_ranges
    fold_start_lines = MapSet.new(fold_ranges, & &1.start_line)
    fold_end_by_start = Map.new(fold_ranges, fn range -> {range.start_line, range.end_line} end)

    scroll
    |> gutter_visible_entries(line_count)
    |> Enum.map(&resolve_gutter_entry(&1, fold_start_lines, fold_end_by_start, ctx, line_count))
  end

  @spec gutter_visible_entries(WindowScroll.t(), non_neg_integer()) :: [
          {non_neg_integer(), term()}
        ]
  defp gutter_visible_entries(%WindowScroll{visible_line_map: entries}, _line_count)
       when is_list(entries), do: entries

  defp gutter_visible_entries(
         %WindowScroll{viewport: viewport, win_layout: %{content: {_row, _col, _width, height}}},
         _line_count
       ) do
    if height <= 0 do
      []
    else
      Enum.map(0..(height - 1), fn row -> {viewport.top + row, :normal} end)
    end
  end

  @spec resolve_gutter_entry(
          {non_neg_integer(), term()},
          MapSet.t(non_neg_integer()),
          %{non_neg_integer() => non_neg_integer()},
          Context.t(),
          non_neg_integer()
        ) :: GutterEntry.t()
  defp resolve_gutter_entry(
         {buf_line, row_type},
         fold_start_lines,
         fold_end_by_start,
         ctx,
         line_count
       )
       when buf_line < line_count do
    sign_type = resolve_sign_type(buf_line, ctx.diagnostic_signs, ctx.git_signs)
    display_type = resolve_display_type(row_type, fold_start_lines, buf_line)
    fold_end_line = Map.get(fold_end_by_start, buf_line, 0xFFFF_FFFF)

    case sign_type do
      :none ->
        resolve_annotation_entry(buf_line, display_type, fold_end_line, ctx.decorations)

      _ ->
        %GutterEntry{
          buf_line: buf_line,
          display_type: display_type,
          sign_type: sign_type,
          fold_end_line: fold_end_line
        }
    end
  end

  defp resolve_gutter_entry(
         {buf_line, _row_type},
         _fold_start_lines,
         _fold_end_by_start,
         _ctx,
         _line_count
       ) do
    %GutterEntry{
      buf_line: buf_line,
      display_type: :normal,
      sign_type: :none,
      fold_end_line: 0xFFFF_FFFF
    }
  end

  @spec resolve_display_type(term(), MapSet.t(non_neg_integer()), non_neg_integer()) ::
          GutterEntry.display_type()
  defp resolve_display_type({:fold_start, _hidden}, _fold_start_lines, _buf_line), do: :fold_start

  defp resolve_display_type({:decoration_fold, _fold}, _fold_start_lines, _buf_line),
    do: :fold_start

  defp resolve_display_type(:normal, fold_start_lines, buf_line) do
    if MapSet.member?(fold_start_lines, buf_line), do: :fold_open, else: :normal
  end

  defp resolve_display_type(_row_type, _fold_start_lines, _buf_line), do: :normal

  @spec resolve_annotation_entry(
          non_neg_integer(),
          GutterEntry.display_type(),
          non_neg_integer(),
          Decorations.t()
        ) :: GutterEntry.t()
  defp resolve_annotation_entry(
         buf_line,
         display_type,
         fold_end_line,
         %Decorations{} = decorations
       ) do
    decorations
    |> Decorations.annotations_for_line(buf_line)
    |> Enum.filter(fn ann -> ann.kind == :gutter_icon end)
    |> annotation_gutter_entry(buf_line, display_type, fold_end_line)
  end

  @spec annotation_gutter_entry(
          [Decorations.LineAnnotation.t()],
          non_neg_integer(),
          GutterEntry.display_type(),
          non_neg_integer()
        ) :: GutterEntry.t()
  defp annotation_gutter_entry([], buf_line, display_type, fold_end_line) do
    %GutterEntry{
      buf_line: buf_line,
      display_type: display_type,
      sign_type: :none,
      fold_end_line: fold_end_line
    }
  end

  defp annotation_gutter_entry([ann | _], buf_line, display_type, fold_end_line) do
    %GutterEntry{
      buf_line: buf_line,
      display_type: display_type,
      sign_type: :annotation,
      fold_end_line: fold_end_line,
      sign_fg: ann.fg,
      sign_text: String.slice(ann.text, 0, 2)
    }
  end

  @spec resolve_sign_type(non_neg_integer(), %{non_neg_integer() => atom()}, %{
          non_neg_integer() => atom()
        }) :: GutterEntry.sign_type()
  defp resolve_sign_type(buf_line, diag_signs, git_signs) do
    case Map.get(diag_signs, buf_line) do
      :error -> :diag_error
      :warning -> :diag_warning
      :info -> :diag_info
      :hint -> :diag_hint
      nil -> resolve_git_sign(buf_line, git_signs)
    end
  end

  @spec resolve_git_sign(non_neg_integer(), %{non_neg_integer() => atom()}) ::
          GutterEntry.sign_type()
  defp resolve_git_sign(buf_line, git_signs) do
    case Map.get(git_signs, buf_line) do
      :added -> :git_added
      :modified -> :git_modified
      :deleted -> :git_deleted
      _ -> :none
    end
  end

  # ── Cursorline ─────────────────────────────────────────────────────────

  @spec build_cursorline(non_neg_integer(), non_neg_integer(), boolean(), Context.t()) ::
          Cursorline.t() | nil
  defp build_cursorline(_content_row, _cursor_row, false, _ctx), do: nil

  defp build_cursorline(content_row, cursor_row, true, %Context{cursorline_bg: bg})
       when is_integer(bg), do: %Cursorline{row: content_row + cursor_row, bg_rgb: bg}

  defp build_cursorline(_content_row, _cursor_row, true, %Context{}), do: Cursorline.disabled()

  # ── Indent guides ──────────────────────────────────────────────────────

  @spec build_indent_guides(WindowScroll.t(), Context.t(), RenderWindow.content_kind()) ::
          IndentGuides.t()
  defp build_indent_guides(%WindowScroll{win_id: win_id}, _ctx, content_kind)
       when content_kind != :buffer, do: IndentGuides.empty(win_id)

  defp build_indent_guides(%WindowScroll{} = scroll, %Context{} = ctx, :buffer) do
    if indent_guides_enabled?() do
      lines = Enum.take(scroll.lines, Viewport.content_rows(scroll.viewport))
      {guides, levels} = IndentGuide.compute_with_levels(lines, ctx.tab_width, ctx.cursor_col)
      indent_guides_from_guides(scroll.win_id, ctx.tab_width, guides, levels)
    else
      IndentGuides.empty(scroll.win_id)
    end
  end

  @spec indent_guides_enabled?() :: boolean()
  defp indent_guides_enabled? do
    Config.get(:indent_guides)
  catch
    :exit, _ -> true
  end

  @spec indent_guides_from_guides(non_neg_integer(), pos_integer(), [IndentGuide.guide()], [
          non_neg_integer()
        ]) :: IndentGuides.t()
  defp indent_guides_from_guides(win_id, tab_width, [], _levels),
    do: %IndentGuides{
      window_id: win_id,
      tab_width: tab_width,
      active_guide_col: 0xFFFF,
      guide_cols: [],
      line_indent_levels: []
    }

  defp indent_guides_from_guides(win_id, tab_width, guides, levels) do
    active_guide = Enum.find(guides, fn guide -> guide.active end)
    active_col = if active_guide, do: active_guide.col, else: 0xFFFF

    %IndentGuides{
      window_id: win_id,
      tab_width: tab_width,
      active_guide_col: active_col,
      guide_cols: Enum.map(guides, & &1.col),
      line_indent_levels: levels
    }
  end

  # ── Overlays ───────────────────────────────────────────────────────────

  @spec build_selection(
          Selection.visual_selection(),
          Viewport.t(),
          pos_integer(),
          [visual_row_entry()],
          boolean()
        ) :: Selection.t() | nil
  defp build_selection(selection, viewport, visible_rows, _visual_entries, false) do
    Selection.from_visual_selection(
      selection,
      viewport.top,
      visible_rows,
      viewport.left,
      viewport.cols
    )
  end

  defp build_selection(nil, _viewport, _visible_rows, _visual_entries, true), do: nil

  defp build_selection(
         {:char, {sl, sc}, {el, ec}},
         _viewport,
         _visible_rows,
         visual_entries,
         true
       ) do
    build_wrapped_char_selection(sl, sc, el, ec, visual_entries)
  end

  defp build_selection(
         {:line, start_line, end_line},
         _viewport,
         _visible_rows,
         visual_entries,
         true
       ) do
    build_wrapped_line_selection(start_line, end_line, visual_entries)
  end

  @spec build_search_matches(
          [Minga.Editing.Search.Match.t()],
          Minga.Editing.Search.Match.t() | nil,
          Viewport.t(),
          non_neg_integer(),
          [visual_row_entry()],
          boolean()
        ) :: [SearchMatch.t()]
  defp build_search_matches(
         matches,
         confirm_match,
         viewport,
         viewport_bottom,
         _visual_entries,
         false
       ) do
    SearchMatch.from_context_matches(matches, confirm_match, viewport.top, viewport_bottom)
  end

  defp build_search_matches(
         matches,
         confirm_match,
         _viewport,
         _viewport_bottom,
         visual_entries,
         true
       ) do
    Enum.flat_map(matches, fn %{line: line, col: col, length: len} = match ->
      project_byte_range(line, col, line, col + len, visual_entries, fn row,
                                                                        start_col,
                                                                        _end_row,
                                                                        end_col ->
        %SearchMatch{
          row: row,
          start_col: start_col,
          end_col: end_col,
          is_current: confirm_match != nil and match == confirm_match
        }
      end)
    end)
  end

  @spec build_diagnostic_ranges(
          String.t() | nil,
          Viewport.t(),
          pos_integer(),
          [visual_row_entry()],
          boolean()
        ) :: [DiagnosticRange.t()]
  defp build_diagnostic_ranges(nil, _viewport, _visible_rows, _visual_entries, _wrapped?), do: []

  defp build_diagnostic_ranges(path, viewport, visible_rows, visual_entries, wrapped?)
       when is_binary(path) do
    uri = SyncServer.path_to_uri(path)
    diagnostics = Diagnostics.for_uri(uri)
    viewport_bottom = viewport.top + visible_rows

    if wrapped? do
      Enum.flat_map(diagnostics, &diagnostic_to_wrapped_ranges(&1, visual_entries))
    else
      DiagnosticRange.from_diagnostics(diagnostics, viewport.top, viewport_bottom)
    end
  end

  @spec diagnostic_to_wrapped_ranges(Diagnostics.Diagnostic.t(), [visual_row_entry()]) :: [
          DiagnosticRange.t()
        ]
  defp diagnostic_to_wrapped_ranges(%{range: range, severity: severity}, visual_entries) do
    project_byte_range(
      range.start_line,
      range.start_col,
      range.end_line,
      range.end_col,
      visual_entries,
      fn start_row, start_col, end_row, end_col ->
        %DiagnosticRange{
          start_row: start_row,
          start_col: start_col,
          end_row: end_row,
          end_col: end_col,
          severity: severity
        }
      end
    )
  end

  # ── Document highlights ─────────────────────────────────────────────────

  @spec build_document_highlights(
          [Minga.LSP.DocumentHighlight.t()] | nil,
          Viewport.t(),
          non_neg_integer(),
          [visual_row_entry()],
          boolean()
        ) :: [DocumentHighlight.t()]
  defp build_document_highlights(nil, _viewport, _bottom, _visual_entries, _wrapped?), do: []
  defp build_document_highlights([], _viewport, _bottom, _visual_entries, _wrapped?), do: []

  defp build_document_highlights(highlights, viewport, viewport_bottom, _visual_entries, false) do
    highlights
    |> Enum.filter(fn hl ->
      hl.start_line < viewport_bottom and hl.end_line >= viewport.top
    end)
    |> Enum.map(fn hl ->
      %DocumentHighlight{
        start_row: hl.start_line - viewport.top,
        start_col: hl.start_col,
        end_row: hl.end_line - viewport.top,
        end_col: hl.end_col,
        kind: hl.kind
      }
    end)
  end

  defp build_document_highlights(highlights, _viewport, _viewport_bottom, visual_entries, true) do
    Enum.flat_map(highlights, fn hl ->
      project_range(
        hl.start_line,
        hl.start_col,
        hl.end_line,
        hl.end_col,
        visual_entries,
        fn start_row, start_col, end_row, end_col ->
          %DocumentHighlight{
            start_row: start_row,
            start_col: start_col,
            end_row: end_row,
            end_col: end_col,
            kind: hl.kind
          }
        end
      )
    end)
  end

  # ── Line annotations ──────────────────────────────────────────────────

  @spec build_annotations(
          Decorations.t(),
          non_neg_integer(),
          non_neg_integer(),
          [visual_row_entry()],
          boolean()
        ) :: [Annotation.t()]
  defp build_annotations(
         %Decorations{annotations: []},
         _top,
         _bottom,
         _visual_entries,
         _wrapped?
       ),
       do: []

  defp build_annotations(
         %Decorations{} = decorations,
         viewport_top,
         viewport_bottom,
         _visual_entries,
         false
       ) do
    decorations.annotations
    |> Enum.filter(fn ann ->
      ann.line >= viewport_top and ann.line < viewport_bottom
    end)
    |> Enum.sort_by(fn ann -> {ann.line, ann.priority} end)
    |> Enum.map(fn ann ->
      %Annotation{
        row: ann.line - viewport_top,
        kind: ann.kind,
        fg: ann.fg,
        bg: ann.bg,
        text: ann.text
      }
    end)
  end

  defp build_annotations(
         %Decorations{} = decorations,
         _viewport_top,
         _viewport_bottom,
         visual_entries,
         true
       ) do
    decorations.annotations
    |> Enum.sort_by(fn ann -> {ann.line, ann.priority} end)
    |> Enum.flat_map(fn ann ->
      case first_visual_entry_for_line(visual_entries, ann.line) do
        nil ->
          []

        entry ->
          [
            %Annotation{
              row: entry.display_row,
              kind: ann.kind,
              fg: ann.fg,
              bg: ann.bg,
              text: ann.text
            }
          ]
      end
    end)
  end

  @spec build_wrapped_char_selection(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [visual_row_entry()]
        ) :: Selection.t() | nil
  defp build_wrapped_char_selection(start_line, start_col, end_line, end_col, visual_entries) do
    selected_entries = visual_entries_for_line_range(visual_entries, start_line, end_line)

    with [_ | _] <- selected_entries,
         start_entry <- selection_endpoint_entry(selected_entries, start_line, start_col, :first),
         end_entry <- selection_endpoint_entry(selected_entries, end_line, end_col, :last) do
      %Selection{
        type: :char,
        start_row: start_entry.display_row,
        start_col: selection_visual_col(start_entry, start_col, :start),
        end_row: end_entry.display_row,
        end_col: selection_visual_col(end_entry, end_col, :end)
      }
    else
      _ -> nil
    end
  end

  @spec build_wrapped_line_selection(non_neg_integer(), non_neg_integer(), [visual_row_entry()]) ::
          Selection.t() | nil
  defp build_wrapped_line_selection(start_line, end_line, visual_entries) do
    case visual_entries_for_line_range(visual_entries, start_line, end_line) do
      [] ->
        nil

      entries ->
        start_entry = hd(entries)
        end_entry = List.last(entries)

        %Selection{
          type: :line,
          start_row: start_entry.display_row,
          start_col: 0,
          end_row: end_entry.display_row,
          end_col: 0
        }
    end
  end

  @spec selection_endpoint_entry(
          [visual_row_entry()],
          non_neg_integer(),
          non_neg_integer(),
          :first | :last
        ) :: visual_row_entry()
  defp selection_endpoint_entry(entries, line, col, fallback) do
    line_entries = Enum.filter(entries, &(&1.buf_line == line))

    if line_entries == [] do
      endpoint_fallback(entries, fallback)
    else
      visual_entry_for_source_col(line_entries, col) || endpoint_fallback(entries, fallback)
    end
  end

  @spec endpoint_fallback([visual_row_entry()], :first | :last) :: visual_row_entry()
  defp endpoint_fallback(entries, :first), do: hd(entries)
  defp endpoint_fallback(entries, :last), do: List.last(entries)

  @spec visual_entries_for_line_range([visual_row_entry()], non_neg_integer(), non_neg_integer()) ::
          [
            visual_row_entry()
          ]
  defp visual_entries_for_line_range(visual_entries, start_line, end_line) do
    Enum.filter(visual_entries, fn entry ->
      entry.buf_line >= start_line and entry.buf_line <= end_line
    end)
  end

  @spec first_visual_entry_for_line([visual_row_entry()], non_neg_integer()) ::
          visual_row_entry() | nil
  defp first_visual_entry_for_line(visual_entries, line) do
    Enum.find(visual_entries, &(&1.buf_line == line))
  end

  @spec project_range(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [visual_row_entry()],
          (non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer() -> term())
        ) :: [term()]
  defp project_range(start_line, start_col, end_line, end_col, visual_entries, build_range) do
    visual_entries
    |> visual_entries_for_line_range(start_line, end_line)
    |> Enum.flat_map(
      &project_entry_range(&1, start_line, start_col, end_line, end_col, build_range)
    )
  end

  @spec project_entry_range(
          visual_row_entry(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          (non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer() -> term())
        ) :: [term()]
  defp project_entry_range(entry, start_line, start_col, end_line, end_col, build_range) do
    range_start =
      if entry.buf_line == start_line,
        do: max(start_col, entry.source_start_col),
        else: entry.source_start_col

    range_end =
      if entry.buf_line == end_line,
        do: min(end_col, entry.source_end_col),
        else: entry.source_end_col

    if range_end > range_start do
      [
        build_range.(
          entry.display_row,
          visual_col_for_source_col(entry, range_start),
          entry.display_row,
          visual_col_for_source_col(entry, range_end)
        )
      ]
    else
      []
    end
  end

  @spec project_byte_range(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          [visual_row_entry()],
          (non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer() -> term())
        ) :: [term()]
  defp project_byte_range(start_line, start_byte, end_line, end_byte, visual_entries, build_range) do
    visual_entries
    |> visual_entries_for_line_range(start_line, end_line)
    |> Enum.flat_map(
      &project_entry_byte_range(&1, start_line, start_byte, end_line, end_byte, build_range)
    )
  end

  @spec project_entry_byte_range(
          visual_row_entry(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          (non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer() -> term())
        ) :: [term()]
  defp project_entry_byte_range(entry, start_line, start_byte, end_line, end_byte, build_range) do
    range_start =
      if entry.buf_line == start_line,
        do: max(start_byte, entry.source_start_byte),
        else: entry.source_start_byte

    range_end =
      if entry.buf_line == end_line,
        do: min(end_byte, entry.source_end_byte),
        else: entry.source_end_byte

    if range_end > range_start do
      [
        build_range.(
          entry.display_row,
          visual_col_for_source_byte(entry, range_start),
          entry.display_row,
          visual_col_for_source_byte(entry, range_end)
        )
      ]
    else
      []
    end
  end

  @spec selection_visual_col(visual_row_entry(), non_neg_integer(), :start | :end) ::
          non_neg_integer()
  defp selection_visual_col(entry, source_col, :start) when source_col <= entry.source_start_col,
    do: 0

  defp selection_visual_col(entry, source_col, :end) when source_col >= entry.source_end_col,
    do: entry.row_width

  defp selection_visual_col(entry, source_col, _endpoint),
    do: visual_col_for_source_col(entry, source_col)

  @spec visual_col_for_source_byte(visual_row_entry(), non_neg_integer()) :: non_neg_integer()
  defp visual_col_for_source_byte(entry, source_byte) do
    source_col = Unicode.display_col(entry.source_text, source_byte)
    visual_col_for_source_col(entry, source_col)
  end

  @spec visual_col_for_source_col(visual_row_entry(), non_neg_integer()) :: non_neg_integer()
  defp visual_col_for_source_col(entry, source_col) do
    source_col
    |> min(entry.source_end_col)
    |> max(entry.source_start_col)
    |> Kernel.-(entry.source_start_col)
    |> Kernel.+(entry.indent_width)
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

  @spec build_line_byte_offsets([String.t()], non_neg_integer(), non_neg_integer()) :: %{
          non_neg_integer() => non_neg_integer()
        }
  defp build_line_byte_offsets(lines, first_line, first_byte_off) do
    lines
    |> build_lines_with_offsets(first_byte_off)
    |> Enum.with_index(first_line)
    |> Map.new(fn {{_line_text, line_byte_offset}, buf_line} ->
      {buf_line, line_byte_offset}
    end)
  end

  @spec virtual_text_to_string(Decorations.VirtualText.t()) :: String.t()
  defp virtual_text_to_string(%{segments: segments}) do
    Enum.map_join(segments, fn {text, _style} -> text end)
  end

  @spec virtual_text_spans(Decorations.VirtualText.t()) :: [Span.t()]
  defp virtual_text_spans(%{segments: segments}) do
    segments_to_spans(segments)
  end

  @spec segments_to_spans([{String.t(), Minga.Core.Face.t()}]) :: [Span.t()]
  defp segments_to_spans(segments) do
    {spans, _col} =
      Enum.reduce(segments, {[], 0}, fn {text, style}, {acc, col} ->
        width = Unicode.display_width(text)

        if width > 0 do
          span = Span.from_face(style, col, col + width, font_id_for_face(style))
          {[span | acc], col + width}
        else
          {acc, col}
        end
      end)

    Enum.reverse(spans)
  end

  @spec font_id_for_face(Minga.Core.Face.t()) :: non_neg_integer()
  defp font_id_for_face(%Minga.Core.Face{font_family: nil}), do: 0

  defp font_id_for_face(%Minga.Core.Face{font_family: family}) when is_binary(family) do
    case MingaEditor.UI.FontRegistry.process_registry() do
      nil ->
        0

      registry ->
        {font_id, updated_registry, _new?} =
          MingaEditor.UI.FontRegistry.get_or_register(registry, family)

        MingaEditor.UI.FontRegistry.put_process_registry(updated_registry)
        font_id
    end
  end
end
