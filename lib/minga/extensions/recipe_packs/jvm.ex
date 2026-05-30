defmodule Minga.Extensions.RecipePacks.Jvm do
  @moduledoc "Bundled recipe pack: JVM ecosystem tools."

  use Minga.Extension.Editor

  alias Minga.Tool.Recipe

  @impl true
  @spec name() :: atom()
  def name, do: :jvm_recipe_pack

  @impl true
  @spec description() :: String.t()
  def description, do: "JVM ecosystem tool recipes (JDTLS, Kotlin, Scala)"

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
        name: :jdtls,
        label: "Eclipse JDT Language Server",
        description: "Java language server powered by Eclipse",
        provides: ["jdtls"],
        method: :github_release,
        package: "eclipse-jdtls/eclipse.jdt.ls",
        homepage: "https://github.com/eclipse-jdtls/eclipse.jdt.ls",
        category: :lsp_server,
        languages: [:java]
      },
      %Recipe{
        name: :kotlin_language_server,
        label: "Kotlin Language Server",
        description: "Kotlin language server",
        provides: ["kotlin-language-server"],
        method: :github_release,
        package: "fwcd/kotlin-language-server",
        homepage: "https://github.com/fwcd/kotlin-language-server",
        category: :lsp_server,
        languages: [:kotlin]
      },
      %Recipe{
        name: :metals,
        label: "Metals",
        description: "Language server for Scala powered by the compiler",
        provides: ["metals"],
        method: :github_release,
        package: "scalameta/metals",
        homepage: "https://scalameta.org/metals",
        category: :lsp_server,
        languages: [:scala]
      }
    ]
  end
end
