defmodule MingaEditor.UI.Theme.Palette.Semantic do
  @moduledoc """
  Semantic palette colors for theme authoring.

  These drive the non-syntax UI surfaces and contrast-aware values.
  """

  alias MingaEditor.UI.Theme
  alias MingaEditor.UI.Theme.Palette.Base

  defstruct [
    :accent,
    :highlight,
    :selection_bg,
    :error,
    :warning,
    :info,
    :success,
    :match,
    :link,
    :border,
    :contrast_fg
  ]

  @type color :: Theme.color()

  @type t :: %__MODULE__{
          accent: color() | nil,
          highlight: color() | nil,
          selection_bg: color() | nil,
          error: color() | nil,
          warning: color() | nil,
          info: color() | nil,
          success: color() | nil,
          match: color() | nil,
          link: color() | nil,
          border: color() | nil,
          contrast_fg: color() | nil
        }

  @doc "Builds the semantic palette from a flat theme map."
  @spec new(map(), :dark | :light, Base.t()) :: t()
  def new(attrs, variant, base) when is_map(attrs) do
    # `accent` is the construction input, `highlight` is the concrete UI source used by slots.
    accent = optional_color(attrs, :accent, default_info(variant))
    highlight = optional_color(attrs, :highlight, accent)
    warning = optional_color(attrs, :warning, default_warning(variant))
    info = optional_color(attrs, :info, accent)

    %__MODULE__{
      accent: accent,
      highlight: highlight,
      selection_bg: optional_color(attrs, :selection_bg, base.surface),
      error: optional_color(attrs, :error, default_error(variant)),
      warning: warning,
      info: info,
      success: optional_color(attrs, :success, default_success(variant)),
      match: optional_color(attrs, :match, warning),
      link: optional_color(attrs, :link, info),
      border: optional_color(attrs, :border, base.subtle),
      contrast_fg: optional_color(attrs, :contrast_fg, default_contrast_fg(variant, base.bg))
    }
  end

  @spec optional_color(map(), atom(), color()) :: color()
  defp optional_color(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        value

      {:ok, value} ->
        raise ArgumentError,
              "theme palette #{Atom.to_string(key)} must be a color, got: #{inspect(value)}"

      :error ->
        default
    end
  end

  @spec default_contrast_fg(:dark | :light, color()) :: color()
  defp default_contrast_fg(:dark, bg), do: bg
  defp default_contrast_fg(:light, _bg), do: 0xFFFFFF

  @spec default_error(:dark | :light) :: color()
  defp default_error(:dark), do: 0xFF6C6B
  defp default_error(:light), do: 0xE45649

  @spec default_warning(:dark | :light) :: color()
  defp default_warning(:dark), do: 0xECBE7B
  defp default_warning(:light), do: 0xDA8548

  @spec default_info(:dark | :light) :: color()
  defp default_info(:dark), do: 0x51AFEF
  defp default_info(:light), do: 0x0184BC

  @spec default_success(:dark | :light) :: color()
  defp default_success(:dark), do: 0x98BE65
  defp default_success(:light), do: 0x50A14F
end
