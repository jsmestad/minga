defmodule Minga.UI.Theme.CatppuccinLatte do
  @moduledoc "Catppuccin Latte (light) theme."

  @palette %{
    rosewater: 0xDC8A78,
    flamingo: 0xDD7878,
    pink: 0xEA76CB,
    mauve: 0x8839EF,
    red: 0xD20F39,
    maroon: 0xE64553,
    peach: 0xFE640B,
    yellow: 0xDF8E1D,
    green: 0x40A02B,
    teal: 0x179299,
    sky: 0x04A5E5,
    sapphire: 0x209FB5,
    blue: 0x1E66F5,
    lavender: 0x7287FD,
    text: 0x4C4F69,
    subtext1: 0x5C5F77,
    subtext0: 0x6C6F85,
    overlay2: 0x7C7F93,
    overlay1: 0x8C8FA1,
    overlay0: 0x9CA0B0,
    surface2: 0xACB0BE,
    surface1: 0xBCC0CC,
    surface0: 0xCCD0DA,
    base: 0xEFF1F5,
    mantle: 0xE6E9EF,
    crust: 0xDCE0E8
  }

  alias Minga.UI.Theme.Catppuccin

  @doc "Returns the Catppuccin Latte theme struct."
  @spec theme() :: Minga.UI.Theme.t()
  def theme, do: Catppuccin.build(:catppuccin_latte, @palette)
end
