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
  alias Minga.Diagnostics
  alias MingaEditor.DisplayMap
  alias MingaEditor.FoldMap
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
  alias Minga.RenderModel.Window.IndentGuides
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.SearchMatch
  alias Minga.RenderModel.Window.Selection
  alias Minga.RenderModel.Window.Span
  alias MingaEditor.Renderer.Gutter, as: EditorGutter
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Viewport
  alias Minga.LSP.SyncServer
  alias MingaEditor.UI.Highlight

  @type state :: EditorState.t() | MingaEditor.RenderPipeline.Input.t()

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
      cursor_col: cursor_col,
      first_line: first_line,
      lines: lines,
      snapshot: snapshot,
      window: window,
      win_layout: win_layout,
      visible_line_map: visible_line_map,
      wrap_on: wrap_on
    } = scroll

    visible_rows = Viewport.content_rows(viewport)
    content_kind = Keyword.get(opts, :content_kind, :buffer)
    rect = win_layout.content
    {content_row, _content_col, _content_width, _content_height} = rect

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
      Selection.from_visual_selection(
        ctx.visual_selection,
        viewport.top,
        visible_rows,
        viewport.left,
        viewport.cols
      )

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
    diagnostic_ranges = build_diagnostic_ranges(snapshot.file_path, viewport, visible_rows)

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
        ) :: [Row.t()]
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
        ) :: [Row.t()]
  defp build_visual_rows_sequential(lines, first_line, ctx, snapshot) do
    first_byte_off = snapshot.first_line_byte_offset

    lines_with_offsets = build_lines_with_offsets(lines, first_byte_off)

    # Pre-compute highlight segments for all visible lines
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

      %Row{
        row_type: :normal,
        buf_line: buf_line,
        text: composed_text,
        spans: spans,
        content_hash: Row.compute_hash(composed_text, spans)
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
        ) :: [Row.t()]
  defp build_visual_rows_folded(lines, first_line, visible_line_map, ctx, snapshot) do
    line_byte_offsets =
      build_line_byte_offsets(lines, first_line, snapshot.first_line_byte_offset)

    Enum.map(visible_line_map, fn {buf_line, entry_type} ->
      build_visual_row_entry(buf_line, entry_type, lines, first_line, ctx, line_byte_offsets)
    end)
  end

  @spec build_visual_row_entry(
          non_neg_integer(),
          DisplayMap.entry() | atom(),
          [String.t()],
          non_neg_integer(),
          Context.t(),
          %{non_neg_integer() => non_neg_integer()}
        ) :: Row.t()
  defp build_visual_row_entry(buf_line, :normal, lines, first_line, ctx, line_byte_offsets) do
    line_text = line_at(lines, buf_line, first_line)
    line_byte_offset = Map.get(line_byte_offsets, buf_line, 0)
    {composed, spans} = compose_line(line_text, nil, ctx, buf_line, line_byte_offset)

    %Row{
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
         line_byte_offsets
       ) do
    line_text = line_at(lines, buf_line, first_line)
    line_byte_offset = Map.get(line_byte_offsets, buf_line, 0)
    {composed, spans} = compose_line(line_text, nil, ctx, buf_line, line_byte_offset)
    {composed, spans} = append_fold_summary(composed, spans, hidden_count, ctx)

    %Row{
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
         _line_byte_offsets
       ) do
    text = virtual_text_to_string(vt)

    %Row{
      row_type: :virtual_line,
      buf_line: buf_line,
      text: text,
      spans: virtual_text_spans(vt),
      content_hash: Row.compute_hash(text, [])
    }
  end

  defp build_visual_row_entry(
         buf_line,
         {:block, block, line_idx},
         _lines,
         _first_line,
         ctx,
         _line_byte_offsets
       ) do
    # Block decorations render via callback; capture the rendered text using the same text width as the draw path.
    rendered_lines = block.render.(ctx.content_w)
    normalized = BlockDecoration.normalize_render_result(rendered_lines)
    segments = Enum.at(normalized, line_idx, [])
    text = Enum.map_join(segments, fn {t, _style} -> t end)
    spans = segments_to_spans(segments)

    %Row{
      row_type: :block,
      buf_line: buf_line,
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
         _line_byte_offsets
       ) do
    hidden = FoldRegion.hidden_count(fold)
    text = " ··· #{hidden} lines"

    %Row{
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
  defp build_gutter(%WindowScroll{} = scroll, %Context{} = ctx, :buffer) do
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

    line_number_width =
      if line_number_style == :none, do: 0, else: Viewport.gutter_width(line_count)

    sign_col_width = EditorGutter.sign_column_width() + EditorGutter.fold_column_width()

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

  @spec build_gutter_entries(WindowScroll.t(), Context.t(), non_neg_integer()) :: [
          GutterEntry.t()
        ]
  defp build_gutter_entries(_scroll, _ctx, 0), do: []

  defp build_gutter_entries(%WindowScroll{} = scroll, %Context{} = ctx, line_count) do
    fold_ranges = scroll.window.fold_ranges || []
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

  # ── Diagnostics ────────────────────────────────────────────────────────

  @spec build_diagnostic_ranges(String.t() | nil, Viewport.t(), pos_integer()) :: [
          DiagnosticRange.t()
        ]
  defp build_diagnostic_ranges(nil, _viewport, _visible_rows), do: []

  defp build_diagnostic_ranges(path, viewport, visible_rows) when is_binary(path) do
    uri = SyncServer.path_to_uri(path)
    diagnostics = Diagnostics.for_uri(uri)
    viewport_bottom = viewport.top + visible_rows
    DiagnosticRange.from_diagnostics(diagnostics, viewport.top, viewport_bottom)
  end

  # ── Document highlights ─────────────────────────────────────────────────

  @spec build_document_highlights(
          [Minga.LSP.DocumentHighlight.t()] | nil,
          non_neg_integer(),
          non_neg_integer()
        ) :: [DocumentHighlight.t()]
  defp build_document_highlights(nil, _top, _bottom), do: []
  defp build_document_highlights([], _top, _bottom), do: []

  defp build_document_highlights(highlights, viewport_top, viewport_bottom) do
    highlights
    |> Enum.filter(fn hl ->
      hl.start_line < viewport_bottom and hl.end_line >= viewport_top
    end)
    |> Enum.map(fn hl ->
      %DocumentHighlight{
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
          [Annotation.t()]
  defp build_annotations(%Decorations{annotations: []}, _top, _bottom), do: []

  defp build_annotations(%Decorations{} = decorations, viewport_top, viewport_bottom) do
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
