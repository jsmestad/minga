defmodule Minga.Extensions.ThemePacks.Catppuccin do
  @moduledoc "Bundled Catppuccin theme pack: Frappe, Latte, Macchiato, and Mocha."

  use Minga.Extension

  @impl true
  @spec name() :: atom()
  def name, do: :catppuccin_theme_pack

  @impl true
  @spec description() :: String.t()
  def description, do: "Catppuccin theme family (Frappe, Latte, Macchiato, Mocha)"

  @impl true
  @spec version() :: String.t()
  def version, do: "0.1.0"

  @impl true
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(_config) do
    case Minga.Extensions.ThemePacks.register_pack(__MODULE__) do
      :ok -> {:ok, %{themes: length(theme_modules())}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the palette modules owned by this pack."
  @spec theme_modules() :: [module()]
  def theme_modules do
    [
      MingaEditor.UI.Theme.CatppuccinFrappe,
      MingaEditor.UI.Theme.CatppuccinLatte,
      MingaEditor.UI.Theme.CatppuccinMacchiato,
      MingaEditor.UI.Theme.CatppuccinMocha
    ]
  end
end
