defmodule MingaEditor.UI.Theme.CatppuccinMocha do
  @moduledoc "Catppuccin Mocha (darkest) theme."

  @palette %{
    rosewater: 0xF5E0DC,
    flamingo: 0xF2CDCD,
    pink: 0xF5C2E7,
    mauve: 0xCBA6F7,
    red: 0xF38BA8,
    maroon: 0xEBA0AC,
    peach: 0xFAB387,
    yellow: 0xF9E2AF,
    green: 0xA6E3A1,
    teal: 0x94E2D5,
    sky: 0x89DCEB,
    sapphire: 0x74C7EC,
    blue: 0x89B4FA,
    lavender: 0xB4BEFE,
    text: 0xCDD6F4,
    subtext1: 0xBAC2DE,
    subtext0: 0xA6ADC8,
    overlay2: 0x9399B2,
    overlay1: 0x7F849C,
    overlay0: 0x6C7086,
    surface2: 0x585B70,
    surface1: 0x45475A,
    surface0: 0x313244,
    base: 0x1E1E2E,
    mantle: 0x181825,
    crust: 0x11111B
  }

  alias MingaEditor.UI.Theme.Catppuccin

  @doc "Returns the Catppuccin Mocha theme struct."
  @spec theme() :: MingaEditor.UI.Theme.t()
  def theme, do: Catppuccin.build(:catppuccin_mocha, @palette)
end
