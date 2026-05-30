defmodule Minga.Extensions.RecipePacks.Systems do
  @moduledoc "Bundled recipe pack: systems programming ecosystem tools."

  use Minga.Extension.Editor

  alias Minga.Tool.Recipe

  @impl true
  @spec name() :: atom()
  def name, do: :systems_recipe_pack

  @impl true
  @spec description() :: String.t()
  def description, do: "Systems ecosystem tool recipes (rust-analyzer, gopls, clangd, ZLS)"

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
        name: :rust_analyzer,
        label: "rust-analyzer",
        description: "Official Rust language server",
        provides: ["rust-analyzer"],
        method: :github_release,
        package: "rust-lang/rust-analyzer",
        homepage: "https://rust-analyzer.github.io",
        category: :lsp_server,
        languages: [:rust]
      },
      %Recipe{
        name: :gopls,
        label: "gopls",
        description: "Official Go language server",
        provides: ["gopls"],
        method: :go_install,
        package: "golang.org/x/tools/gopls",
        homepage: "https://pkg.go.dev/golang.org/x/tools/gopls",
        category: :lsp_server,
        languages: [:go]
      },
      %Recipe{
        name: :clangd,
        label: "clangd",
        description: "C/C++ language server from LLVM",
        provides: ["clangd"],
        method: :github_release,
        package: "clangd/clangd",
        homepage: "https://clangd.llvm.org",
        category: :lsp_server,
        languages: [:c, :cpp],
        asset_pattern: &clangd_asset?/2
      },
      %Recipe{
        name: :zls,
        label: "ZLS",
        description: "Zig language server",
        provides: ["zls"],
        method: :github_release,
        package: "zigtools/zls",
        homepage: "https://github.com/zigtools/zls",
        category: :lsp_server,
        languages: [:zig]
      }
    ]
  end

  @doc "Matches clangd release assets (uses 'mac' instead of 'darwin', excludes indexing tools)."
  @spec clangd_asset?(String.t(), String.t()) :: boolean()
  def clangd_asset?(asset_name, platform_suffix) do
    name = String.downcase(asset_name)
    os_token = clangd_os_token(platform_suffix)

    String.starts_with?(name, "clangd-") and
      String.contains?(name, os_token) and
      String.ends_with?(name, ".zip")
  end

  @spec clangd_os_token(String.t()) :: String.t()
  defp clangd_os_token("darwin_" <> _), do: "mac"
  defp clangd_os_token("linux_" <> _), do: "linux"
  defp clangd_os_token("windows_" <> _), do: "windows"
  defp clangd_os_token(_), do: "unknown"
end
