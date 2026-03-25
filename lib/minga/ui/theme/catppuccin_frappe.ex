defmodule Minga.UI.Theme.CatppuccinFrappe do
  @moduledoc "Catppuccin Frappé (medium-dark) theme."

  @palette %{
    rosewater: 0xF2D5CF,
    flamingo: 0xEEBEBE,
    pink: 0xF4B8E4,
    mauve: 0xCA9EE6,
    red: 0xE78284,
    maroon: 0xEA999C,
    peach: 0xEF9F76,
    yellow: 0xE5C890,
    green: 0xA6D189,
    teal: 0x81C8BE,
    sky: 0x99D1DB,
    sapphire: 0x85C1DC,
    blue: 0x8CAAEE,
    lavender: 0xBABBF1,
    text: 0xC6D0F5,
    subtext1: 0xB5BFE2,
    subtext0: 0xA5ADCE,
    overlay2: 0x949CBB,
    overlay1: 0x838BA7,
    overlay0: 0x737994,
    surface2: 0x626880,
    surface1: 0x51576D,
    surface0: 0x414559,
    base: 0x303446,
    mantle: 0x292C3C,
    crust: 0x232634
  }

  alias Minga.UI.Theme.Catppuccin

  @doc "Returns the Catppuccin Frappé theme struct."
  @spec theme() :: Minga.UI.Theme.t()
  def theme, do: Catppuccin.build(:catppuccin_frappe, @palette)
end
