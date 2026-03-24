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
  alias Minga.Face
  alias Minga.Highlight

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
          required(:line_text) => String.t(),
          required(:buf_line) => non_neg_integer(),
          required(:cursor_line) => non_neg_integer(),
          required(:byte_offset) => non_neg_integer(),
          required(:screen_row) => non_neg_integer(),
          required(:ctx) => Context.t(),
          required(:ln_style) => Gutter.line_number_style(),
          required(:gutter_w) => non_neg_integer(),
          required(:sign_w) => non_neg_integer(),
          required(:wrap_entry) => WrapMap.wrap_entry() | nil,
          required(:max_rows) => pos_integer(),
          required(:row_offset) => non_neg_integer(),
          required(:col_offset) => non_neg_integer(),
          optional(:highlight_segments) => [Highlight.styled_segment()] | nil
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

    # On the cursor line, reveal concealed text (Neovim concealcursor behavior).
    # This lets the user see raw delimiters when the cursor is on the line.
    ctx = maybe_reveal_conceals(p.ctx, p.buf_line, p.cursor_line)

    content_cmds =
      LineRenderer.render(
        p.line_text,
        sr,
        p.buf_line,
        ctx,
        p.byte_offset,
        Map.get(p, :highlight_segments)
      )

    content_cmds = maybe_apply_cursorline(content_cmds, sr, p)
    content_cmds = maybe_apply_decoration_bg(content_cmds, sr, p)
    content_cmds = overlay_decoration_styles(content_cmds, sr, p)

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
    #
    # When inline VTs exist (e.g., "▎ " border), we strip them from the
    # decorations so Line.render works in pure text coordinates. The border
    # is drawn directly and text shifted rightward. This avoids coordinate
    # mismatches between WrapMap (text-only) and the segment pipeline.
    vrow_display_off = Unicode.display_col(p.line_text, vrow.byte_offset)
    vrow_display_w = Unicode.display_width(vrow.text)
    vt_w = inline_vt_display_width(p.ctx.decorations, p.buf_line)

    vrow_viewport = %{p.ctx.viewport | left: vrow_display_off}

    vrow_ctx =
      if vt_w > 0 do
        stripped = strip_inline_vts(p.ctx.decorations, p.buf_line)
        %{p.ctx | viewport: vrow_viewport, content_w: vrow_display_w, decorations: stripped}
      else
        %{p.ctx | viewport: vrow_viewport, content_w: vrow_display_w}
      end

    content_cmds = LineRenderer.render(p.line_text, sr, p.buf_line, vrow_ctx, p.byte_offset)
    content_cmds = maybe_apply_cursorline(content_cmds, sr, p)
    content_cmds = maybe_apply_decoration_bg(content_cmds, sr, p)
    content_cmds = overlay_decoration_styles(content_cmds, sr, p)

    # Draw the border and shift text rightward to make room.
    content_cmds =
      if vt_w > 0 do
        shifted =
          Enum.map(content_cmds, fn {row, col, text, style} -> {row, col + vt_w, text, style} end)

        inline_vt_border_draw(p.ctx.decorations, p.buf_line, sr) ++ shifted
      else
        content_cmds
      end

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
    default_bg = ctx.editor_bg

    tinted =
      Enum.map(cmds, fn {row, col, text, %Face{} = face} ->
        if (face.bg != nil and face.bg != default_bg) or face.reverse do
          {row, col, text, face}
        else
          {row, col, text, %{face | bg: bg}}
        end
      end)

    # GUI frontends draw the cursorline bg natively as a Metal quad.
    # Skip the full-width space fill draw that the TUI needs for bg painting.
    if ctx.is_gui do
      tinted
    else
      fill =
        DisplayList.draw(sr, ctx.gutter_w, String.duplicate(" ", ctx.content_w), Face.new(bg: bg))

      [fill | tinted]
    end
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
      bg = hl.style.bg
      if bg && hl.start == {buf_line, 0}, do: bg, else: nil
    end)
  end

  # Overlays decoration highlight range styles (underlines, strikethrough, etc.)
  # onto content draws. Splits draws at decoration range boundaries and merges
  # the decoration's style properties. This is how diagnostic underlines appear
  # on top of syntax-highlighted text.
  @spec overlay_decoration_styles([DisplayList.draw()], non_neg_integer(), line_params()) ::
          [DisplayList.draw()]
  defp overlay_decoration_styles(cmds, _sr, p) do
    ranges = Decorations.highlights_for_line(p.ctx.decorations, p.buf_line)

    # Filter to ranges that have non-bg style attributes (underline, strikethrough, etc.)
    overlay_ranges =
      Enum.filter(ranges, fn hl ->
        face = hl.style

        face.underline != nil or
          face.underline_color != nil or
          face.underline_style != nil or
          face.strikethrough != nil or
          face.blend != nil
      end)

    if overlay_ranges == [] do
      cmds
    else
      apply_overlays(cmds, overlay_ranges, p.buf_line)
    end
  end

  @spec apply_overlays([DisplayList.draw()], [term()], non_neg_integer()) ::
          [DisplayList.draw()]
  defp apply_overlays(cmds, overlay_ranges, buf_line) do
    Enum.flat_map(cmds, fn {row, col, text, style} = cmd ->
      overlapping =
        Enum.filter(overlay_ranges, fn hl ->
          range_overlaps_draw?(hl, buf_line, col, col + display_width(text))
        end)

      if overlapping == [] do
        [cmd]
      else
        split_and_merge(row, col, text, style, overlapping, buf_line)
      end
    end)
  end

  # Check if a highlight range overlaps a draw command's column span.
  @spec range_overlaps_draw?(
          Minga.Buffer.Decorations.HighlightRange.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: boolean()
  defp range_overlaps_draw?(hl, buf_line, draw_start_col, draw_end_col) do
    {hl_start_line, hl_start_col} = hl.start
    {hl_end_line, hl_end_col} = hl.end_

    # Range starts before or on this line, and ends on or after this line
    starts_before_end =
      hl_start_line < buf_line or (hl_start_line == buf_line and hl_start_col < draw_end_col)

    ends_after_start =
      hl_end_line > buf_line or (hl_end_line == buf_line and hl_end_col > draw_start_col)

    starts_before_end and ends_after_start
  end

  # Split a draw command at decoration range boundaries and merge
  # each segment with the appropriate decoration's style.
  @spec split_and_merge(
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          Face.t(),
          [Minga.Buffer.Decorations.HighlightRange.t()],
          non_neg_integer()
        ) :: [DisplayList.draw()]
  defp split_and_merge(row, col, text, base_style, ranges, buf_line) do
    draw_end = col + display_width(text)

    # Collect boundary columns from all overlapping ranges
    boundaries =
      ranges
      |> Enum.flat_map(fn hl ->
        {sl, sc} = hl.start
        {el, ec} = hl.end_
        start_c = if sl < buf_line, do: col, else: max(sc, col)
        end_c = if el > buf_line, do: draw_end, else: min(ec, draw_end)
        [start_c, end_c]
      end)
      |> Enum.concat([col, draw_end])
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.filter(&(&1 >= col and &1 <= draw_end))

    # Build a segment for each consecutive boundary pair
    boundaries
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [seg_start, seg_end] ->
      build_split_segment(row, col, text, base_style, ranges, buf_line, seg_start, seg_end)
    end)
  end

  @spec build_split_segment(
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          Face.t(),
          [Minga.Buffer.Decorations.HighlightRange.t()],
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: [DisplayList.draw()]
  defp build_split_segment(_row, _col, _text, _base_style, _ranges, _buf_line, s, e) when s >= e,
    do: []

  defp build_split_segment(row, col, text, base_style, ranges, buf_line, seg_start, seg_end) do
    seg_text = slice_by_display_width(text, seg_start - col, seg_end - seg_start)

    if seg_text == "" do
      []
    else
      covering =
        Enum.filter(ranges, fn hl ->
          {sl, sc} = hl.start
          {el, ec} = hl.end_
          after_start = sl < buf_line or (sl == buf_line and sc <= seg_start)
          before_end = el > buf_line or (el == buf_line and ec > seg_start)
          after_start and before_end
        end)

      style =
        case covering do
          [] ->
            base_style

          _ ->
            best = Enum.max_by(covering, & &1.priority)
            merge_overlay_style(base_style, best.style)
        end

      [{row, seg_start, seg_text, style}]
    end
  end

  # Slice text by display width offset and length.
  @spec slice_by_display_width(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  defp slice_by_display_width(text, offset, length) do
    {_, _, result} =
      text
      |> String.graphemes()
      |> Enum.reduce({0, 0, []}, fn grapheme, {pos, collected, acc} ->
        w = Unicode.display_width(grapheme)

        cond do
          pos + w <= offset -> {pos + w, collected, acc}
          collected >= length -> {pos + w, collected, acc}
          true -> {pos + w, collected + w, [grapheme | acc]}
        end
      end)

    result |> Enum.reverse() |> Enum.join()
  end

  # Merges overlay decoration style attributes onto a base face.
  # Only merges decorative attributes (underline, strikethrough, blend).
  # Does NOT override fg/bg from the decoration (preserves syntax colors).
  @spec merge_overlay_style(Face.t(), Face.t()) :: Face.t()
  defp merge_overlay_style(%Face{} = base, %Face{} = overlay) do
    base
    |> merge_face_field(:underline, overlay)
    |> merge_face_field(:underline_color, overlay)
    |> merge_face_field(:underline_style, overlay)
    |> merge_face_field(:strikethrough, overlay)
    |> merge_face_field(:blend, overlay)
  end

  @spec merge_face_field(Face.t(), atom(), Face.t()) :: Face.t()
  defp merge_face_field(base, key, overlay) do
    case Map.get(overlay, key) do
      nil -> base
      value -> Map.put(base, key, value)
    end
  end

  @spec display_width(String.t()) :: non_neg_integer()
  defp display_width(text), do: Unicode.display_width(text)

  # Removes inline virtual texts for a specific line from the decorations.
  # Used during wrapped rendering to prevent the VT from interfering with
  # the segment pipeline's coordinate system.
  @spec strip_inline_vts(Decorations.t(), non_neg_integer()) :: Decorations.t()
  defp strip_inline_vts(%Decorations{virtual_texts: vts} = decs, buf_line) do
    filtered =
      Enum.reject(vts, fn vt ->
        vt.placement == :inline and match?({^buf_line, _}, vt.anchor)
      end)

    %{decs | virtual_texts: filtered}
  end

  # Renders inline VT border as direct draw commands for continuation rows.
  @spec inline_vt_border_draw(Decorations.t(), non_neg_integer(), non_neg_integer()) ::
          [DisplayList.draw()]
  defp inline_vt_border_draw(decorations, buf_line, screen_row) do
    case Decorations.inline_virtual_texts_for_line(decorations, buf_line) do
      [] ->
        []

      [vt | _] ->
        Enum.map(vt.segments, fn {text, style} ->
          DisplayList.draw(screen_row, 0, text, style)
        end)
    end
  end

  # Returns the total display width of inline virtual texts on a line.
  @spec inline_vt_display_width(Decorations.t(), non_neg_integer()) :: non_neg_integer()
  defp inline_vt_display_width(decorations, buf_line) do
    decorations
    |> Decorations.inline_virtual_texts_for_line(buf_line)
    |> Enum.reduce(0, fn vt, acc ->
      seg_width =
        Enum.reduce(vt.segments, 0, fn {text, _style}, w ->
          w + Unicode.display_width(text)
        end)

      acc + seg_width
    end)
  end

  # ── Gutter primitives ───────────────────────────────────────────────────

  @spec render_sign(line_params(), non_neg_integer()) :: DisplayList.draw() | []
  defp render_sign(%{ctx: ctx, buf_line: buf_line}, sr) do
    Gutter.render_sign(
      sr,
      0,
      buf_line,
      ctx.diagnostic_signs,
      ctx.git_signs,
      ctx.gutter_colors,
      ctx.git_colors,
      ctx.decorations
    )
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
    DisplayList.draw(
      sr,
      p.sign_w,
      String.duplicate(" ", max(p.gutter_w - p.sign_w, 0)),
      Face.new(fg: p.ctx.gutter_colors.fg)
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

  # Strips conceal ranges for the cursor line so that raw text is revealed.
  # This implements Neovim's concealcursor behavior: concealed text is
  # visible when the cursor is on the line, hidden on all other lines.
  @spec maybe_reveal_conceals(Context.t(), non_neg_integer(), non_neg_integer()) :: Context.t()
  defp maybe_reveal_conceals(ctx, buf_line, cursor_line) when buf_line == cursor_line do
    if Decorations.has_conceal_ranges?(ctx.decorations) do
      revealed = %{ctx.decorations | conceal_ranges: []}
      %{ctx | decorations: revealed}
    else
      ctx
    end
  end

  defp maybe_reveal_conceals(ctx, _buf_line, _cursor_line), do: ctx

  @spec prepend_all([DisplayList.draw()], [DisplayList.draw()]) :: [DisplayList.draw()]
  defp prepend_all(acc, []), do: acc
  defp prepend_all(acc, items), do: Enum.reduce(items, acc, fn item, a -> [item | a] end)
end
