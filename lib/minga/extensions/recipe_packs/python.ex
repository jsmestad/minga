defmodule Minga.Extensions.RecipePacks.Python do
  @moduledoc "Bundled recipe pack: Python ecosystem tools."

  use Minga.Extension.Editor

  alias Minga.Tool.Recipe

  @impl true
  @spec name() :: atom()
  def name, do: :python_recipe_pack

  @impl true
  @spec description() :: String.t()
  def description, do: "Python ecosystem tool recipes (Pyright, Black)"

  @impl true
  @spec version() :: String.t()
  def version, do: "0.1.0"

  @impl true
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(_config) do
    case Minga.Extensions.RecipePacks.register_pack(__MODULE__) do
      :ok -> {:ok, %{recipes: length(recipes())}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the recipes owned by this pack."
  @spec recipes() :: [Recipe.t()]
  def recipes do
    [
      %Recipe{
        name: :pyright,
        label: "Pyright",
        description: "Fast Python type checker and language server",
        provides: ["pyright-langserver", "pyright"],
        method: :npm,
        package: "pyright",
        homepage: "https://github.com/microsoft/pyright",
        category: :lsp_server,
        languages: [:python]
      },
      %Recipe{
        name: :black,
        label: "Black",
        description: "The uncompromising Python code formatter",
        provides: ["black"],
        method: :pip,
        package: "black",
        homepage: "https://black.readthedocs.io",
        category: :formatter,
        languages: [:python]
      }
    ]
  end
end
