defmodule MingaEditor.FloatingWindow do
  @moduledoc """
  Cell-grid geometry for floating panels.

  Takes a `Spec` struct describing a floating window's size and position and
  resolves its outer rect via `box/1`. The cursor-anchored popups
  (`HoverPopup`, `SignatureHelp`) build a `Spec` and ask for its `box/1` so the
  `SurfaceRegistry`/`FocusTree` can register a conservative cell-grid
  containment rect from the BEAM's semantic state.

  The cell-grid painter (`render/1` and the border/title/footer/content draw
  helpers) was removed in #2311: the semantic frontends render these popups
  natively from dedicated GUI opcodes, so native GUI frontends own final pixel
  placement.
  """

  # ── Spec ─────────────────────────────────────────────────────────────────

  defmodule Spec do
    @moduledoc """
    Geometry specification for a floating window.

    Only `viewport` is required; size and position default to a centered 60% x 50% rect.
    """

    @enforce_keys [:viewport]
    defstruct width: {:percent, 60},
              height: {:percent, 50},
              position: :center,
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
            width: size(),
            height: size(),
            position: position(),
            viewport: {rows :: pos_integer(), cols :: pos_integer()}
          }
  end

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Returns the window's outer rect in `Layout.rect()` shape: `{row, col, width, height}`.

  This is the BEAM's cell-grid containment rect for a floating popup, including
  border, position resolution, and viewport clamping, so a caller (the
  `SurfaceRegistry`/`FocusTree`) can register the surface without rendering its
  content. Native GUI frontends must not treat this as an exact pixel rect.
  """
  @spec box(Spec.t()) :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}
  def box(%Spec{} = spec) do
    {vp_rows, vp_cols} = spec.viewport
    %{row: row, col: col, w: w, h: h} = compute_box(spec, vp_rows, vp_cols)
    {row, col, w, h}
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
end
