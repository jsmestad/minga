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
    :contrast_fg,
    :minga,
    :needs_you,
    :done,
    :waiting,
    :group
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
          contrast_fg: color() | nil,
          minga: color() | nil,
          needs_you: color() | nil,
          done: color() | nil,
          waiting: color() | nil,
          group: color() | nil
        }

  @doc "Builds the semantic palette from a flat theme map."
  @spec new(map(), :dark | :light, Base.t()) :: t()
  def new(attrs, variant, base) when is_map(attrs) do
    # `accent` is the construction input, `highlight` is the concrete UI source used by slots.
    accent = Base.optional_color(attrs, :accent, default_info(variant))
    highlight = Base.optional_color(attrs, :highlight, accent)
    warning = Base.optional_color(attrs, :warning, default_warning(variant))
    info = Base.optional_color(attrs, :info, accent)
    success = Base.optional_color(attrs, :success, default_success(variant))

    %__MODULE__{
      accent: accent,
      highlight: highlight,
      selection_bg: Base.optional_color(attrs, :selection_bg, base.surface),
      error: Base.optional_color(attrs, :error, default_error(variant)),
      warning: warning,
      info: info,
      success: success,
      match: Base.optional_color(attrs, :match, warning),
      link: Base.optional_color(attrs, :link, info),
      border: Base.optional_color(attrs, :border, base.subtle),
      contrast_fg:
        Base.optional_color(attrs, :contrast_fg, default_contrast_fg(variant, base.bg)),
      minga: Base.optional_color(attrs, :minga, default_minga(variant)),
      needs_you: Base.optional_color(attrs, :needs_you, default_needs_you(variant)),
      done: Base.optional_color(attrs, :done, success),
      waiting: Base.optional_color(attrs, :waiting, base.muted),
      group: Base.optional_color(attrs, :group, highlight)
    }
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

  @spec default_minga(:dark | :light) :: color()
  defp default_minga(:dark), do: 0xC678DD
  defp default_minga(:light), do: 0xA626A4

  @spec default_needs_you(:dark | :light) :: color()
  defp default_needs_you(:dark), do: 0xDA8548
  defp default_needs_you(:light), do: 0xB35900

  @spec default_success(:dark | :light) :: color()
  defp default_success(:dark), do: 0x98BE65
  defp default_success(:light), do: 0x50A14F
end
