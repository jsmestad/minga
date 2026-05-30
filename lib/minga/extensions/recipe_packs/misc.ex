defmodule Minga.Extensions.RecipePacks.Misc do
  @moduledoc "Bundled recipe pack: miscellaneous language tools not grouped by ecosystem."

  use Minga.Extension.Editor

  alias Minga.Tool.Recipe

  @impl true
  @spec name() :: atom()
  def name, do: :misc_recipe_pack

  @impl true
  @spec description() :: String.t()
  def description,
    do: "Miscellaneous tool recipes (Lua, Haskell, OCaml, Swift, Nix, C#, Terraform)"

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
        name: :lua_language_server,
        label: "lua-language-server",
        description: "Lua language server by sumneko",
        provides: ["lua-language-server"],
        method: :github_release,
        package: "LuaLS/lua-language-server",
        homepage: "https://github.com/LuaLS/lua-language-server",
        category: :lsp_server,
        languages: [:lua]
      },
      %Recipe{
        name: :stylua,
        label: "StyLua",
        description: "Opinionated Lua code formatter",
        provides: ["stylua"],
        method: :github_release,
        package: "JohnnyMorganz/StyLua",
        homepage: "https://github.com/JohnnyMorganz/StyLua",
        category: :formatter,
        languages: [:lua]
      },
      %Recipe{
        name: :omnisharp,
        label: "OmniSharp",
        description: "C# language server powered by Roslyn",
        provides: ["omnisharp"],
        method: :github_release,
        package: "OmniSharp/omnisharp-roslyn",
        homepage: "https://github.com/OmniSharp/omnisharp-roslyn",
        category: :lsp_server,
        languages: [:c_sharp]
      },
      %Recipe{
        name: :sourcekit_lsp,
        label: "SourceKit-LSP",
        description: "Swift language server bundled with the Swift toolchain",
        provides: ["sourcekit-lsp"],
        method: :github_release,
        package: "apple/sourcekit-lsp",
        homepage: "https://github.com/apple/sourcekit-lsp",
        category: :lsp_server,
        languages: [:swift]
      },
      %Recipe{
        name: :haskell_language_server,
        label: "Haskell Language Server",
        description: "Language server for Haskell",
        provides: ["haskell-language-server-wrapper"],
        method: :github_release,
        package: "haskell/haskell-language-server",
        homepage: "https://github.com/haskell/haskell-language-server",
        category: :lsp_server,
        languages: [:haskell]
      },
      %Recipe{
        name: :ocamllsp,
        label: "OCaml LSP",
        description: "Language server for OCaml (install via opam install ocaml-lsp-server)",
        provides: ["ocamllsp"],
        method: :github_release,
        package: "ocaml-lsp-server",
        homepage: "https://github.com/ocaml/ocaml-lsp",
        category: :lsp_server,
        languages: [:ocaml]
      },
      %Recipe{
        name: :nil_ls,
        label: "nil",
        description: "Language server for Nix",
        provides: ["nil"],
        method: :github_release,
        package: "oxalica/nil",
        homepage: "https://github.com/oxalica/nil",
        category: :lsp_server,
        languages: [:nix]
      },
      %Recipe{
        name: :terraform_ls,
        label: "Terraform Language Server",
        description: "Language server for Terraform and HCL",
        provides: ["terraform-ls"],
        method: :github_release,
        package: "hashicorp/terraform-ls",
        homepage: "https://github.com/hashicorp/terraform-ls",
        category: :lsp_server,
        languages: [:hcl]
      }
    ]
  end
end
