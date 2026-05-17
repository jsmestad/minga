# credo:disable-for-this-file Credo.Check.Warning.StructFieldAmount
# This ticket intentionally defines a flat semantic authoring surface for theme files.
defmodule MingaEditor.UI.Theme.Palette do
  @moduledoc """
  Semantic color palette used to derive a complete editor theme.

  A palette is the small authoring surface for themes. Theme authors provide base colors, semantic accents, and syntax roles; `MingaEditor.UI.Theme.Builder` expands them into all of the concrete theme sub-structs consumed by the renderer.
  """

  alias MingaEditor.UI.Theme

  @enforce_keys [:variant, :bg, :fg, :surface, :overlay, :muted, :subtle]
  defstruct [
    :variant,
    :bg,
    :fg,
    :surface,
    :overlay,
    :muted,
    :subtle,
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
    :builtin,
    :functions,
    :keywords,
    :methods,
    :operators,
    :constants,
    :strings,
    :numbers,
    :type,
    :variables,
    :comments
  ]

  @type variant :: :dark | :light
  @type color :: Theme.color()

  @type t :: %__MODULE__{
          variant: variant(),
          bg: color(),
          fg: color(),
          surface: color(),
          overlay: color(),
          muted: color(),
          subtle: color(),
          accent: color(),
          highlight: color(),
          selection_bg: color(),
          error: color(),
          warning: color(),
          info: color(),
          success: color(),
          match: color(),
          link: color(),
          border: color(),
          contrast_fg: color(),
          builtin: color(),
          functions: color(),
          keywords: color(),
          methods: color(),
          operators: color(),
          constants: color(),
          strings: color(),
          numbers: color(),
          type: color(),
          variables: color(),
          comments: color()
        }

  @doc "Builds a palette from an atom-keyed map and fills optional semantic defaults."
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    attrs
    |> then(&struct!(__MODULE__, &1))
    |> normalize()
  end

  @doc "Normalizes an existing palette or atom-keyed palette map."
  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = palette), do: normalize(palette)
  def from_map(attrs) when is_map(attrs), do: new(attrs)

  @doc "Fills optional semantic and syntax roles using variant-aware defaults."
  @spec normalize(t()) :: t()
  def normalize(%__MODULE__{variant: :dark} = palette) do
    palette
    |> fill_semantic_defaults()
    |> fill_syntax_defaults()
  end

  def normalize(%__MODULE__{variant: :light} = palette) do
    palette
    |> fill_semantic_defaults()
    |> fill_syntax_defaults()
  end

  def normalize(%__MODULE__{variant: variant}) do
    raise ArgumentError, "theme palette variant must be :dark or :light, got: #{inspect(variant)}"
  end

  @spec fill_semantic_defaults(t()) :: t()
  defp fill_semantic_defaults(%__MODULE__{} = palette) do
    accent = palette.accent || default_info(palette.variant)
    highlight = palette.highlight || accent
    warning = palette.warning || default_warning(palette.variant)
    info = palette.info || accent

    %{
      palette
      | accent: accent,
        highlight: highlight,
        selection_bg: palette.selection_bg || palette.surface,
        error: palette.error || default_error(palette.variant),
        warning: warning,
        info: info,
        success: palette.success || default_success(palette.variant),
        match: palette.match || warning,
        link: palette.link || info,
        border: palette.border || palette.subtle,
        contrast_fg: palette.contrast_fg || default_contrast_fg(palette)
    }
  end

  @spec fill_syntax_defaults(t()) :: t()
  defp fill_syntax_defaults(%__MODULE__{} = palette) do
    functions = default_color(palette_color(palette, :functions), palette.info)

    %{
      palette
      | builtin: default_color(palette_color(palette, :builtin), palette.info),
        functions: functions,
        keywords: default_color(palette_color(palette, :keywords), palette.highlight),
        methods: default_color(palette_color(palette, :methods), functions),
        operators: default_color(palette_color(palette, :operators), palette.accent),
        constants: default_color(palette_color(palette, :constants), palette.warning),
        strings: default_color(palette_color(palette, :strings), palette.success),
        numbers: default_color(palette_color(palette, :numbers), palette.warning),
        type: default_color(palette_color(palette, :type), palette.warning),
        variables: default_color(palette_color(palette, :variables), palette.fg),
        comments: default_color(palette_color(palette, :comments), palette.muted)
    }
  end

  @spec palette_color(t(), atom()) :: color() | nil
  defp palette_color(%__MODULE__{} = palette, field), do: Map.get(palette, field)

  @spec default_color(color() | nil, color()) :: color()
  defp default_color(nil, fallback), do: fallback
  defp default_color(color, _fallback), do: color

  @spec default_contrast_fg(t()) :: color()
  defp default_contrast_fg(%__MODULE__{variant: :dark, bg: bg}), do: bg
  defp default_contrast_fg(%__MODULE__{variant: :light}), do: 0xFFFFFF

  @spec default_error(variant()) :: color()
  defp default_error(:dark), do: 0xFF6C6B
  defp default_error(:light), do: 0xE45649

  @spec default_warning(variant()) :: color()
  defp default_warning(:dark), do: 0xECBE7B
  defp default_warning(:light), do: 0xDA8548

  @spec default_info(variant()) :: color()
  defp default_info(:dark), do: 0x51AFEF
  defp default_info(:light), do: 0x0184BC

  @spec default_success(variant()) :: color()
  defp default_success(:dark), do: 0x98BE65
  defp default_success(:light), do: 0x50A14F
end
