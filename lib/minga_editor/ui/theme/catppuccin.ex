defmodule MingaEditor.UI.Theme.Catppuccin do
  @moduledoc """
  Shared palette and theme builder for the Catppuccin theme family.

  Catppuccin is a community-driven pastel theme with four flavors:
  Latte (light), Frappe, Macchiato, and Mocha (darkest).
  Palette values sourced from https://github.com/catppuccin/catppuccin.

  Catppuccin recommends overlay2 at 20% to 30% opacity for selection backgrounds. Minga theme colors are opaque RGB values, so this builder uses surface2 as the solid selection approximation.
  """

  alias MingaEditor.UI.Theme.Builder
  alias MingaEditor.UI.Theme.Palette

  @doc "Builds a full `MingaEditor.UI.Theme.t()` struct from a Catppuccin palette map."
  @spec build(atom(), map()) :: MingaEditor.UI.Theme.t()
  def build(name, p) do
    Builder.from_palette(name, palette(name, p), overrides(name, p))
  end

  @spec palette(atom(), map()) :: Palette.t()
  defp palette(name, p) do
    %{
      variant: variant(name),
      bg: p.base,
      fg: p.text,
      surface: p.surface0,
      overlay: p.mantle,
      muted: p.overlay1,
      subtle: p.surface1,
      accent: p.blue,
      highlight: p.blue,
      selection_bg: p.surface2,
      error: p.red,
      warning: p.yellow,
      info: p.teal,
      success: p.green,
      match: p.teal,
      link: p.blue,
      border: p.overlay1,
      contrast_fg: p.base,
      builtin: p.red,
      functions: p.blue,
      keywords: p.mauve,
      methods: p.blue,
      operators: p.sky,
      constants: p.peach,
      strings: p.green,
      numbers: p.peach,
      type: p.yellow,
      variables: p.text,
      comments: p.overlay2,
      minga: p.mauve,
      needs_you: p.peach,
      done: p.green,
      waiting: p.overlay1,
      group: p.lavender
    }
    |> Map.merge(contrast_fixes(name))
    |> Palette.new()
  end

  # Latte is the light flavour, where several Catppuccin hues miss the contrast targets in docs/design/themes.md against `base`. These darker values keep each hue and reach 3:1 for glyphs (needs_you, warning, waiting, done) and 4.5:1 for group labels on popups.
  @spec contrast_fixes(atom()) :: map()
  defp contrast_fixes(:catppuccin_latte) do
    %{
      needs_you: 0xD35400,
      warning: 0xA86D10,
      waiting: 0x7C7F93,
      done: 0x388E25,
      group: 0x1650C0
    }
  end

  defp contrast_fixes(_name), do: %{}

  @spec variant(atom()) :: Palette.variant()
  defp variant(:catppuccin_latte), do: :light
  defp variant(_name), do: :dark

  # Line numbers are secondary text, so they need 4.5:1 against `base`.
  # overlay2 reaches it on the dark flavours and subtext1 on Latte.
  # Latte's popup and pane borders also move to overlay2 to reach 3:1.
  @spec overrides(atom(), map()) :: map()
  defp overrides(:catppuccin_latte, p) do
    %{
      syntax: syntax(p),
      gutter: %{current_fg: p.lavender, fg: p.subtext1},
      popup: %{border_fg: p.overlay2},
      editor: %{split_border_fg: p.overlay2}
    }
  end

  defp overrides(_name, p) do
    %{
      syntax: syntax(p),
      gutter: %{current_fg: p.lavender, fg: p.overlay2}
    }
  end

  @spec syntax(map()) :: MingaEditor.UI.Theme.syntax()
  defp syntax(p) do
    %{
      "string.special.regex" => [fg: p.pink],
      "string.escape" => [fg: p.pink],
      "string.regex" => [fg: p.pink],
      "character" => [fg: p.red],
      "variable.parameter" => [fg: p.maroon],
      "variable.member" => [fg: p.blue],
      "parameter" => [fg: p.maroon],
      "field" => [fg: p.blue],
      "attribute" => [fg: p.yellow],
      "property" => [fg: p.blue],
      "tag.attribute" => [fg: p.yellow],
      "escape" => [fg: p.pink],
      "constructor" => [fg: p.sapphire, bold: true]
    }
  end
end
