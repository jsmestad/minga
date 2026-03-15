defmodule Minga.Editor.Renderer.BufferLine do
  @moduledoc """
  Single entry point for rendering a buffer line to screen rows.

  Every code path that draws buffer content (single-buffer, word-wrap,
  split-window) goes through `render/2`. This guarantees that gutter
  signs, line numbers, syntax highlighting, search highlights, and
  visual selections are always present, regardless of rendering mode.

  ## Rendering modes

  Without a wrap entry, one logical line produces one screen row.
  With a wrap entry, one logical line produces N visual rows. Each
  visual row passes through `LineRenderer.render` with a per-row
  context where `viewport.left` is set to the visual row's display
  column offset, reusing the existing horizontal-scroll clipping.

  All render functions return `DisplayList.draw()` tuples.
  """

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Unicode
  alias Minga.Editor.DisplayList
  alias Minga.Editor.NavFlash
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.Gutter
  alias Minga.Editor.Renderer.Line, as: LineRenderer
  alias Minga.Editor.WrapMap

  @typedoc """
  Per-line values that vary across lines in a render pass.

  - `line_text`     — full logical line text
  - `buf_line`      — 0-indexed buffer line number
  - `cursor_line`   — buffer line the cursor is on (for relative numbers)
  - `byte_offset`   — absolute byte offset of this line in the buffer
  - `screen_row`    — first screen row to draw on
  - `ctx`           — per-frame render context (viewport, highlights, etc.)
  - `ln_style`      — line number display style
  - `gutter_w`      — total gutter width (sign column + line numbers)
  - `sign_w`        — sign column width (0 when no diagnostics)
  - `wrap_entry`    — nil for nowrap; list of visual rows for wrapped lines
  - `max_rows`      — maximum screen rows available (prevents overflow into modeline)
  - `row_offset`    — row shift for split windows (0 for single buffer)
  - `col_offset`    — column shift for split windows (0 for single buffer)
  """
  @type line_params :: %{
          line_text: String.t(),
          buf_line: non_neg_integer(),
          cursor_line: non_neg_integer(),
          byte_offset: non_neg_integer(),
          screen_row: non_neg_integer(),
          ctx: Context.t(),
          ln_style: Gutter.line_number_style(),
          gutter_w: non_neg_integer(),
          sign_w: non_neg_integer(),
          wrap_entry: WrapMap.wrap_entry() | nil,
          max_rows: pos_integer(),
          row_offset: non_neg_integer(),
          col_offset: non_neg_integer()
        }

  @doc """
  Renders one logical buffer line to screen rows.

  Returns `{gutter_draws, content_draws, rows_consumed}`.
  For non-wrapped lines, `rows_consumed` is always 1. For wrapped
  lines, it equals the number of visual rows produced.

  All draws are `DisplayList.draw()` tuples.
  """
  @spec render(line_params()) :: {[DisplayList.draw()], [DisplayList.draw()], pos_integer()}
  def render(%{wrap_entry: nil} = p) do
    {g_cmds, c_cmds} = render_single_row(p)
    {g_cmds, c_cmds, 1}
  end

  def render(%{wrap_entry: visual_rows} = p) do
    render_wrapped_rows(p, visual_rows)
  end

  # ── Single row (no wrap) ─────────────────────────────────────────────────

  @spec render_single_row(line_params()) ::
          {[DisplayList.draw()], [DisplayList.draw()]}
  defp render_single_row(p) do
    sr = p.screen_row

    sign_cmd = render_sign(p, sr)
    gutter_cmd = render_number(p, sr)

    content_cmds =
      LineRenderer.render(p.line_text, sr, p.buf_line, p.ctx, p.byte_offset)

    content_cmds = maybe_apply_cursorline(content_cmds, sr, p)
    content_cmds = maybe_apply_decoration_bg(content_cmds, sr, p)

    gutters = build_gutter_list(sign_cmd, gutter_cmd, p.row_offset, p.col_offset)
    contents = maybe_offset(content_cmds, p.row_offset, p.col_offset)
    {gutters, contents}
  end

  # ── Wrapped rows ─────────────────────────────────────────────────────────

  @spec render_wrapped_rows(line_params(), WrapMap.wrap_entry()) ::
          {[DisplayList.draw()], [DisplayList.draw()], pos_integer()}
  defp render_wrapped_rows(p, visual_rows) do
    {g_acc, c_acc, sr} =
      Enum.reduce_while(visual_rows, {[], [], p.screen_row}, fn vrow, {g, c, sr} ->
        if sr >= p.max_rows do
          {:halt, {g, c, sr}}
        else
          is_first = sr == p.screen_row
          {g_cmds, c_cmds} = render_visual_row(p, vrow, sr, is_first)
          {:cont, {prepend_all(g, g_cmds), prepend_all(c, c_cmds), sr + 1}}
        end
      end)

    {Enum.reverse(g_acc), Enum.reverse(c_acc), sr - p.screen_row}
  end

  @spec render_visual_row(line_params(), WrapMap.visual_row(), non_neg_integer(), boolean()) ::
          {[DisplayList.draw()], [DisplayList.draw()]}
  defp render_visual_row(p, vrow, sr, is_first) do
    # Gutter: sign + number on first row; blank gutter on continuations.
    sign_cmd = if is_first, do: render_sign(p, sr), else: []
    gutter_cmd = if is_first, do: render_number(p, sr), else: render_blank_gutter(p, sr)

    # Content: slide the viewport window to this visual row's column range.
    vrow_display_off = Unicode.display_col(p.line_text, vrow.byte_offset)
    vrow_display_w = Unicode.display_width(vrow.text)
    vrow_viewport = %{p.ctx.viewport | left: vrow_display_off}
    vrow_ctx = %{p.ctx | viewport: vrow_viewport, content_w: vrow_display_w}

    content_cmds = LineRenderer.render(p.line_text, sr, p.buf_line, vrow_ctx, p.byte_offset)
    content_cmds = maybe_apply_cursorline(content_cmds, sr, p)
    content_cmds = maybe_apply_decoration_bg(content_cmds, sr, p)

    gutters = build_gutter_list(sign_cmd, gutter_cmd, p.row_offset, p.col_offset)
    contents = maybe_offset(content_cmds, p.row_offset, p.col_offset)
    {gutters, contents}
  end

  # ── Cursorline & Nav-flash ─────────────────────────────────────────────────

  # Applies cursorline or nav-flash background to content draws.
  #
  # For the cursor line: uses cursorline_bg (or nav-flash interpolated color
  # if a flash is active on this line). For non-cursor lines: applies
  # nav-flash bg if the flash targets this line (can happen briefly when
  # the cursor has moved but the flash line hasn't caught up).
  #
  # Prepends a full-width fill draw so the tint extends past the text,
  # then sets bg on each content draw that doesn't already have an explicit
  # bg or :reverse (visual selections keep their own colors).
  @spec maybe_apply_cursorline([DisplayList.draw()], non_neg_integer(), line_params()) ::
          [DisplayList.draw()]
  defp maybe_apply_cursorline(cmds, sr, p) do
    bg = resolve_line_bg(p)

    if bg do
      apply_line_bg(cmds, sr, bg, p.ctx)
    else
      cmds
    end
  end

  # Determines the effective background color for this line, considering
  # both cursorline and nav-flash state.
  @spec resolve_line_bg(line_params()) :: non_neg_integer() | nil
  defp resolve_line_bg(%{buf_line: bl, cursor_line: cl, ctx: ctx}) do
    effective_bg(nav_flash_bg_for_line(bl, ctx), bl, cl, ctx)
  end

  @spec effective_bg(non_neg_integer() | nil, non_neg_integer(), non_neg_integer(), Context.t()) ::
          non_neg_integer() | nil
  # Nav-flash overrides cursorline on the flash line
  defp effective_bg(flash_bg, _bl, _cl, _ctx) when is_integer(flash_bg), do: flash_bg
  # Normal cursorline for cursor line
  defp effective_bg(nil, bl, cl, ctx) when bl == cl, do: ctx.cursorline_bg
  # No highlight for other lines
  defp effective_bg(nil, _bl, _cl, _ctx), do: nil

  # Returns the interpolated flash bg if a flash is active on this line.
  @spec nav_flash_bg_for_line(non_neg_integer(), Context.t()) :: non_neg_integer() | nil
  defp nav_flash_bg_for_line(_buf_line, %{nav_flash: nil}), do: nil

  defp nav_flash_bg_for_line(buf_line, %{nav_flash: %NavFlash{line: flash_line} = flash} = ctx)
       when buf_line == flash_line do
    flash_bg = ctx_nav_flash_bg(ctx)
    target_bg = ctx.cursorline_bg || ctx_editor_bg(ctx)

    if flash_bg do
      NavFlash.color_for_step(flash, flash_bg, target_bg)
    else
      nil
    end
  end

  defp nav_flash_bg_for_line(_buf_line, _ctx), do: nil

  @spec ctx_nav_flash_bg(Context.t()) :: non_neg_integer() | nil
  defp ctx_nav_flash_bg(%{nav_flash_bg: bg}), do: bg

  @spec ctx_editor_bg(Context.t()) :: non_neg_integer()
  defp ctx_editor_bg(%{editor_bg: bg}), do: bg

  @spec apply_line_bg([DisplayList.draw()], non_neg_integer(), non_neg_integer(), Context.t()) ::
          [DisplayList.draw()]
  defp apply_line_bg(cmds, sr, bg, ctx) do
    fill = DisplayList.draw(sr, ctx.gutter_w, String.duplicate(" ", ctx.content_w), bg: bg)

    tinted =
      Enum.map(cmds, fn {row, col, text, style} ->
        if Keyword.has_key?(style, :bg) or Keyword.has_key?(style, :reverse) do
          {row, col, text, style}
        else
          {row, col, text, Keyword.put(style, :bg, bg)}
        end
      end)

    [fill | tinted]
  end

  # Applies full-width background fill when the line has a decoration
  # highlight with a bg color. Without this, decoration bg only colors
  # existing text characters, not the full terminal width.
  @spec maybe_apply_decoration_bg([DisplayList.draw()], non_neg_integer(), line_params()) ::
          [DisplayList.draw()]
  defp maybe_apply_decoration_bg(cmds, sr, p) do
    bg = decoration_line_bg(p.ctx.decorations, p.buf_line)

    if bg do
      apply_line_bg(cmds, sr, bg, p.ctx)
    else
      cmds
    end
  end

  defp decoration_line_bg(decorations, buf_line) do
    decorations
    |> Decorations.highlights_for_line(buf_line)
    |> Enum.find_value(fn hl ->
      bg = Keyword.get(hl.style, :bg)
      if bg && hl.start == {buf_line, 0}, do: bg, else: nil
    end)
  end

  # ── Gutter primitives ───────────────────────────────────────────────────

  @spec render_sign(line_params(), non_neg_integer()) :: DisplayList.draw() | []
  defp render_sign(%{ctx: ctx, buf_line: buf_line}, sr) do
    if ctx.has_sign_column do
      Gutter.render_sign(
        sr,
        0,
        buf_line,
        ctx.diagnostic_signs,
        ctx.git_signs,
        ctx.gutter_colors,
        ctx.git_colors
      )
    else
      []
    end
  end

  @spec render_number(line_params(), non_neg_integer()) :: DisplayList.draw() | []
  defp render_number(p, sr) do
    Gutter.render_number(
      sr,
      p.sign_w,
      p.buf_line,
      p.cursor_line,
      p.gutter_w - p.sign_w,
      p.ln_style,
      p.ctx.gutter_colors
    )
  end

  @spec render_blank_gutter(line_params(), non_neg_integer()) :: DisplayList.draw()
  defp render_blank_gutter(p, sr) do
    DisplayList.draw(sr, p.sign_w, String.duplicate(" ", max(p.gutter_w - p.sign_w, 0)),
      fg: p.ctx.gutter_colors.fg
    )
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec build_gutter_list(
          DisplayList.draw() | [],
          DisplayList.draw() | [],
          non_neg_integer(),
          non_neg_integer()
        ) :: [DisplayList.draw()]
  defp build_gutter_list(sign_cmd, gutter_cmd, row_off, col_off) do
    cmds =
      []
      |> prepend_if(sign_cmd)
      |> prepend_if(gutter_cmd)

    maybe_offset(cmds, row_off, col_off)
  end

  @spec maybe_offset([DisplayList.draw()], non_neg_integer(), non_neg_integer()) ::
          [DisplayList.draw()]
  defp maybe_offset(cmds, 0, 0), do: cmds

  defp maybe_offset(cmds, row_off, col_off) do
    Enum.map(cmds, fn {row, col, text, style} ->
      {row + row_off, col + col_off, text, style}
    end)
  end

  @spec prepend_if([DisplayList.draw()], DisplayList.draw() | []) :: [DisplayList.draw()]
  defp prepend_if(list, []), do: list
  defp prepend_if(list, cmd) when is_tuple(cmd), do: [cmd | list]

  @spec prepend_all([DisplayList.draw()], [DisplayList.draw()]) :: [DisplayList.draw()]
  defp prepend_all(acc, []), do: acc
  defp prepend_all(acc, items), do: Enum.reduce(items, acc, fn item, a -> [item | a] end)
end
