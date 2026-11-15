defmodule MingaEditor.Layout.OverlayBand do
  @moduledoc """
  Shared footer-band geometry for single-active secondary overlays (#2281).

  Float popups, compact agent context, extension panels, observatory, notifications and extension overlays share this band.
  The edit timeline is persistent chrome with its own `Layout.edit_timeline` rectangle and does not compete for this band.

  `rect/2` preserves the historical Go `maxOverlayHeight()` clamp: `min(max(height / 3, 4), 12)`.
  The rectangle spans the full terminal width and is bottom-anchored.
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
  floored at #{@clamp_floor} and ceiled at #{@clamp_ceiling}, and never taller
  than the content it must contain. Passing `:max` for `content_height` yields
  the clamp ceiling directly, the conservative size for a text-wrap-dependent
  surface whose exact wrapped line count the BEAM cannot know.
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

  `content_height` is the surface's content line count (or `:max` to take the
  clamp ceiling for a text-wrap-dependent surface). The rect spans the full
  terminal width and the lowest `band_height/2` rows, matching where the Go
  compositor footer-appended the overlay. Returns `nil` when the band would be
  empty (zero content and zero clamp floor never happens, but a degenerate
  terminal can produce a zero-height band).
  """
  @spec rect(Layout.rect(), non_neg_integer() | :max) :: Layout.rect() | nil
  def rect({row, col, width, rows}, content_height) do
    height = band_height(rows, content_height)

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
  end
end
