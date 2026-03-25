defmodule Minga.Editor.Renderer.Caps do
  @moduledoc """
  Capability-aware rendering helpers.

  These functions inspect the frontend's reported capabilities and adapt
  rendering behavior accordingly. Each function is a decision point where
  the renderer branches based on what the frontend supports.

  Current TUI always reports: RGB, monospace, no images, emulated floats.
  These helpers become meaningful when a GUI frontend connects with
  different capabilities.
  """

  alias Minga.Frontend.Capabilities

  @doc """
  Returns true if the BEAM should render overlay popups (which-key,
  completion, picker) as draw commands.

  When the frontend has native float support, these overlays are handled
  by the frontend's native windowing system (NSPopover, GtkPopover, etc.)
  and the BEAM should send structured data instead of draw commands.
  """
  @spec render_overlays?(Capabilities.t()) :: boolean()
  def render_overlays?(%Capabilities{float_support: :native}), do: false
  def render_overlays?(%Capabilities{}), do: true

  @doc """
  Degrades a 24-bit RGB color to the nearest 256-color or monochrome
  equivalent based on the frontend's color depth.

  Returns the color unchanged for RGB frontends.
  """
  @spec adapt_color(non_neg_integer(), Capabilities.t()) :: non_neg_integer()
  def adapt_color(color, %Capabilities{color_depth: :rgb}), do: color

  def adapt_color(color, %Capabilities{color_depth: :color_256}) do
    rgb_to_256(color)
  end

  def adapt_color(_color, %Capabilities{color_depth: :mono}), do: 0xFFFFFF

  @doc """
  Returns true if image rendering commands should be sent to the frontend.

  Terminals without kitty/sixel/native image support will ignore or
  garble image escape sequences.
  """
  @spec send_images?(Capabilities.t()) :: boolean()
  def send_images?(%Capabilities{image_support: :none}), do: false
  def send_images?(%Capabilities{}), do: true

  # ── Color conversion ───────────────────────────────────────────────────────

  # Converts a 24-bit RGB color to the nearest xterm-256 color index.
  # Uses the 6x6x6 color cube (indices 16-231) for non-grayscale colors
  # and the grayscale ramp (indices 232-255) for near-gray colors.
  @spec rgb_to_256(non_neg_integer()) :: non_neg_integer()
  defp rgb_to_256(color) do
    r = Bitwise.bsr(color, 16) |> Bitwise.band(0xFF)
    g = Bitwise.bsr(color, 8) |> Bitwise.band(0xFF)
    b = Bitwise.band(color, 0xFF)

    # Check if it's close to grayscale
    if abs(r - g) < 10 and abs(g - b) < 10 do
      # Use grayscale ramp (232-255, 24 shades from 8 to 238)
      gray = div(r + g + b, 3)
      232 + min(div(gray * 23, 255), 23)
    else
      # Map to 6x6x6 color cube (indices 16-231)
      ri = min(div(r * 5, 255), 5)
      gi = min(div(g * 5, 255), 5)
      bi = min(div(b * 5, 255), 5)
      16 + 36 * ri + 6 * gi + bi
    end
  end
end
