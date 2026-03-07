defmodule Minga.Port.Capabilities do
  @moduledoc """
  Frontend capabilities reported during the ready handshake.

  When a frontend starts, it sends a `ready` event with optional capability
  fields. The BEAM uses these to adapt rendering strategy: skipping image
  commands on terminals without image support, using native floating windows
  on GUIs, adjusting text measurement for proportional fonts, etc.

  Frontends that send the short 5-byte `ready` format get `default/0` caps
  (TUI, RGB, wcwidth, no images, emulated floats, monospace).
  """

  @enforce_keys []
  defstruct frontend_type: :tui,
            color_depth: :rgb,
            unicode_width: :wcwidth,
            image_support: :none,
            float_support: :emulated,
            text_rendering: :monospace

  @type frontend_type :: :tui | :native_gui | :web
  @type color_depth :: :mono | :color_256 | :rgb
  @type unicode_width :: :wcwidth | :unicode_15
  @type image_support :: :none | :kitty | :sixel | :native
  @type float_support :: :emulated | :native
  @type text_rendering :: :monospace | :proportional

  @type t :: %__MODULE__{
          frontend_type: frontend_type(),
          color_depth: color_depth(),
          unicode_width: unicode_width(),
          image_support: image_support(),
          float_support: float_support(),
          text_rendering: text_rendering()
        }

  @doc "Returns the default capabilities (TUI with full RGB, monospace)."
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc "Decodes capability fields from the binary payload (6 bytes)."
  @spec from_binary(binary()) :: t()
  def from_binary(
        <<frontend_type::8, color_depth::8, unicode_width::8, image_support::8, float_support::8,
          text_rendering::8>>
      ) do
    %__MODULE__{
      frontend_type: decode_frontend_type(frontend_type),
      color_depth: decode_color_depth(color_depth),
      unicode_width: decode_unicode_width(unicode_width),
      image_support: decode_image_support(image_support),
      float_support: decode_float_support(float_support),
      text_rendering: decode_text_rendering(text_rendering)
    }
  end

  def from_binary(_), do: default()

  # ── Decoders ──

  @spec decode_frontend_type(non_neg_integer()) :: frontend_type()
  defp decode_frontend_type(0), do: :tui
  defp decode_frontend_type(1), do: :native_gui
  defp decode_frontend_type(2), do: :web
  defp decode_frontend_type(_), do: :tui

  @spec decode_color_depth(non_neg_integer()) :: color_depth()
  defp decode_color_depth(0), do: :mono
  defp decode_color_depth(1), do: :color_256
  defp decode_color_depth(2), do: :rgb
  defp decode_color_depth(_), do: :rgb

  @spec decode_unicode_width(non_neg_integer()) :: unicode_width()
  defp decode_unicode_width(0), do: :wcwidth
  defp decode_unicode_width(1), do: :unicode_15
  defp decode_unicode_width(_), do: :wcwidth

  @spec decode_image_support(non_neg_integer()) :: image_support()
  defp decode_image_support(0), do: :none
  defp decode_image_support(1), do: :kitty
  defp decode_image_support(2), do: :sixel
  defp decode_image_support(3), do: :native
  defp decode_image_support(_), do: :none

  @spec decode_float_support(non_neg_integer()) :: float_support()
  defp decode_float_support(0), do: :emulated
  defp decode_float_support(1), do: :native
  defp decode_float_support(_), do: :emulated

  @spec decode_text_rendering(non_neg_integer()) :: text_rendering()
  defp decode_text_rendering(0), do: :monospace
  defp decode_text_rendering(1), do: :proportional
  defp decode_text_rendering(_), do: :monospace
end
