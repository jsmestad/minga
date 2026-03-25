defmodule Minga.Editor.FloatingWindow do
  @moduledoc """
  Pure rendering helper for bordered, titled floating panels.

  Takes a `Spec` struct describing the window's content, size, position,
  and styling, and returns a list of `DisplayList.draw()` tuples. No
  GenServer, no state. The caller (PickerUI, WhichKey, or any future
  consumer) builds the spec, calls `render/1`, and includes the draws
  as an `Overlay` in the render pipeline.

  Works for both TUI (emulated overlays) and GUI (the draws are
  frontend-agnostic styled text runs).

  ## Example

      spec = %FloatingWindow.Spec{
        title: "Select Model",
        content: [DisplayList.draw(0, 0, "claude-sonnet-4-20250514", Face.new(fg: :white))],
        width: {:percent, 60},
        height: {:rows, 15},
        border: :rounded,
        theme: state.theme.popup,
        viewport: {state.workspace.viewport.rows, state.workspace.viewport.cols}
      }

      draws = FloatingWindow.render(spec)
  """

  alias Minga.Editor.DisplayList
  alias Minga.UI.Face

  # ── Border character sets ────────────────────────────────────────────────

  @type border_style :: :single | :double | :rounded | :none

  @type border_chars :: %{
          tl: String.t(),
          tr: String.t(),
          bl: String.t(),
          br: String.t(),
          h: String.t(),
          v: String.t()
        }

  @border_single %{tl: "┌", tr: "┐", bl: "└", br: "┘", h: "─", v: "│"}
  @border_double %{tl: "╔", tr: "╗", bl: "╚", br: "╝", h: "═", v: "║"}
  @border_rounded %{tl: "╭", tr: "╮", bl: "╰", br: "╯", h: "─", v: "│"}

  # ── Spec ─────────────────────────────────────────────────────────────────

  defmodule Spec do
    @moduledoc """
    Specification for a floating window.

    All fields except `theme` and `viewport` have sensible defaults.
    """

    @enforce_keys [:theme, :viewport]
    defstruct title: nil,
              footer: nil,
              content: [],
              width: {:percent, 60},
              height: {:percent, 50},
              position: :center,
              border: :rounded,
              theme: nil,
              viewport: nil

    @type size :: {:cols, pos_integer()} | {:rows, pos_integer()} | {:percent, 1..100}

    @typedoc """
    Position for the floating window.

    - `:center` — centered in the viewport
    - `{row_offset, col_offset}` — offset from center
    - `{:anchor, row, col, :above | :below}` — anchored to a cursor position,
      appearing above or below. Flips if there isn't enough room.
    """
    @type position ::
            :center
            | {row_offset :: integer(), col_offset :: integer()}
            | {:anchor, row :: non_neg_integer(), col :: non_neg_integer(),
               preferred :: :above | :below}

    @type t :: %__MODULE__{
            title: String.t() | nil,
            footer: String.t() | nil,
            content: [Minga.Editor.DisplayList.draw()],
            width: size(),
            height: size(),
            position: position(),
            border: Minga.Editor.FloatingWindow.border_style(),
            theme: map(),
            viewport: {rows :: pos_integer(), cols :: pos_integer()}
          }
  end

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Renders a floating window from the given spec.

  Returns a flat list of `DisplayList.draw()` tuples representing the
  border, title, footer, background fill, and content. The draws use
  absolute screen coordinates and can be included directly in an
  `Overlay` struct.
  """
  @spec render(Spec.t()) :: [DisplayList.draw()]
  def render(%Spec{} = spec) do
    {vp_rows, vp_cols} = spec.viewport
    box = compute_box(spec, vp_rows, vp_cols)

    bg_draws = render_background(box, spec.theme)
    border_draws = render_border(box, spec.border, spec.theme)
    title_draws = render_title(box, spec.title, spec.border, spec.theme)
    footer_draws = render_footer(box, spec.footer, spec.border, spec.theme)
    content_draws = offset_content(box, spec.content, spec.border)

    bg_draws ++ border_draws ++ title_draws ++ footer_draws ++ content_draws
  end

  @doc """
  Computes the interior dimensions (usable content area) for a spec.

  Returns `{rows, cols}` representing how many rows and columns are
  available for content inside the border. Useful for callers that need
  to know how much content to prepare before calling `render/1`.
  """
  @spec interior_size(Spec.t()) :: {rows :: non_neg_integer(), cols :: non_neg_integer()}
  def interior_size(%Spec{} = spec) do
    {vp_rows, vp_cols} = spec.viewport
    box = compute_box(spec, vp_rows, vp_cols)
    border_inset = if spec.border == :none, do: 0, else: 1
    interior_w = max(box.w - border_inset * 2, 0)
    interior_h = max(box.h - border_inset * 2, 0)
    {interior_h, interior_w}
  end

  # ── Box computation ──────────────────────────────────────────────────────

  @typep box :: %{
           row: non_neg_integer(),
           col: non_neg_integer(),
           w: pos_integer(),
           h: pos_integer()
         }

  @spec compute_box(Spec.t(), pos_integer(), pos_integer()) :: box()
  defp compute_box(spec, vp_rows, vp_cols) do
    w = resolve_size(spec.width, vp_cols) |> clamp(1, vp_cols)
    h = resolve_size(spec.height, vp_rows) |> clamp(1, vp_rows)

    {row, col} = resolve_position(spec.position, h, w, vp_rows, vp_cols)

    %{row: row, col: col, w: w, h: h}
  end

  @spec resolve_size(Spec.size(), pos_integer()) :: pos_integer()
  defp resolve_size({:cols, n}, _max), do: n
  defp resolve_size({:rows, n}, _max), do: n
  defp resolve_size({:percent, pct}, max), do: max(div(max * pct, 100), 1)

  @spec resolve_position(
          Spec.position(),
          pos_integer(),
          pos_integer(),
          pos_integer(),
          pos_integer()
        ) ::
          {non_neg_integer(), non_neg_integer()}
  defp resolve_position(:center, h, w, vp_rows, vp_cols) do
    row = max(div(vp_rows - h, 2), 0)
    col = max(div(vp_cols - w, 2), 0)
    {row, col}
  end

  defp resolve_position({row_off, col_off}, h, w, vp_rows, vp_cols) do
    center_row = max(div(vp_rows - h, 2), 0)
    center_col = max(div(vp_cols - w, 2), 0)
    row = clamp(center_row + row_off, 0, max(vp_rows - h, 0))
    col = clamp(center_col + col_off, 0, max(vp_cols - w, 0))
    {row, col}
  end

  # Anchor positioning: place the window near a cursor position.
  # Tries the preferred direction first, flips if there isn't room.
  defp resolve_position({:anchor, anchor_row, anchor_col, preferred}, h, w, vp_rows, vp_cols) do
    col = clamp(anchor_col, 0, max(vp_cols - w, 0))

    row =
      case preferred do
        :above ->
          if anchor_row - h >= 0 do
            anchor_row - h
          else
            # Not enough room above, try below
            min(anchor_row + 1, max(vp_rows - h, 0))
          end

        :below ->
          if anchor_row + 1 + h <= vp_rows do
            anchor_row + 1
          else
            # Not enough room below, try above
            max(anchor_row - h, 0)
          end
      end

    {row, col}
  end

  @spec clamp(integer(), integer(), integer()) :: integer()
  defp clamp(val, lo, hi), do: max(lo, min(val, hi))

  # ── Background fill ─────────────────────────────────────────────────────

  @spec render_background(box(), map()) :: [DisplayList.draw()]
  defp render_background(%{row: row, col: col, w: w, h: h}, theme) do
    bg_style = Face.new(bg: theme.bg)
    fill = String.duplicate(" ", w)

    for r <- row..(row + h - 1) do
      DisplayList.draw(r, col, fill, bg_style)
    end
  end

  # ── Border rendering ─────────────────────────────────────────────────────

  @spec render_border(box(), border_style(), map()) :: [DisplayList.draw()]
  defp render_border(_box, :none, _theme), do: []

  defp render_border(%{row: row, col: col, w: w, h: h}, style, theme) do
    chars = border_chars(style)
    border_style = Face.new(fg: theme.border_fg, bg: theme.bg)
    inner_w = max(w - 2, 0)
    horiz = String.duplicate(chars.h, inner_w)

    top = DisplayList.draw(row, col, chars.tl <> horiz <> chars.tr, border_style)
    bottom = DisplayList.draw(row + h - 1, col, chars.bl <> horiz <> chars.br, border_style)

    sides =
      for r <- (row + 1)..(row + h - 2)//1 do
        [
          DisplayList.draw(r, col, chars.v, border_style),
          DisplayList.draw(r, col + w - 1, chars.v, border_style)
        ]
      end

    [top, bottom | List.flatten(sides)]
  end

  # ── Title / Footer ──────────────────────────────────────────────────────

  @spec render_title(box(), String.t() | nil, border_style(), map()) :: [DisplayList.draw()]
  defp render_title(_box, nil, _border, _theme), do: []
  defp render_title(_box, "", _border, _theme), do: []
  defp render_title(_box, _title, :none, _theme), do: []

  defp render_title(%{row: row, col: col, w: w}, title, _border, theme) do
    inner_w = max(w - 4, 0)
    truncated = truncate(title, inner_w)
    title_text = " #{truncated} "
    title_len = String.length(title_text)
    # Center the title in the top border
    start_col = col + max(div(w - title_len, 2), 1)
    title_style = title_style(theme)
    [DisplayList.draw(row, start_col, title_text, title_style)]
  end

  @spec render_footer(box(), String.t() | nil, border_style(), map()) :: [DisplayList.draw()]
  defp render_footer(_box, nil, _border, _theme), do: []
  defp render_footer(_box, "", _border, _theme), do: []
  defp render_footer(_box, _footer, :none, _theme), do: []

  defp render_footer(%{row: row, col: col, w: w, h: h}, footer, _border, theme) do
    inner_w = max(w - 4, 0)
    truncated = truncate(footer, inner_w)
    footer_text = " #{truncated} "
    footer_len = String.length(footer_text)
    start_col = col + max(div(w - footer_len, 2), 1)
    footer_style = Face.new(fg: theme.border_fg, bg: theme.bg)
    [DisplayList.draw(row + h - 1, start_col, footer_text, footer_style)]
  end

  # ── Content offsetting ──────────────────────────────────────────────────

  @spec offset_content(box(), [DisplayList.draw()], border_style()) :: [DisplayList.draw()]
  defp offset_content(_box, [], _border), do: []

  defp offset_content(%{row: row, col: col, w: w, h: h}, content, border) do
    inset = if border == :none, do: 0, else: 1
    interior_row = row + inset
    interior_col = col + inset
    interior_w = max(w - inset * 2, 0)
    interior_h = max(h - inset * 2, 0)

    content
    |> Enum.map(fn {r, c, text, style} ->
      abs_row = r + interior_row
      abs_col = c + interior_col

      # Clip: skip draws outside the interior
      if r < interior_h and c < interior_w do
        # Truncate text that would overflow the right edge
        max_len = max(interior_w - c, 0)
        clipped_text = truncate(text, max_len)
        DisplayList.draw(abs_row, abs_col, clipped_text, style)
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  @spec border_chars(border_style()) :: border_chars()
  defp border_chars(:single), do: @border_single
  defp border_chars(:double), do: @border_double
  defp border_chars(:rounded), do: @border_rounded

  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  defp truncate(text, max_len) when max_len <= 0, do: text

  defp truncate(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max(max_len - 1, 0)) <> "…"
    else
      text
    end
  end

  @spec title_style(map()) :: Face.t()
  defp title_style(theme) do
    fg = Map.get(theme, :title_fg, theme.border_fg)
    Face.new(fg: fg, bg: theme.bg, bold: true)
  end
end
