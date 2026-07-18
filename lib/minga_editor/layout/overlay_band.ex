defmodule MingaEditor.Layout.OverlayBand do
  @moduledoc """
  Shared footer-band geometry for the single-active secondary overlays (#2281).

  The Go compositor historically footer-appended one secondary overlay at the
  bottom of the screen, sizing its height with `maxOverlayHeight()`
  (`go/tui/internal/ui/model.go`: `min(max(height/3, 4), 12)`) and spanning the
  full terminal width. These seven surfaces (float popup, agent context, extension
  panel, observatory, edit timeline, notifications, and extension overlay) are
  identical footer-band shapes, so the BEAM owns one rect helper for all of them
  instead of seven copies.

  `rect/2` ports that exact clamp. `content_height` is the surface's content line
  count (BEAM-derivable from the chrome/UI models) or `:max` for a surface whose
  wrapped line count the BEAM cannot know. The rect is bottom-anchored: it occupies
  the lowest `height` rows of the terminal and the full width, the same band the
  frontend appended into, so the rect's bottom edge sits where the old footer-append
  put the overlay (directly above the minibuffer).

  Only one overlay shows at a time in that band (single-active model, #2268 AC-4).
  For the count-derivable surfaces (notifications, observatory, edit_timeline,
  extension_overlay) the caller passes a real `content_height` so the band shrinks
  to the content and the overlay hugs the screen bottom. For wrap-dependent
  active surfaces (float_popup, extension_panel, and agent_context) the caller
  passes `:max` (the clamp ceiling); the frontend bottom-aligns the
  rendered content inside that band, so a short overlay still hugs the bottom and
  the residual phantom rows sit ABOVE it (see `MingaEditor.Layout.FooterOverlays`).
  Either way the rect only needs to CONTAIN the overlay so clicks over it are
  hit-tested, not pixel-match it.
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
