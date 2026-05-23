defmodule Minga.Extensions.ThemePacks.One do
  @moduledoc "Bundled One theme pack: One Dark and One Light."

  use Minga.Extension

  @impl true
  @spec name() :: atom()
  def name, do: :one_theme_pack

  @impl true
  @spec description() :: String.t()
  def description, do: "Atom One theme family (One Dark, One Light)"

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
      MingaEditor.UI.Theme.OneDark,
      MingaEditor.UI.Theme.OneLight
    ]
  end
end
