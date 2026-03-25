defmodule Minga.UI.Theme.CatppuccinMacchiato do
  @moduledoc "Catppuccin Macchiato (dark) theme."

  @palette %{
    rosewater: 0xF4DBD6,
    flamingo: 0xF0C6C6,
    pink: 0xF5BDE6,
    mauve: 0xC6A0F6,
    red: 0xED8796,
    maroon: 0xEE99A0,
    peach: 0xF5A97F,
    yellow: 0xEED49F,
    green: 0xA6DA95,
    teal: 0x8BD5CA,
    sky: 0x91D7E3,
    sapphire: 0x7DC4E4,
    blue: 0x8AADF4,
    lavender: 0xB7BDF8,
    text: 0xCAD3F5,
    subtext1: 0xB8C0E0,
    subtext0: 0xA5ADCB,
    overlay2: 0x939AB7,
    overlay1: 0x8087A2,
    overlay0: 0x6E738D,
    surface2: 0x5B6078,
    surface1: 0x494D64,
    surface0: 0x363A4F,
    base: 0x24273A,
    mantle: 0x1E2030,
    crust: 0x181926
  }

  alias Minga.UI.Theme.Catppuccin

  @doc "Returns the Catppuccin Macchiato theme struct."
  @spec theme() :: Minga.UI.Theme.t()
  def theme, do: Catppuccin.build(:catppuccin_macchiato, @palette)
end
