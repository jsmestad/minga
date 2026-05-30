defmodule Minga.Extensions.RecipePacks.Web do
  @moduledoc "Bundled recipe pack: Web ecosystem tools."

  use Minga.Extension.Editor

  alias Minga.Tool.Recipe

  @impl true
  @spec name() :: atom()
  def name, do: :web_recipe_pack

  @impl true
  @spec description() :: String.t()
  def description, do: "Web ecosystem tool recipes (TypeScript, Prettier, PHP, Dart)"

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
        name: :typescript_language_server,
        label: "TypeScript Language Server",
        description: "TypeScript and JavaScript language server",
        provides: ["typescript-language-server"],
        method: :npm,
        package: "typescript-language-server",
        homepage: "https://github.com/typescript-language-server/typescript-language-server",
        category: :lsp_server,
        languages: [:typescript, :javascript]
      },
      %Recipe{
        name: :prettier,
        label: "Prettier",
        description: "Opinionated code formatter for web languages",
        provides: ["prettier"],
        method: :npm,
        package: "prettier",
        homepage: "https://prettier.io",
        category: :formatter,
        languages: [:javascript, :typescript, :html, :css, :json, :markdown]
      },
      %Recipe{
        name: :intelephense,
        label: "Intelephense",
        description: "PHP language server with code intelligence",
        provides: ["intelephense"],
        method: :npm,
        package: "intelephense",
        homepage: "https://intelephense.com",
        category: :lsp_server,
        languages: [:php]
      },
      %Recipe{
        name: :dart_language_server,
        label: "Dart Language Server",
        description: "Dart language server built into the Dart SDK (install Dart SDK first)",
        provides: ["dart"],
        method: :github_release,
        package: "dart-lang/sdk",
        homepage: "https://dart.dev",
        category: :lsp_server,
        languages: [:dart]
      }
    ]
  end
end
