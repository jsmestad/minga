defmodule MingaEditor.Layout.OverlayBand do
  @moduledoc """
  Shared footer-band geometry for single-active secondary overlays (#2281).

  Float popups, compact agent context, extension panels, observatory, notifications and extension overlays share this band.
  The edit timeline is persistent chrome with its own `Layout.edit_timeline` rectangle and does not compete for this band.

  `rect/3` computes the Go `maxOverlayHeight()` clamp from the full terminal row count, exactly as the Go TUI does, and caps it to the rows of the area the band may occupy.
  Callers pass the editor area, so the rectangle spans the full width and is bottom-anchored directly above the terminal status row and minibuffer.
  Anchoring to the whole terminal grid would cover that footer chrome and hide the command line while an overlay is visible.
  `content_height` is the surface's BEAM-derived line count, or `:max` when wrapping determines the final height.

  Only one overlay appears in the band at a time.
  Notifications, observatory and extension overlays provide a real content height so short overlays hug the bottom.
  Float popups, extension panels and compact agent context use `:max`; the frontend bottom-aligns their rendered content inside the band.
  The rectangle must contain the rendered overlay for hit testing, not match every rendered pixel.
  """

  alias MingaEditor.Layout

  @clamp_floor 4
  @clamp_ceiling 12

  @doc """
  Returns the clamped footer-band height for a content line count.

  Ports the Go `maxOverlayHeight()` clamp: the band is `terminal_rows / 3`,
  floored at #{@clamp_floor} and ceiled at #{@clamp_ceiling}, but never taller
  than the grid or the content it must contain. Passing `:max` takes the full
  available band for a surface with an unknown wrapped line count.
  """
  @spec band_height(non_neg_integer(), non_neg_integer() | :max) :: non_neg_integer()
  def band_height(terminal_rows, :max) do
    max_overlay_height(terminal_rows)
  end

  def band_height(terminal_rows, content_height)
      when is_integer(content_height) and content_height >= 0 do
    min(content_height, max_overlay_height(terminal_rows))
  end

  @doc """
  Returns the bottom-anchored, full-width footer-band rect for an overlay.

  `area` is the region the band may occupy, normally the layout's editor area.
  `content_height` is the surface's content line count (or `:max` to take the
  clamp ceiling for a text-wrap-dependent surface). The rect spans the full
  width of `area` and its lowest `band_height/2` rows, matching where the Go
  compositor footer-appended the overlay above the minibuffer. Returns `nil`
  when the band is empty.
  """
  @spec rect(Layout.rect(), non_neg_integer() | :max) :: Layout.rect() | nil
  def rect({_row, _col, _width, rows} = area, content_height),
    do: rect(area, content_height, rows)

  @doc """
  Like `rect/2`, but computes the height clamp from `clamp_rows` (the full terminal row count, as the Go TUI's `maxOverlayHeight()` does) while still anchoring the band inside `area` and never exceeding its rows.
  """
  @spec rect(Layout.rect(), non_neg_integer() | :max, non_neg_integer()) :: Layout.rect() | nil
  def rect({row, col, width, rows}, content_height, clamp_rows)
      when is_integer(clamp_rows) and clamp_rows >= 0 do
    height = clamp_rows |> band_height(content_height) |> min(rows)

    if height <= 0 do
      nil
    else
      {row + rows - height, col, width, height}
    end
  end

  @spec max_overlay_height(non_neg_integer()) :: non_neg_integer()
  defp max_overlay_height(terminal_rows) do
    terminal_rows
    |> div(3)
    |> max(@clamp_floor)
    |> min(@clamp_ceiling)
    |> min(terminal_rows)
  end
end
