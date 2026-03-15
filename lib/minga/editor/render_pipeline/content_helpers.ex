defmodule Minga.Editor.RenderPipeline.ContentHelpers do
  @moduledoc """
  Helper functions for the Content stage of the render pipeline.

  Builds render contexts, renders lines (wrapped and nowrapped),
  computes visual selection bounds, and resolves window-local
  highlight/sign data.

  Extracted from `RenderPipeline` to reduce module size.
  """

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Decorations.FoldRegion
  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Buffer.Unicode
  alias Minga.Config.Options
  alias Minga.Diagnostics
  alias Minga.Editor.DisplayList
  alias Minga.Editor.DocumentSync
  alias Minga.Editor.Renderer.BufferLine
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.Gutter
  alias Minga.Editor.Renderer.SearchHighlight
  alias Minga.Editor.RenderPosition
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Window
  alias Minga.Editor.WrapMap
  alias Minga.Git.Buffer, as: GitBuffer
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

    cursorline_bg =
      if is_active and Options.get(:cursorline) do
        state.theme.editor.cursorline_bg
      else
        nil
      end

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

    {gutters, contents_rev, _byte_off, window} =
      lines
      |> Enum.with_index()
      |> Enum.reduce(
        {[], [], first_byte_off, window},
        fn {line_text, screen_row}, {g, c, byte_off, win} ->
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
                col_offset: col_off
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
    max_rows = length(visible_line_map)

    {gutters, contents_rev, window} =
      visible_line_map
      |> Enum.with_index()
      |> Enum.reduce({[], [], window}, fn {{buf_line, fold_info}, screen_row}, {g, c, win} ->
        case fold_info do
          {:virtual_line, vt} ->
            # Virtual lines render their own styled segments, no buffer content
            render_pos = %RenderPosition{
              screen_row: screen_row,
              gutter_w: gutter_w,
              row_off: row_off,
              col_off: col_off,
              content_w: ctx.content_w
            }

            c_cmds = render_virtual_line_entry(vt, render_pos)
            {g, prepend_all(c, c_cmds), win}

          {:block, block, line_idx} ->
            render_pos = %RenderPosition{
              screen_row: screen_row,
              gutter_w: gutter_w,
              row_off: row_off,
              col_off: col_off,
              content_w: ctx.content_w
            }

            c_cmds = render_block_entry(block, line_idx, render_pos)
            {g, prepend_all(c, c_cmds), win}

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
            {fold_g ++ g, prepend_all(c, c_cmds), win}

          _ ->
            line_index = buf_line - first_line
            line_text = Enum.at(lines, line_index, "")
            display_text = fold_display_text(line_text, fold_info)

            render_folded_line(
              win,
              buf_line,
              display_text,
              fold_info,
              screen_row,
              %{
                cursor_line: cursor_line,
                ctx: ctx,
                ln_style: ln_style,
                gutter_w: gutter_w,
                sign_w: sign_w,
                max_rows: max_rows,
                row_off: row_off,
                col_off: col_off
              },
              {g, c}
            )
        end
      end)

    # Clean up per-frame block render cache from process dictionary
    clear_block_render_cache()

    {Enum.reverse(gutters), Enum.reverse(contents_rev), length(visible_line_map), window}
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
          wrap_entry: nil,
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

  @spec render_placeholder_segments([{String.t(), keyword()}], RenderPosition.t()) ::
          [DisplayList.draw()]
  defp render_placeholder_segments(segments, pos) do
    render_styled_segments(segments, pos)
  end

  # Shared renderer for styled segments at a screen position.
  @spec render_styled_segments([{String.t(), keyword()}], RenderPosition.t()) ::
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
  defp maybe_update_search_decorations(decs, matches, confirm_match, colors) do
    fingerprint = {matches, confirm_match}
    cached = Process.get(:search_decoration_cache)

    case cached do
      {^fingerprint, cached_decs} ->
        # Same matches as last frame: reuse the merged decorations, but
        # update the base version to match the fresh buffer decorations
        %{cached_decs | version: decs.version + 1}

      _ ->
        result = rebuild_search_decorations(decs, matches, confirm_match, colors)
        Process.put(:search_decoration_cache, {fingerprint, result})
        result
    end
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
        {[bg: colors.current_bg, fg: colors.highlight_fg], -5}
      else
        {[bg: colors.highlight_bg, fg: colors.highlight_fg], -10}
      end

    {_id, decs} =
      Decorations.add_highlight(decs, {line, col}, {line, col + len},
        style: style,
        priority: priority,
        group: :search
      )

    decs
  end

  @doc "Returns the decorations for a window's buffer."
  @spec window_decorations(Window.t()) :: Decorations.t()
  def window_decorations(%{buffer: buf}) when is_pid(buf) do
    if Process.alive?(buf) do
      BufferServer.decorations(buf)
    else
      Decorations.new()
    end
  catch
    :exit, _ -> Decorations.new()
  end

  def window_decorations(_window), do: Decorations.new()

  @doc "Returns the highlight state for a window's buffer."
  @spec window_highlight(state(), Window.t()) :: Minga.Highlight.t() | nil
  def window_highlight(state, window) do
    hl =
      if window.buffer == state.buffers.active do
        state.highlight.current
      else
        Map.get(state.highlight.cache, window.buffer, Minga.Highlight.from_theme(state.theme))
      end

    if hl.capture_names != [], do: hl, else: nil
  end

  @doc "Returns git signs for a window's buffer."
  @spec git_signs_for_window(state(), Window.t()) :: %{non_neg_integer() => atom()}
  def git_signs_for_window(%{git_buffers: git_buffers}, %{buffer: buf}) when is_pid(buf) do
    case Map.get(git_buffers, buf) do
      nil -> %{}
      git_pid -> if Process.alive?(git_pid), do: GitBuffer.signs(git_pid), else: %{}
    end
  end

  @doc "Returns diagnostic signs for a window's buffer."
  @spec diagnostic_signs_for_window(state(), Window.t()) :: %{non_neg_integer() => atom()}
  def diagnostic_signs_for_window(_state, %{buffer: buf}) when is_pid(buf) do
    case BufferServer.file_path(buf) do
      nil -> %{}
      path -> Diagnostics.severity_by_line(DocumentSync.path_to_uri(path))
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
end
