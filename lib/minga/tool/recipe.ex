defmodule Minga.Tool.Recipe do
  @moduledoc """
  A recipe describing how to install a development tool (LSP server, formatter, etc.).

  Recipes are the "what" and "how" of tool installation. They live in
  `Tool.Recipe.Registry`, separate from language definitions. The link
  between tools and languages is implicit through the command string:
  if `ServerConfig.command == "expert"` and a recipe provides `"expert"`,
  the tool manager can offer to install it.

  ## Fields

  - `:name` - unique atom identifier (e.g., `:pyright`)
  - `:label` - human-readable display name (e.g., "Pyright")
  - `:description` - one-line description for the picker/manager UI
  - `:provides` - list of command strings this tool makes available
  - `:method` - installer method atom (`:npm`, `:pip`, `:cargo`, `:go_install`, `:github_release`)
  - `:package` - package identifier (npm package name, GitHub "owner/repo", pip package, etc.)
  - `:version` - version constraint or `"latest"`
  - `:homepage` - URL for the tool's homepage/docs
  - `:category` - UI grouping (`:lsp_server`, `:formatter`, `:linter`, `:debugger`)
  - `:languages` - list of language atoms this tool serves (for UI grouping)
  - `:asset_pattern` - optional function for GitHub release asset matching

  ## Example

      %Recipe{
        name: :pyright,
        label: "Pyright",
        description: "Fast Python type checker and language server",
        provides: ["pyright-langserver"],
        method: :npm,
        package: "pyright",
        version: "latest",
        homepage: "https://github.com/microsoft/pyright",
        category: :lsp_server,
        languages: [:python]
      }
  """

  @enforce_keys [:name, :label, :description, :provides, :method, :package]
  defstruct [
    :name,
    :label,
    :description,
    :provides,
    :method,
    :package,
    :homepage,
    :asset_pattern,
    version: "latest",
    category: :lsp_server,
    languages: []
  ]

  @type category :: :lsp_server | :formatter | :linter | :debugger

  @type t :: %__MODULE__{
          name: atom(),
          label: String.t(),
          description: String.t(),
          provides: [String.t()],
          method: :npm | :pip | :cargo | :go_install | :github_release,
          package: String.t(),
          version: String.t(),
          homepage: String.t() | nil,
          category: category(),
          languages: [atom()],
          asset_pattern: (String.t(), String.t() -> boolean()) | nil
        }
end
