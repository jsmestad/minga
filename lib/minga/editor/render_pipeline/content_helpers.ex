defmodule Minga.Editor.RenderPipeline.ContentHelpers do
  @moduledoc """
  Helper functions for the Content stage of the render pipeline.

  Builds render contexts, renders lines (wrapped and nowrapped),
  computes visual selection bounds, and resolves window-local
  highlight/sign data.

  Extracted from `RenderPipeline` to reduce module size.
  """

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Decorations.ConcealRange
  alias Minga.Buffer.Decorations.FoldRegion
  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Config.Options
  alias Minga.Diagnostics
  alias Minga.Editor.DisplayList
  alias Minga.Editor.Renderer.BufferLine
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.Gutter
  alias Minga.Editor.Renderer.SearchHighlight
  alias Minga.Editor.RenderPosition
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Window
  alias Minga.Editor.WrapMap
  alias Minga.Face
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.Git.Tracker, as: GitTracker
  alias Minga.Highlight
  alias Minga.LSP.SyncServer
  alias Minga.Mode.VisualState

  @type state :: EditorState.t()

  @typedoc """
  Options passed to line rendering functions.
  """
  @type line_render_opts :: %{
          first_line: non_neg_integer(),
          cursor_line: non_neg_integer(),
          ctx: Context.t(),
          ln_style: atom(),
          gutter_w: non_neg_integer(),
          first_byte_off: non_neg_integer(),
          row_off: non_neg_integer(),
          col_off: non_neg_integer(),
          window: Window.t(),
          buffer: pid()
        }

  @type visual_selection :: Context.visual_selection()

  # ── Render context ─────────────────────────────────────────────────────────

  @doc "Builds the per-frame render context for a window."
  @spec build_render_ctx(state(), Window.t(), map()) :: Context.t()
  def build_render_ctx(state, window, params) do
    %{
      viewport: viewport,
      cursor: cursor,
      lines: lines,
      first_line: first_line,
      preview_matches: preview_matches,
      gutter_w: gutter_w,
      content_w: content_w,
      has_sign_column: has_sign_column,
      is_active: is_active
    } = params

    decorations = window_decorations(window)

    visual_selection =
      if is_active do
        sel = visual_selection_grapheme_bounds(state, cursor, lines, first_line)
        adjust_selection_for_virtual_text(sel, decorations)
      else
        nil
      end

    search_matches =
      case preview_matches do
        [] -> SearchHighlight.search_matches_for_lines(state, lines, first_line)
        _ -> preview_matches
      end

    confirm_match = if(is_active, do: SearchHighlight.current_confirm_match(state), else: nil)

    # Merge search matches into decorations as highlight ranges so they
    # compose with tree-sitter syntax colors (bg overlay preserving fg).
    # Only rebuild when the match set actually changed (avoid per-frame
    # clear-and-reapply when nothing changed).

    decorations =
      maybe_update_search_decorations(
        decorations,
        search_matches,
        confirm_match,
        state.theme.search
      )

    decorations =
      if is_active do
        merge_document_highlight_decorations(decorations, state.document_highlights, state.theme)
      else
        decorations
      end

    cursorline_bg =
      if is_active and Options.get(:cursorline) do
        state.theme.editor.cursorline_bg
      else
        nil
      end

    is_gui = Map.get(params, :is_gui, false)

    %Context{
      viewport: viewport,
      visual_selection: visual_selection,
      search_matches: search_matches,
      gutter_w: gutter_w,
      content_w: content_w,
      confirm_match: confirm_match,
      highlight: window_highlight(state, window),
      cursorline_bg: cursorline_bg,
      nav_flash: state.nav_flash,
      nav_flash_bg: state.theme.editor.nav_flash_bg,
      editor_bg: state.theme.editor.bg,
      is_gui: is_gui,
      has_sign_column: has_sign_column,
      decorations: decorations,
      diagnostic_signs: diagnostic_signs_for_window(state, window),
      git_signs: git_signs_for_window(state, window),
      gutter_colors: state.theme.gutter,
      git_colors: state.theme.git
    }
  end

  # ── Line rendering ────────────────────────────────────────────────────────

  @doc """
  Renders lines without word wrapping.

  When `opts.visible_line_map` is non-nil (folds active), uses the fold-aware
  path that skips hidden lines and renders fold summaries. Otherwise uses the
  zero-overhead sequential path.
  """
  @spec render_lines_nowrap([String.t()], map()) ::
          {[DisplayList.draw()], [DisplayList.draw()], non_neg_integer(), Window.t()}
  def render_lines_nowrap(lines, opts) do
    visible_line_map = Map.get(opts, :visible_line_map)

    if visible_line_map != nil do
      render_lines_nowrap_folded(lines, opts, visible_line_map)
    else
      render_lines_nowrap_sequential(lines, opts)
    end
  end

  # Standard sequential rendering (no folds, zero overhead fast path)
  @spec render_lines_nowrap_sequential([String.t()], map()) ::
          {[DisplayList.draw()], [DisplayList.draw()], non_neg_integer(), Window.t()}
  defp render_lines_nowrap_sequential(lines, opts) do
    %{
      first_line: first_line,
      cursor_line: cursor_line,
      ctx: ctx,
      ln_style: ln_style,
      gutter_w: gutter_w,
      first_byte_off: first_byte_off,
      row_off: row_off,
      col_off: col_off,
      window: window
    } = opts

    sign_w = if ctx.has_sign_column, do: Gutter.sign_column_width(), else: 0
    max_rows = length(lines)

    # Pre-compute highlight segments for all visible lines in one O(N) pass.
    highlight_segments_list =
      if ctx.highlight do
        lines_with_offsets = build_lines_with_offsets(lines, first_byte_off)
        Highlight.styles_for_visible_lines(ctx.highlight, lines_with_offsets)
      else
        List.duplicate(nil, max_rows)
      end

    {gutters, contents_rev, _byte_off, window} =
      lines
      |> Enum.zip(highlight_segments_list)
      |> Enum.with_index()
      |> Enum.reduce(
        {[], [], first_byte_off, window},
        fn {{line_text, hl_segments}, screen_row}, {g, c, byte_off, win} ->
          buf_line = first_line + screen_row
          next_byte_off = byte_off + byte_size(line_text) + 1

          if Window.dirty?(win, buf_line) do
            {g_cmds, c_cmds, _rows} =
              BufferLine.render(%{
                line_text: line_text,
                buf_line: buf_line,
                cursor_line: cursor_line,
                byte_offset: byte_off,
                screen_row: screen_row,
                ctx: ctx,
                ln_style: ln_style,
                gutter_w: gutter_w,
                sign_w: sign_w,
                wrap_entry: nil,
                max_rows: max_rows,
                row_offset: row_off,
                col_offset: col_off,
                highlight_segments: hl_segments
              })

            win = Window.cache_line(win, buf_line, g_cmds, c_cmds)
            {g_cmds ++ g, prepend_all(c, c_cmds), next_byte_off, win}
          else
            g_cmds = Map.get(win.cached_gutter, buf_line, [])
            c_cmds = Map.get(win.cached_content, buf_line, [])
            {g_cmds ++ g, prepend_all(c, c_cmds), next_byte_off, win}
          end
        end
      )

    {Enum.reverse(gutters), Enum.reverse(contents_rev), length(lines), window}
  end

  # Fold-aware rendering: uses visible_line_map to skip folded lines
  # and render fold summary indicators
  @spec render_lines_nowrap_folded(
          [String.t()],
          line_render_opts(),
          [Minga.Editor.FoldMap.VisibleLines.line_entry()]
        ) :: {[DisplayList.draw()], [DisplayList.draw()], non_neg_integer(), Window.t()}
  defp render_lines_nowrap_folded(lines, opts, visible_line_map) do
    %{
      first_line: first_line,
      cursor_line: cursor_line,
      ctx: ctx,
      ln_style: ln_style,
      gutter_w: gutter_w,
      row_off: row_off,
      col_off: col_off,
      window: window
    } = opts

    sign_w = if ctx.has_sign_column, do: Gutter.sign_column_width(), else: 0
    wrap_on = Map.get(opts, :wrap_on, false)

    # Pre-compute wrap map for all visible buffer lines in one batch call
    # (more efficient than per-line WrapMap.compute during the reduce).
    wrap_index =
      precompute_wrap_index(
        wrap_on,
        visible_line_map,
        lines,
        first_line,
        ctx.content_w,
        ctx.decorations
      )

    render_opts = %{
      cursor_line: cursor_line,
      ctx: ctx,
      ln_style: ln_style,
      gutter_w: gutter_w,
      sign_w: sign_w,
      row_off: row_off,
      col_off: col_off,
      lines: lines,
      first_line: first_line,
      wrap_index: wrap_index
    }

    {gutters, contents_rev, screen_row, window} =
      Enum.reduce(visible_line_map, {[], [], 0, window}, fn {buf_line, fold_info},
                                                            {g, c, screen_row, win} ->
        case fold_info do
          {:virtual_line, vt} ->
            render_pos = %RenderPosition{
              screen_row: screen_row,
              gutter_w: gutter_w,
              row_off: row_off,
              col_off: col_off,
              content_w: ctx.content_w
            }

            c_cmds = render_virtual_line_entry(vt, render_pos)
            {g, prepend_all(c, c_cmds), screen_row + 1, win}

          {:block, block, line_idx} ->
            render_pos = %RenderPosition{
              screen_row: screen_row,
              gutter_w: gutter_w,
              row_off: row_off,
              col_off: col_off,
              content_w: ctx.content_w
            }

            c_cmds = render_block_entry(block, line_idx, render_pos)
            {g, prepend_all(c, c_cmds), screen_row + 1, win}

          {:decoration_fold, %FoldRegion{placeholder: placeholder} = fold}
          when placeholder != nil ->
            render_pos = %RenderPosition{
              screen_row: screen_row,
              gutter_w: gutter_w,
              row_off: row_off,
              col_off: col_off,
              content_w: ctx.content_w
            }

            fold_g = fold_gutter_indicator(fold_info, render_pos)
            segments = placeholder.(fold.start_line, fold.end_line, ctx.content_w)
            c_cmds = render_placeholder_segments(segments, render_pos)
            {fold_g ++ g, prepend_all(c, c_cmds), screen_row + 1, win}

          _ ->
            render_normal_entry(
              buf_line,
              fold_info,
              screen_row,
              render_opts,
              win,
              {g, c}
            )
        end
      end)

    # Clean up per-frame block render cache from process dictionary
    clear_block_render_cache()

    {Enum.reverse(gutters), Enum.reverse(contents_rev), screen_row, window}
  end

  defp render_normal_entry(buf_line, fold_info, screen_row, render_opts, win, {g, c}) do
    %{lines: lines, first_line: first_line, wrap_index: wrap_index} = render_opts

    line_index = buf_line - first_line
    line_text = Enum.at(lines, line_index, "")
    display_text = fold_display_text(line_text, fold_info)

    wrap_entry = Map.get(wrap_index, buf_line)
    rows_for_line = if wrap_entry, do: length(wrap_entry), else: 1

    line_opts =
      render_opts
      |> Map.put(:max_rows, screen_row + rows_for_line)
      |> Map.put(:wrap_entry, wrap_entry)

    {new_g, new_c, win} =
      render_folded_line(win, buf_line, display_text, fold_info, screen_row, line_opts, {g, c})

    {new_g, new_c, screen_row + rows_for_line, win}
  end

  # Pre-computes wrap entries for all buffer lines in the visible_line_map
  # in a single batch WrapMap.compute call. Returns %{buf_line => wrap_entry}.
  @spec precompute_wrap_index(
          boolean(),
          [{non_neg_integer(), term()}],
          [String.t()],
          non_neg_integer(),
          pos_integer(),
          Decorations.t()
        ) :: %{non_neg_integer() => WrapMap.wrap_entry()}
  defp precompute_wrap_index(false, _vlm, _lines, _first, _w, _decs), do: %{}

  defp precompute_wrap_index(true, visible_line_map, lines, first_line, width, decorations) do
    # Extract buffer lines that need wrapping (skip virtual lines, blocks, folds)
    buffer_entries =
      visible_line_map
      |> Enum.filter(fn {_buf_line, fold_info} ->
        match?(:normal, fold_info) or match?({:fold_start, _}, fold_info)
      end)
      |> Enum.map(fn {buf_line, fold_info} ->
        line_index = buf_line - first_line
        line_text = Enum.at(lines, line_index, "")
        display_text = fold_display_text(line_text, fold_info)
        {buf_line, display_text}
      end)

    # Compute wrap entries per-line, adjusting width for inline virtual text
    # and conceal ranges. Inline VTs displace content rightward; conceals
    # reduce visible width. Both affect where line breaks should occur.
    wrap_entries =
      Enum.map(buffer_entries, fn {buf_line, text} ->
        vt_width = inline_vt_width(decorations, buf_line)
        line_len = Unicode.display_width(text)
        conceal_width = conceal_hidden_width(decorations, buf_line, line_len)
        wrap_w = max(width - vt_width + conceal_width, 10)

        [entry] = WrapMap.compute([text], wrap_w)
        entry
      end)

    buf_lines = Enum.map(buffer_entries, &elem(&1, 0))

    buf_lines
    |> Enum.zip(wrap_entries)
    |> Map.new()
  end

  # Returns the total display width of inline virtual texts on a line.
  @spec inline_vt_width(Decorations.t(), non_neg_integer()) :: non_neg_integer()
  defp inline_vt_width(decorations, buf_line) do
    decorations
    |> Decorations.inline_virtual_texts_for_line(buf_line)
    |> Enum.reduce(0, fn vt, acc ->
      seg_width = Enum.reduce(vt.segments, 0, fn {text, _style}, w -> w + String.length(text) end)
      acc + seg_width
    end)
  end

  # Returns the total number of buffer columns hidden by conceals on a line.
  # This is the concealed width minus replacement width (0 or 1 per range).
  # Used by the wrap map to compensate: concealed text doesn't consume
  # display width, so the effective wrap width is larger than content_w.
  @spec conceal_hidden_width(Decorations.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp conceal_hidden_width(decorations, buf_line, line_len) do
    conceals = Decorations.conceals_for_line(decorations, buf_line)

    Enum.reduce(conceals, 0, fn conceal, acc ->
      concealed = ConcealRange.concealed_width_on_line(conceal, buf_line, line_len)
      replacement = ConcealRange.display_width(conceal)
      acc + max(concealed - replacement, 0)
    end)
  end

  defp clear_block_render_cache do
    Process.get_keys()
    |> Enum.each(fn
      {:block_render_cache, _} = key -> Process.delete(key)
      _ -> :ok
    end)
  end

  @spec fold_display_text(String.t(), term()) :: String.t()
  defp fold_display_text(text, :normal), do: text
  defp fold_display_text(text, {:fold_start, hidden}), do: text <> " ··· #{hidden} lines"

  defp fold_display_text(_text, {:decoration_fold, fold}) do
    hidden = FoldRegion.hidden_count(fold)
    " ··· #{hidden} lines"
  end

  defp fold_display_text(_text, {:virtual_line, _vt}), do: ""
  defp fold_display_text(_text, {:block, _, _}), do: ""

  @spec fold_gutter_indicator(term(), RenderPosition.t()) :: [DisplayList.draw()]
  defp fold_gutter_indicator({:fold_start, _}, %RenderPosition{} = pos) do
    [DisplayList.draw(pos.screen_row + pos.row_off, pos.col_off, "▸")]
  end

  defp fold_gutter_indicator(:normal, _pos), do: []

  defp fold_gutter_indicator({:decoration_fold, _}, %RenderPosition{} = pos) do
    [DisplayList.draw(pos.screen_row + pos.row_off, pos.col_off, "▸")]
  end

  defp fold_gutter_indicator({:virtual_line, _}, _pos), do: []
  defp fold_gutter_indicator({:block, _, _}, _pos), do: []

  @spec render_folded_line(
          Window.t(),
          non_neg_integer(),
          String.t(),
          :normal | {:fold_start, pos_integer()},
          non_neg_integer(),
          map(),
          {[DisplayList.draw()], [DisplayList.draw()]}
        ) :: {[DisplayList.draw()], [DisplayList.draw()], Window.t()}
  defp render_folded_line(win, buf_line, display_text, fold_info, screen_row, render_opts, {g, c}) do
    wrap_entry = Map.get(render_opts, :wrap_entry)

    if Window.dirty?(win, buf_line) do
      fold_pos = %RenderPosition{
        screen_row: screen_row,
        gutter_w: render_opts.gutter_w,
        row_off: render_opts.row_off,
        col_off: render_opts.col_off,
        content_w: render_opts.ctx.content_w
      }

      fold_g = fold_gutter_indicator(fold_info, fold_pos)

      {g_cmds, c_cmds, _rows} =
        BufferLine.render(%{
          line_text: display_text,
          buf_line: buf_line,
          cursor_line: render_opts.cursor_line,
          byte_offset: 0,
          screen_row: screen_row,
          ctx: render_opts.ctx,
          ln_style: render_opts.ln_style,
          gutter_w: render_opts.gutter_w,
          sign_w: render_opts.sign_w,
          wrap_entry: wrap_entry,
          max_rows: render_opts.max_rows,
          row_offset: render_opts.row_off,
          col_offset: render_opts.col_off
        })

      win = Window.cache_line(win, buf_line, fold_g ++ g_cmds, c_cmds)
      {(fold_g ++ g_cmds) ++ g, prepend_all(c, c_cmds), win}
    else
      g_cmds = Map.get(win.cached_gutter, buf_line, [])
      c_cmds = Map.get(win.cached_content, buf_line, [])
      {g_cmds ++ g, prepend_all(c, c_cmds), win}
    end
  end

  @doc "Renders lines with word wrapping."
  @spec render_lines_wrapped([String.t()], pos_integer(), line_render_opts()) ::
          {[DisplayList.draw()], [DisplayList.draw()], non_neg_integer()}
  def render_lines_wrapped(lines, max_rows, opts) do
    %{
      first_line: first_line,
      cursor_line: cursor_line,
      ctx: ctx,
      ln_style: ln_style,
      gutter_w: gutter_w,
      first_byte_off: first_byte_off,
      row_off: row_off,
      col_off: col_off
    } = opts

    breakindent = wrap_option(opts.buffer, :breakindent)
    linebreak = wrap_option(opts.buffer, :linebreak)

    wrap_map =
      WrapMap.compute(lines, ctx.content_w, breakindent: breakindent, linebreak: linebreak)

    sign_w = if ctx.has_sign_column, do: Gutter.sign_column_width(), else: 0

    {gutters, contents, screen_row, _byte_off} =
      lines
      |> Enum.with_index()
      |> Enum.zip(wrap_map)
      |> Enum.reduce_while(
        {[], [], 0, first_byte_off},
        fn {{line_text, line_idx}, visual_rows}, {g, c, sr, byte_off} ->
          {g2, c2, rows_used} =
            BufferLine.render(%{
              line_text: line_text,
              buf_line: first_line + line_idx,
              cursor_line: cursor_line,
              byte_offset: byte_off,
              screen_row: sr,
              ctx: ctx,
              ln_style: ln_style,
              gutter_w: gutter_w,
              sign_w: sign_w,
              wrap_entry: visual_rows,
              max_rows: max_rows,
              row_offset: row_off,
              col_offset: col_off
            })

          sr2 = sr + rows_used
          next_byte_off = byte_off + byte_size(line_text) + 1

          if sr2 >= max_rows do
            {:halt, {g2 ++ g, prepend_all(c, c2), sr2, next_byte_off}}
          else
            {:cont, {g2 ++ g, prepend_all(c, c2), sr2, next_byte_off}}
          end
        end
      )

    {Enum.reverse(gutters), Enum.reverse(contents), screen_row}
  end

  # Renders a virtual line entry (from DisplayMap) into draw commands.
  # Virtual lines have no buffer content; they render their styled segments
  # directly with no line number in the gutter.
  @spec render_virtual_line_entry(Decorations.VirtualText.t(), RenderPosition.t()) ::
          [DisplayList.draw()]
  defp render_virtual_line_entry(vt, pos) do
    render_styled_segments(vt.segments, pos)
  end

  @spec render_placeholder_segments([{String.t(), Face.t()}], RenderPosition.t()) ::
          [DisplayList.draw()]
  defp render_placeholder_segments(segments, pos) do
    render_styled_segments(segments, pos)
  end

  # Shared renderer for styled segments at a screen position.
  @spec render_styled_segments([{String.t(), Face.t()}], RenderPosition.t()) ::
          [DisplayList.draw()]
  defp render_styled_segments(segments, %RenderPosition{} = pos) do
    row = pos.screen_row + pos.row_off

    {draws, _col} =
      Enum.reduce(segments, {[], pos.gutter_w + pos.col_off}, fn {text, style}, {acc, col} ->
        width = Unicode.display_width(text)
        draw = DisplayList.draw(row, col, text, style)
        {[draw | acc], col + width}
      end)

    Enum.reverse(draws)
  end

  # Renders a single row of a block decoration by invoking its render callback
  # and extracting the line_idx-th row from the result.
  @spec render_block_entry(Decorations.BlockDecoration.t(), non_neg_integer(), RenderPosition.t()) ::
          [DisplayList.draw()]
  defp render_block_entry(block, line_idx, pos) do
    # Cache render callback result per block ID to avoid re-invoking
    # for each line_idx of a multi-line block.
    cache_key = {:block_render_cache, block.id}

    lines =
      case Process.get(cache_key) do
        nil ->
          result = block.render.(pos.content_w)
          normalized = Decorations.BlockDecoration.normalize_render_result(result)
          Process.put(cache_key, normalized)
          normalized

        cached ->
          cached
      end

    segments = Enum.at(lines, line_idx, [])
    row = pos.screen_row + pos.row_off

    {draws, _col} =
      Enum.reduce(segments, {[], pos.gutter_w + pos.col_off}, fn {text, style}, {acc, col} ->
        width = Unicode.display_width(text)
        draw = DisplayList.draw(row, col, text, style)
        {[draw | acc], col + width}
      end)

    Enum.reverse(draws)
  end

  @doc "Prepends draw commands to an accumulator."
  @spec prepend_all([DisplayList.draw()], [DisplayList.draw()]) :: [DisplayList.draw()]
  def prepend_all(acc, []), do: acc
  def prepend_all(acc, new_items), do: Enum.reduce(new_items, acc, fn item, a -> [item | a] end)

  # ── Window data ────────────────────────────────────────────────────────────

  # Adjusts visual selection display columns to account for inline virtual
  # text that displaces buffer content rightward.
  @spec adjust_selection_for_virtual_text(visual_selection(), Decorations.t()) ::
          visual_selection()
  defp adjust_selection_for_virtual_text(nil, _decs), do: nil
  defp adjust_selection_for_virtual_text({:line, _, _} = sel, _decs), do: sel

  defp adjust_selection_for_virtual_text({:char, {sl, sc}, {el, ec}}, decs) do
    {:char, {sl, Decorations.buf_col_to_display_col(decs, sl, sc)},
     {el, Decorations.buf_col_to_display_col(decs, el, ec)}}
  end

  # Converts search matches into highlight range decorations and merges
  # them into the decorations struct. Search highlights use a lower priority
  # than user decorations so they don't override intentional styling.
  # The current confirm match gets a different bg and higher priority.
  # Only rebuilds search decorations when the match set changes.
  # Uses a fingerprint of the matches to detect changes.
  @typedoc "Search decoration cache: {search_fingerprint, base_version, merged_decorations}"
  @type search_cache ::
          {term(), non_neg_integer(), Decorations.t()} | nil

  @doc """
  Merges search match highlights into a decorations struct, with caching.

  Returns `{merged_decorations, updated_cache}`. The cache is keyed on both
  the search fingerprint (matches + confirm) AND the base decoration version.
  When the base version changes (e.g., agent chat decorations updated between
  frames), the cache misses and search highlights are rebuilt on the fresh base.
  """
  @spec merge_search_decorations(
          Decorations.t(),
          [Minga.Search.Match.t()],
          Minga.Search.Match.t() | nil,
          map(),
          search_cache()
        ) :: {Decorations.t(), search_cache()}
  def merge_search_decorations(decs, matches, confirm_match, colors, cached) do
    fingerprint = {matches, confirm_match}

    case cached do
      {^fingerprint, base_version, cached_decs} when base_version == decs.version ->
        {cached_decs, cached}

      _ ->
        result = rebuild_search_decorations(decs, matches, confirm_match, colors)
        new_cache = {fingerprint, decs.version, result}
        {result, new_cache}
    end
  end

  defp maybe_update_search_decorations(decs, matches, confirm_match, colors) do
    cached = Process.get(:search_decoration_cache)
    {result, new_cache} = merge_search_decorations(decs, matches, confirm_match, colors, cached)
    Process.put(:search_decoration_cache, new_cache)
    result
  end

  defp rebuild_search_decorations(decs, [], _confirm, _colors) do
    Decorations.remove_group(decs, :search)
  end

  defp rebuild_search_decorations(decs, matches, confirm_match, colors) do
    Decorations.batch(decs, fn d ->
      d = Decorations.remove_group(d, :search)

      Enum.reduce(matches, d, fn match, acc ->
        add_search_highlight(acc, match, confirm_match, colors)
      end)
    end)
  end

  defp add_search_highlight(
         decs,
         %Minga.Search.Match{line: line, col: col, length: len} = match,
         confirm_match,
         colors
       ) do
    is_confirm = confirm_match != nil and match == confirm_match

    {style, priority} =
      if is_confirm do
        {Face.new(bg: colors.current_bg, fg: colors.highlight_fg), -5}
      else
        {Face.new(bg: colors.highlight_bg, fg: colors.highlight_fg), -10}
      end

    {_id, decs} =
      Decorations.add_highlight(decs, {line, col}, {line, col + len},
        style: style,
        priority: priority,
        group: :search
      )

    decs
  end

  # ── Document highlight decorations ──────────────────────────────────────────

  # Merges LSP document highlights into decorations with caching.
  # Uses a process-dictionary cache keyed on the highlight list and base
  # decorations version, matching the search highlight caching pattern.
  @spec merge_document_highlight_decorations(
          Decorations.t(),
          [Minga.LSP.DocumentHighlight.t()] | nil,
          Minga.Theme.t()
        ) :: Decorations.t()
  defp merge_document_highlight_decorations(decs, nil, _theme), do: decs
  defp merge_document_highlight_decorations(decs, [], _theme), do: decs

  defp merge_document_highlight_decorations(decs, highlights, theme) do
    cached = Process.get(:doc_highlight_cache)
    fingerprint = {highlights, decs.version}

    case cached do
      {^fingerprint, cached_decs} ->
        cached_decs

      _ ->
        result = rebuild_document_highlight_decorations(decs, highlights, theme)
        Process.put(:doc_highlight_cache, {fingerprint, result})
        result
    end
  end

  @spec rebuild_document_highlight_decorations(
          Decorations.t(),
          [Minga.LSP.DocumentHighlight.t()],
          Minga.Theme.t()
        ) :: Decorations.t()
  defp rebuild_document_highlight_decorations(decs, highlights, theme) do
    Decorations.batch(decs, fn d ->
      d = Decorations.remove_group(d, :document_highlight)

      Enum.reduce(highlights, d, fn hl, acc ->
        bg = document_highlight_bg(hl.kind, theme)
        style = Face.new(bg: bg)

        {_id, acc} =
          Decorations.add_highlight(acc, {hl.start_line, hl.start_col}, {hl.end_line, hl.end_col},
            style: style,
            priority: -15,
            group: :document_highlight
          )

        acc
      end)
    end)
  end

  # Resolve background color for document highlights from the theme.
  # Uses subtle, muted colors that are visible but don't compete with
  # search highlights (priority -10) or selection.
  @spec document_highlight_bg(Minga.LSP.DocumentHighlight.kind(), Minga.Theme.t()) ::
          Minga.Theme.color()
  defp document_highlight_bg(:write, _theme), do: 0x4A3F2B
  defp document_highlight_bg(_kind, _theme), do: 0x3A3F4B

  @doc "Returns the decorations for a window's buffer."
  @spec window_decorations(Window.t()) :: Decorations.t()
  def window_decorations(%{buffer: buf}) when is_pid(buf) do
    BufferServer.decorations(buf)
    |> Decorations.build_vt_line_cache()
  catch
    :exit, _ -> Decorations.new()
  end

  def window_decorations(_window), do: Decorations.new()

  @doc "Returns the highlight state for a window's buffer."
  @spec window_highlight(state(), Window.t()) :: Minga.Highlight.t() | nil
  def window_highlight(state, window) do
    hl =
      Map.get(state.highlight.highlights, window.buffer, Minga.Highlight.from_theme(state.theme))

    if hl.capture_names == {} do
      nil
    else
      apply_buffer_face_overrides(hl, window.buffer, state)
    end
  end

  # Applies buffer-local face overrides to the highlight's face registry.
  # Reads from the editor's pre-computed face_override_registries map,
  # which is updated via push from Buffer.Server when overrides change.
  # Zero GenServer calls on the render path.
  @spec apply_buffer_face_overrides(Highlight.t(), pid(), state()) :: Highlight.t()
  defp apply_buffer_face_overrides(hl, buf_pid, state) when is_pid(buf_pid) do
    case Map.get(state.face_override_registries, buf_pid) do
      nil -> hl
      registry -> %{hl | face_registry: registry}
    end
  end

  @doc "Returns git signs for a window's buffer."
  @spec git_signs_for_window(state(), Window.t()) :: %{non_neg_integer() => atom()}
  def git_signs_for_window(_state, %{buffer: buf}) when is_pid(buf) do
    case GitTracker.lookup(buf) do
      nil ->
        %{}

      git_pid ->
        try do
          GitBuffer.signs(git_pid)
        catch
          :exit, _ -> %{}
        end
    end
  end

  @doc "Returns diagnostic signs for a window's buffer."
  @spec diagnostic_signs_for_window(state(), Window.t()) :: %{non_neg_integer() => atom()}
  def diagnostic_signs_for_window(_state, %{buffer: buf}) when is_pid(buf) do
    case BufferServer.file_path(buf) do
      nil -> %{}
      path -> Diagnostics.severity_by_line(SyncServer.path_to_uri(path))
    end
  end

  # ── Visual selection ───────────────────────────────────────────────────────

  @doc "Computes visual selection bounds in display columns."
  @spec visual_selection_grapheme_bounds(
          state(),
          Document.position(),
          [String.t()],
          non_neg_integer()
        ) :: visual_selection()
  def visual_selection_grapheme_bounds(state, cursor, lines, first_line) do
    case visual_selection_bounds(state, cursor) do
      nil ->
        nil

      {:line, _, _} = sel ->
        sel

      {:char, {sl, sc}, {el, ec}} ->
        {
          :char,
          {sl, byte_col_to_display(lines, sl, sc, first_line)},
          {el, byte_col_to_display_end(lines, el, ec, first_line)}
        }
    end
  end

  @doc "Computes raw visual selection bounds (byte columns)."
  @spec visual_selection_bounds(state(), Document.position()) :: visual_selection()
  def visual_selection_bounds(%{vim: %{mode: :visual, mode_state: %VisualState{} = ms}}, cursor) do
    anchor = ms.visual_anchor
    visual_type = ms.visual_type

    case visual_type do
      :char ->
        {start_pos, end_pos} = sort_positions(anchor, cursor)
        {:char, start_pos, end_pos}

      :line ->
        {anchor_line, _} = anchor
        {cursor_line, _} = cursor
        {:line, min(anchor_line, cursor_line), max(anchor_line, cursor_line)}
    end
  end

  def visual_selection_bounds(_state, _cursor), do: nil

  # ── Context fingerprint ─────────────────────────────────────────────────────

  @doc "Computes a fingerprint from the render context for change detection."
  @spec context_fingerprint(Context.t(), boolean()) :: Window.context_fingerprint()
  def context_fingerprint(%Context{} = ctx, is_active) do
    hl_id =
      case ctx.highlight do
        nil -> nil
        hl -> hl.version
      end

    {
      ctx.visual_selection,
      ctx.search_matches,
      hl_id,
      ctx.diagnostic_signs,
      ctx.git_signs,
      ctx.viewport.left,
      ctx.viewport.cols,
      ctx.content_w,
      is_active,
      ctx.confirm_match,
      ctx.decorations.version
    }
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec wrap_option(pid(), atom()) :: boolean()
  defp wrap_option(buf, name) do
    BufferServer.get_option(buf, name)
  catch
    :exit, _ -> true
  end

  @spec byte_col_to_display(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp byte_col_to_display(lines, line, byte_col, first_line) do
    line_text = cursor_line_text(lines, line, first_line)
    Unicode.display_col(line_text, byte_col)
  end

  @spec byte_col_to_display_end(
          [String.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp byte_col_to_display_end(lines, line, byte_col, first_line) do
    line_text = cursor_line_text(lines, line, first_line)
    next_byte = Unicode.next_grapheme_byte_offset(line_text, byte_col)
    Unicode.display_col(line_text, next_byte)
  end

  @spec sort_positions(Document.position(), Document.position()) ::
          {Document.position(), Document.position()}
  defp sort_positions({l1, c1} = p1, {l2, c2} = p2) do
    if {l1, c1} <= {l2, c2}, do: {p1, p2}, else: {p2, p1}
  end

  @spec cursor_line_text([String.t()], non_neg_integer(), non_neg_integer()) :: String.t()
  defp cursor_line_text(lines, cursor_line, first_line) do
    index = cursor_line - first_line

    if index >= 0 and index < length(lines) do
      Enum.at(lines, index)
    else
      ""
    end
  end

  # Build {line_text, byte_offset} tuples for batch highlight computation.
  @spec build_lines_with_offsets([String.t()], non_neg_integer()) ::
          [{String.t(), non_neg_integer()}]
  defp build_lines_with_offsets(lines, first_byte_off) do
    {pairs_rev, _} =
      Enum.reduce(lines, {[], first_byte_off}, fn line, {acc, off} ->
        {[{line, off} | acc], off + byte_size(line) + 1}
      end)

    Enum.reverse(pairs_rev)
  end
end
