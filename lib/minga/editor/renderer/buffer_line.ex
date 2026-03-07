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
  """

  alias Minga.Buffer.Unicode
  alias Minga.Editor.Renderer.Context
  alias Minga.Editor.Renderer.Gutter
  alias Minga.Editor.Renderer.Line, as: LineRenderer
  alias Minga.Editor.WrapMap
  alias Minga.Port.Protocol

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
          row_offset: non_neg_integer(),
          col_offset: non_neg_integer()
        }

  @doc """
  Renders one logical buffer line to screen rows.

  Returns `{gutter_commands, content_commands, rows_consumed}`.
  For non-wrapped lines, `rows_consumed` is always 1. For wrapped
  lines, it equals the number of visual rows produced.
  """
  @spec render(line_params()) :: {[binary()], [binary()], pos_integer()}
  def render(%{wrap_entry: nil} = p) do
    {g_cmds, c_cmds} = render_single_row(p)
    {g_cmds, c_cmds, 1}
  end

  def render(%{wrap_entry: visual_rows} = p) do
    render_wrapped_rows(p, visual_rows)
  end

  # ── Single row (no wrap) ─────────────────────────────────────────────────

  @spec render_single_row(line_params()) :: {[binary()], [binary()]}
  defp render_single_row(p) do
    sr = p.screen_row

    sign_cmd = render_sign(p, sr)
    gutter_cmd = render_number(p, sr)

    content_cmds =
      LineRenderer.render(p.line_text, sr, p.buf_line, p.ctx, p.byte_offset)

    gutters = build_gutter_list(sign_cmd, gutter_cmd, p.row_offset, p.col_offset)
    contents = maybe_offset(content_cmds, p.row_offset, p.col_offset)
    {gutters, contents}
  end

  # ── Wrapped rows ─────────────────────────────────────────────────────────

  @spec render_wrapped_rows(line_params(), WrapMap.wrap_entry()) ::
          {[binary()], [binary()], pos_integer()}
  defp render_wrapped_rows(p, visual_rows) do
    {g_acc, c_acc, sr} =
      Enum.reduce(visual_rows, {[], [], p.screen_row}, fn vrow, {g, c, sr} ->
        is_first = sr == p.screen_row
        {g_cmds, c_cmds} = render_visual_row(p, vrow, sr, is_first)
        {prepend_all(g, g_cmds), prepend_all(c, c_cmds), sr + 1}
      end)

    {Enum.reverse(g_acc), Enum.reverse(c_acc), sr - p.screen_row}
  end

  @spec render_visual_row(line_params(), WrapMap.visual_row(), non_neg_integer(), boolean()) ::
          {[binary()], [binary()]}
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

    gutters = build_gutter_list(sign_cmd, gutter_cmd, p.row_offset, p.col_offset)
    contents = maybe_offset(content_cmds, p.row_offset, p.col_offset)
    {gutters, contents}
  end

  # ── Gutter primitives ───────────────────────────────────────────────────

  @spec render_sign(line_params(), non_neg_integer()) :: binary() | []
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

  @spec render_number(line_params(), non_neg_integer()) :: binary() | []
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

  @spec render_blank_gutter(line_params(), non_neg_integer()) :: binary()
  defp render_blank_gutter(p, sr) do
    Protocol.encode_draw(sr, p.sign_w, String.duplicate(" ", max(p.gutter_w - p.sign_w, 0)),
      fg: p.ctx.gutter_colors.fg
    )
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec build_gutter_list(binary() | [], binary() | [], non_neg_integer(), non_neg_integer()) ::
          [binary()]
  defp build_gutter_list(sign_cmd, gutter_cmd, row_off, col_off) do
    cmds =
      []
      |> prepend_if(sign_cmd)
      |> prepend_if(gutter_cmd)

    maybe_offset(cmds, row_off, col_off)
  end

  @spec maybe_offset([binary()], non_neg_integer(), non_neg_integer()) :: [binary()]
  defp maybe_offset(cmds, 0, 0), do: cmds

  defp maybe_offset(cmds, row_off, col_off) do
    Enum.map(cmds, fn
      <<0x10, row::16, col::16, rest::binary>> ->
        <<0x10, row + row_off::16, col + col_off::16, rest::binary>>

      other ->
        other
    end)
  end

  @spec prepend_if([binary()], binary() | []) :: [binary()]
  defp prepend_if(list, []), do: list
  defp prepend_if(list, cmd) when is_binary(cmd), do: [cmd | list]

  @spec prepend_all([binary()], [binary()]) :: [binary()]
  defp prepend_all(acc, []), do: acc
  defp prepend_all(acc, items), do: Enum.reduce(items, acc, fn item, a -> [item | a] end)
end
