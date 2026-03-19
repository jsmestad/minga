defmodule Minga.Port.Capabilities do
  @moduledoc """
  Frontend capabilities reported during the ready handshake.

  When a frontend starts, it sends a `ready` event with optional capability
  fields. The BEAM uses these to adapt rendering strategy: skipping image
  commands on terminals without image support, using native floating windows
  on GUIs, using native floating windows, etc.

  Frontends that send the short 5-byte `ready` format get `default/0` caps
  (TUI, RGB, wcwidth, no images, emulated floats, monospace).
  """

  @enforce_keys []
  defstruct frontend_type: :tui,
            color_depth: :rgb,
            unicode_width: :wcwidth,
            image_support: :none,
            float_support: :emulated

  @type frontend_type :: :tui | :native_gui | :web
  @type color_depth :: :mono | :color_256 | :rgb
  @type unicode_width :: :wcwidth | :unicode_15
  @type image_support :: :none | :kitty | :sixel | :native
  @type float_support :: :emulated | :native

  @type t :: %__MODULE__{
          frontend_type: frontend_type(),
          color_depth: color_depth(),
          unicode_width: unicode_width(),
          image_support: image_support(),
          float_support: float_support()
        }

  @doc "Returns the default capabilities (TUI with full RGB, monospace)."
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc "Decodes capability fields from the binary payload (6 bytes)."
  @spec from_binary(binary()) :: t()
  def from_binary(
        <<frontend_type::8, color_depth::8, unicode_width::8, image_support::8, float_support::8,
          _reserved::8>>
      ) do
    %__MODULE__{
      frontend_type: decode_frontend_type(frontend_type),
      color_depth: decode_color_depth(color_depth),
      unicode_width: decode_unicode_width(unicode_width),
      image_support: decode_image_support(image_support),
      float_support: decode_float_support(float_support)
    }
  end

  def from_binary(_), do: default()

  # ── Query helpers ──

  @doc "Returns true if the frontend supports inline images (kitty, sixel, or native)."
  @spec images?(t()) :: boolean()
  def images?(%__MODULE__{image_support: :none}), do: false
  def images?(%__MODULE__{}), do: true

  @doc "Returns true if the frontend supports native floating windows (not emulated overlays)."
  @spec native_floats?(t()) :: boolean()
  def native_floats?(%__MODULE__{float_support: :native}), do: true
  def native_floats?(%__MODULE__{}), do: false

  @doc "Returns true if the frontend supports full 24-bit RGB color."
  @spec rgb?(t()) :: boolean()
  def rgb?(%__MODULE__{color_depth: :rgb}), do: true
  def rgb?(%__MODULE__{}), do: false

  @doc "Returns true if the frontend is a native GUI (not a terminal)."
  @spec gui?(t()) :: boolean()
  def gui?(%__MODULE__{frontend_type: :native_gui}), do: true
  def gui?(%__MODULE__{}), do: false

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
end
