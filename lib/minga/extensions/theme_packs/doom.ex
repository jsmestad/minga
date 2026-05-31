defmodule Minga.Extensions.ThemePacks.Doom do
  @moduledoc "Bundled Doom theme pack: Doom One."

  use Minga.Extension.Editor

  @impl true
  @spec name() :: atom()
  def name, do: :doom_theme_pack

  @impl true
  @spec description() :: String.t()
  def description, do: "Doom Emacs theme family (Doom One)"

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
    [MingaEditor.UI.Theme.DoomOne]
  end
end
