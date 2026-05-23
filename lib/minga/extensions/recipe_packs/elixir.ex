defmodule Minga.Extensions.RecipePacks.Elixir do
  @moduledoc "Bundled recipe pack: Elixir ecosystem tools."

  use Minga.Extension

  alias Minga.Tool.Recipe

  @impl true
  @spec name() :: atom()
  def name, do: :elixir_recipe_pack

  @impl true
  @spec description() :: String.t()
  def description, do: "Elixir ecosystem tool recipes (Expert)"

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
        name: :expert,
        label: "Expert",
        description: "Official Elixir language server",
        provides: ["expert"],
        method: :github_release,
        package: "expert-lsp/expert",
        homepage: "https://github.com/expert-lsp/expert",
        category: :lsp_server,
        languages: [:elixir],
        asset_pattern: &expert_asset?/2
      },
      %Recipe{
        name: :erlang_ls,
        label: "Erlang Language Server",
        description: "Language server for Erlang and OTP",
        provides: ["erlang_ls"],
        method: :github_release,
        package: "erlang-ls/erlang_ls",
        homepage: "https://github.com/erlang-ls/erlang_ls",
        category: :lsp_server,
        languages: [:erlang]
      },
      %Recipe{
        name: :gleam_lsp,
        label: "Gleam LSP",
        description: "Language server for Gleam (built into gleam binary)",
        provides: ["gleam"],
        method: :github_release,
        package: "gleam-lang/gleam",
        homepage: "https://gleam.run",
        category: :lsp_server,
        languages: [:gleam]
      }
    ]
  end

  @doc "Matches Expert release assets (bare platform binaries, e.g. `expert_darwin_arm64`)."
  @spec expert_asset?(String.t(), String.t()) :: boolean()
  def expert_asset?(asset_name, platform_suffix) do
    name = String.downcase(asset_name)
    suffix = String.downcase(platform_suffix)
    String.starts_with?(name, "expert_") and String.contains?(name, suffix)
  end
end
