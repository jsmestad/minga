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
  @source_table :"#{__MODULE__}.Sources"

  @type name :: atom()
  @typedoc "Source that contributed registry entries."
  @type contribution_source :: :builtin | :config | {:extension, atom()}
  @type register_error ::
          {:duplicate_recipe, atom(), contribution_source(), contribution_source()}

  # ── Built-in recipes ────────────────────────────────────────────────────────

  @built_in_recipes [
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
      asset_pattern: &Minga.Tool.Recipe.Registry.expert_asset?/2
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
    },
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
      name: :dart_language_server,
      label: "Dart Language Server",
      description: "Dart language server built into the Dart SDK (install Dart SDK first)",
      provides: ["dart"],
      method: :github_release,
      package: "dart-lang/sdk",
      homepage: "https://dart.dev",
      category: :lsp_server,
      languages: [:dart]
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
      name: :erlang_ls,
      label: "Erlang Language Server",
      description: "Language server for Erlang and OTP",
      provides: ["erlang_ls"],
      method: :github_release,
      package: "erlang-ls/erlang_ls",
      homepage: "https://erlang-ls.github.io",
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
      name: :metals,
      label: "Metals",
      description: "Language server for Scala powered by the compiler",
      provides: ["metals"],
      method: :github_release,
      package: "scalameta/metals",
      homepage: "https://scalameta.org/metals",
      category: :lsp_server,
      languages: [:scala]
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

  @doc "Registers a config-owned recipe."
  @spec register(Recipe.t()) :: :ok | {:error, register_error()}
  def register(%Recipe{} = recipe), do: register(recipe, :config)

  @doc "Registers a recipe with explicit source ownership."
  @spec register(Recipe.t(), contribution_source()) :: :ok | {:error, register_error()}
  def register(%Recipe{} = recipe, source) do
    GenServer.call(__MODULE__, {:register, recipe, source})
  end

  @doc "Removes every recipe contributed by a source."
  @spec unregister_source(contribution_source()) :: :ok
  def unregister_source(source) do
    GenServer.call(__MODULE__, {:unregister_source, source})
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) ::
          {:ok, %{table: :ets.table(), command_index: :ets.table(), source_table: :ets.table()}}
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    cmd_table = :ets.new(@command_index, [:named_table, :set, :protected, read_concurrency: true])

    source_table =
      :ets.new(@source_table, [:named_table, :set, :protected, read_concurrency: true])

    for recipe <- @built_in_recipes do
      insert_recipe(table, cmd_table, source_table, recipe, :builtin)
    end

    {:ok, %{table: table, command_index: cmd_table, source_table: source_table}}
  end

  @impl true
  def handle_call({:register, %Recipe{} = recipe, source}, _from, state) do
    reply =
      with :ok <- validate_recipe_source(state.command_index, state.source_table, recipe, source) do
        insert_recipe(state.table, state.command_index, state.source_table, recipe, source)
      end

    {:reply, reply, state}
  end

  def handle_call({:unregister_source, source}, _from, state) do
    unregister_source_recipes(state.table, state.command_index, state.source_table, source)
    {:reply, :ok, state}
  end

  @spec validate_recipe_source(:ets.table(), :ets.table(), Recipe.t(), contribution_source()) ::
          :ok | {:error, register_error()}
  defp validate_recipe_source(cmd_table, source_table, %Recipe{} = recipe, source) do
    with :ok <- validate_recipe_name_source(source_table, recipe.name, source) do
      Enum.reduce_while(recipe.provides, :ok, fn command, :ok ->
        validate_command_source(cmd_table, source_table, command, source)
      end)
    end
  end

  @spec validate_recipe_name_source(:ets.table(), atom(), contribution_source()) ::
          :ok | {:error, register_error()}
  defp validate_recipe_name_source(source_table, name, source) do
    case :ets.lookup(source_table, name) do
      [{^name, ^source}] -> :ok
      [{^name, existing_source}] -> {:error, {:duplicate_recipe, name, existing_source, source}}
      [] -> :ok
    end
  end

  @spec validate_command_source(:ets.table(), :ets.table(), String.t(), contribution_source()) ::
          {:cont, :ok} | {:halt, {:error, register_error()}}
  defp validate_command_source(cmd_table, source_table, command, source) do
    case :ets.lookup(cmd_table, command) do
      [{^command, name}] -> validate_command_recipe_source(source_table, name, source)
      [] -> {:cont, :ok}
    end
  end

  @spec validate_command_recipe_source(:ets.table(), atom(), contribution_source()) ::
          {:cont, :ok} | {:halt, {:error, register_error()}}
  defp validate_command_recipe_source(source_table, name, source) do
    case validate_recipe_name_source(source_table, name, source) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @spec insert_recipe(:ets.table(), :ets.table(), :ets.table(), Recipe.t(), contribution_source()) ::
          :ok
  defp insert_recipe(table, cmd_table, source_table, %Recipe{} = recipe, source) do
    remove_recipe_indexes(table, cmd_table, recipe.name)
    :ets.insert(table, {recipe.name, recipe})
    :ets.insert(source_table, {recipe.name, source})

    for command <- recipe.provides do
      :ets.insert(cmd_table, {command, recipe.name})
    end

    :ok
  end

  @spec remove_recipe_indexes(:ets.table(), :ets.table(), atom()) :: :ok
  defp remove_recipe_indexes(table, cmd_table, name) do
    case :ets.lookup(table, name) do
      [{^name, %Recipe{} = old_recipe}] ->
        for command <- old_recipe.provides, do: :ets.delete(cmd_table, command)

      [] ->
        :ok
    end

    :ok
  end

  @spec unregister_source_recipes(:ets.table(), :ets.table(), :ets.table(), contribution_source()) ::
          :ok
  defp unregister_source_recipes(table, cmd_table, source_table, source) do
    source_table
    |> :ets.tab2list()
    |> Enum.each(fn
      {name, ^source} ->
        remove_recipe_indexes(table, cmd_table, name)
        :ets.delete(table, name)
        :ets.delete(source_table, name)

      _entry ->
        :ok
    end)

    :ok
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
  Matches Expert release assets.

  Expert ships bare platform binaries with no archive extension
  (e.g., `expert_darwin_arm64`, `expert_linux_amd64`).
  """
  @spec expert_asset?(String.t(), String.t()) :: boolean()
  def expert_asset?(asset_name, platform_suffix) do
    name = String.downcase(asset_name)
    suffix = String.downcase(platform_suffix)
    String.starts_with?(name, "expert_") and String.contains?(name, suffix)
  end
end
