defmodule Minga.Tool.Recipe.Registry do
  @moduledoc """
  ETS-backed registry of tool installation recipes.

  Holds all known recipes for installable tools (LSP servers, formatters,
  linters). Populated at startup with built-in recipes. Provides fast
  lookups by tool name, command string, and category.

  Follows the same pattern as `Minga.Language.Registry`.

  ## Lookups

  - `get/1` - look up a recipe by name atom
  - `for_command/1` - find the recipe that provides a given command string
  - `all/0` - list all recipes
  - `by_category/1` - filter recipes by category
  """

  use GenServer

  alias Minga.Tool.Recipe

  @table __MODULE__
  @command_index :"#{__MODULE__}.Commands"

  @type name :: atom()

  # ── Built-in recipes ────────────────────────────────────────────────────────

  @built_in_recipes [
    %Recipe{
      name: :expert,
      label: "Expert",
      description: "Official Elixir language server",
      provides: ["expert"],
      method: :github_release,
      package: "elixir-lang/expert",
      homepage: "https://github.com/elixir-lang/expert",
      category: :lsp_server,
      languages: [:elixir]
    },
    %Recipe{
      name: :elixir_ls,
      label: "ElixirLS",
      description: "Elixir language server with debugger support",
      provides: ["elixir-ls", "language_server.sh"],
      method: :github_release,
      package: "elixir-lsp/elixir-ls",
      homepage: "https://github.com/elixir-lsp/elixir-ls",
      category: :lsp_server,
      languages: [:elixir],
      asset_pattern: &Minga.Tool.Recipe.Registry.elixir_ls_asset?/2
    },
    %Recipe{
      name: :lexical,
      label: "Lexical",
      description: "Next-generation Elixir language server",
      provides: ["lexical", "start_lexical.sh"],
      method: :github_release,
      package: "lexical-lsp/lexical",
      homepage: "https://github.com/lexical-lsp/lexical",
      category: :lsp_server,
      languages: [:elixir],
      asset_pattern: &Minga.Tool.Recipe.Registry.lexical_asset?/2
    },
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
      name: :black,
      label: "Black",
      description: "The uncompromising Python code formatter",
      provides: ["black"],
      method: :pip,
      package: "black",
      homepage: "https://black.readthedocs.io",
      category: :formatter,
      languages: [:python]
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
      name: :zls,
      label: "ZLS",
      description: "Zig language server",
      provides: ["zls"],
      method: :github_release,
      package: "zigtools/zls",
      homepage: "https://github.com/zigtools/zls",
      category: :lsp_server,
      languages: [:zig]
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
      asset_pattern: &Minga.Tool.Recipe.Registry.clangd_asset?/2
    }
  ]

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Returns the recipe for a given tool name, or nil."
  @spec get(name()) :: Recipe.t() | nil
  def get(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, recipe}] -> recipe
      [] -> nil
    end
  end

  @doc "Returns the recipe whose `provides` list includes the given command string."
  @spec for_command(String.t()) :: Recipe.t() | nil
  def for_command(command) when is_binary(command) do
    case :ets.lookup(@command_index, command) do
      [{^command, name}] -> get(name)
      [] -> nil
    end
  end

  @doc "Returns all registered recipes."
  @spec all() :: [Recipe.t()]
  def all do
    :ets.tab2list(@table) |> Enum.map(fn {_name, recipe} -> recipe end)
  end

  @doc "Returns recipes filtered by category."
  @spec by_category(Recipe.category()) :: [Recipe.t()]
  def by_category(category) when is_atom(category) do
    all() |> Enum.filter(fn r -> r.category == category end)
  end

  @doc "Returns all recipes that serve a given language."
  @spec for_language(atom()) :: [Recipe.t()]
  def for_language(language) when is_atom(language) do
    all() |> Enum.filter(fn r -> language in r.languages end)
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) :: {:ok, %{}}
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    cmd_table = :ets.new(@command_index, [:named_table, :set, :protected, read_concurrency: true])

    for recipe <- @built_in_recipes do
      :ets.insert(table, {recipe.name, recipe})

      for command <- recipe.provides do
        :ets.insert(cmd_table, {command, recipe.name})
      end
    end

    {:ok, %{}}
  end

  # ── Asset pattern helpers ───────────────────────────────────────────────────

  @doc """
  Matches clangd release assets.

  clangd uses "mac" instead of "darwin"/"macos" and ships one binary per
  OS (no architecture in the filename, likely universal on macOS). We also
  need to exclude `clangd_indexing_tools-*` assets.
  """
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

  @doc """
  Matches ElixirLS release assets.

  ElixirLS is a BEAM application that ships a single platform-independent
  zip (e.g., `elixir-ls-v0.30.0.zip`). The default asset matcher fails
  because it looks for OS/arch strings like `darwin_arm64` in the filename.
  """
  @spec elixir_ls_asset?(String.t(), String.t()) :: boolean()
  def elixir_ls_asset?(asset_name, _platform_suffix) do
    name = String.downcase(asset_name)

    String.starts_with?(name, "elixir-ls") and
      String.ends_with?(name, ".zip")
  end

  @doc """
  Matches Lexical release assets.

  Lexical is a BEAM application that ships platform-independent zips.
  Releases include both a versioned zip (`lexical-v0.7.3.zip`) and a
  plain `lexical.zip`. We prefer the versioned one to avoid cache
  confusion across upgrades.
  """
  @spec lexical_asset?(String.t(), String.t()) :: boolean()
  def lexical_asset?(asset_name, _platform_suffix) do
    name = String.downcase(asset_name)

    String.starts_with?(name, "lexical") and
      String.ends_with?(name, ".zip") and
      String.contains?(name, "-v")
  end
end
