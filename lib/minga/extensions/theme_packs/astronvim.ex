defmodule Minga.Extensions.ThemePacks.AstroNvim do
  @moduledoc "Bundled AstroNvim theme pack: AstroDark."

  use Minga.Extension.Editor

  @impl true
  @spec name() :: atom()
  def name, do: :astronvim_theme_pack

  @impl true
  @spec description() :: String.t()
  def description, do: "AstroNvim astrotheme family (AstroDark)"

  @impl true
  @spec version() :: String.t()
  def version, do: "0.1.0"

  @impl true
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(_config) do
    case Minga.Extensions.ThemePacks.register_pack(__MODULE__) do
      :ok -> {:ok, %{themes: Enum.count(theme_modules())}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the palette modules owned by this pack."
  @spec theme_modules() :: [module()]
  def theme_modules do
    [
      MingaEditor.UI.Theme.AstroDark
    ]
  end
end
