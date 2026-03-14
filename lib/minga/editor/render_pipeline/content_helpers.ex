defmodule Minga.Editor.RenderPipeline.ContentHelpers do
  @moduledoc """
  Helper functions for the Content stage of the render pipeline.

  Builds render contexts, renders lines (wrapped and nowrapped),
  computes visual selection bounds, and resolves window-local
  highlight/sign data.

  Extracted from `RenderPipeline` to reduce module size.
  """

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

  @typedoc """
  Visual selection bounds for rendering.
  """
  @type visual_selection ::
          nil
          | {:char, {non_neg_integer(), non_neg_integer()},
             {non_neg_integer(), non_neg_integer()}}
          | {:line, non_neg_integer(), non_neg_integer()}

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

    visual_selection =
      if is_active do
        visual_selection_grapheme_bounds(state, cursor, lines, first_line)
      else
        nil
      end

    search_matches =
      case preview_matches do
        [] -> SearchHighlight.search_matches_for_lines(state, lines, first_line)
        _ -> preview_matches
      end

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
      confirm_match: if(is_active, do: SearchHighlight.current_confirm_match(state), else: nil),
      highlight: window_highlight(state, window),
      cursorline_bg: cursorline_bg,
      has_sign_column: has_sign_column,
      diagnostic_signs: diagnostic_signs_for_window(state, window),
      git_signs: git_signs_for_window(state, window),
      search_colors: state.theme.search,
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
      end)

    {Enum.reverse(gutters), Enum.reverse(contents_rev), length(visible_line_map), window}
  end

  @spec fold_display_text(String.t(), :normal | {:fold_start, pos_integer()}) :: String.t()
  defp fold_display_text(text, :normal), do: text
  defp fold_display_text(text, {:fold_start, hidden}), do: text <> " ··· #{hidden} lines"

  @spec fold_gutter_indicator(
          :normal | {:fold_start, pos_integer()},
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          [DisplayList.draw()]
  defp fold_gutter_indicator({:fold_start, _}, screen_row, row_off, col_off) do
    [DisplayList.draw(screen_row + row_off, col_off, "▸")]
  end

  defp fold_gutter_indicator(:normal, _screen_row, _row_off, _col_off), do: []

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
      fold_g =
        fold_gutter_indicator(fold_info, screen_row, render_opts.row_off, render_opts.col_off)

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

  @doc "Prepends draw commands to an accumulator."
  @spec prepend_all([DisplayList.draw()], [DisplayList.draw()]) :: [DisplayList.draw()]
  def prepend_all(acc, []), do: acc
  def prepend_all(acc, new_items), do: Enum.reduce(new_items, acc, fn item, a -> [item | a] end)

  # ── Window data ────────────────────────────────────────────────────────────

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
      ctx.confirm_match
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
