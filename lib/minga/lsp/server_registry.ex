defmodule Minga.LSP.ServerRegistry do
  @moduledoc """
  Maps filetypes to language server configurations.

  A pure module with hardcoded defaults for well-known language servers,
  following the pattern established by `Minga.Filetype`. No GenServer,
  no config files — if the server binary is on `$PATH`, it just works.

  ## Adding a new server

  Add an entry to `@servers` mapping a filetype atom to a list of
  `server_config()` structs. Multiple servers per filetype are supported
  (e.g., TypeScript files may use both `typescript-language-server` and
  `eslint`).

  ## Future

  A config file (`~/.config/minga/lsp.exs`) will allow users to override
  or extend these defaults without modifying source code.
  """

  @typedoc "Configuration for a single language server."
  @type server_config :: %{
          name: atom(),
          command: String.t(),
          args: [String.t()],
          root_markers: [String.t()],
          init_options: map()
        }

  @servers %{
    elixir: [
      %{
        name: :lexical,
        command: "lexical",
        args: [],
        root_markers: ["mix.exs"],
        init_options: %{}
      }
    ],
    go: [
      %{
        name: :gopls,
        command: "gopls",
        args: [],
        root_markers: ["go.mod", "go.sum"],
        init_options: %{}
      }
    ],
    rust: [
      %{
        name: :rust_analyzer,
        command: "rust-analyzer",
        args: [],
        root_markers: ["Cargo.toml"],
        init_options: %{}
      }
    ],
    c: [
      %{
        name: :clangd,
        command: "clangd",
        args: [],
        root_markers: ["compile_commands.json", "CMakeLists.txt", ".clangd"],
        init_options: %{}
      }
    ],
    cpp: [
      %{
        name: :clangd,
        command: "clangd",
        args: [],
        root_markers: ["compile_commands.json", "CMakeLists.txt", ".clangd"],
        init_options: %{}
      }
    ],
    javascript: [
      %{
        name: :typescript_language_server,
        command: "typescript-language-server",
        args: ["--stdio"],
        root_markers: ["package.json", "tsconfig.json", "jsconfig.json"],
        init_options: %{}
      }
    ],
    typescript: [
      %{
        name: :typescript_language_server,
        command: "typescript-language-server",
        args: ["--stdio"],
        root_markers: ["package.json", "tsconfig.json"],
        init_options: %{}
      }
    ],
    python: [
      %{
        name: :pyright,
        command: "pyright-langserver",
        args: ["--stdio"],
        root_markers: ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"],
        init_options: %{}
      }
    ],
    ruby: [
      %{
        name: :solargraph,
        command: "solargraph",
        args: ["stdio"],
        root_markers: ["Gemfile", ".solargraph.yml"],
        init_options: %{}
      }
    ],
    zig: [
      %{
        name: :zls,
        command: "zls",
        args: [],
        root_markers: ["build.zig", "build.zig.zon"],
        init_options: %{}
      }
    ],
    lua: [
      %{
        name: :lua_ls,
        command: "lua-language-server",
        args: [],
        root_markers: [".luarc.json", ".luarc.jsonc", ".stylua.toml"],
        init_options: %{}
      }
    ],
    json: [
      %{
        name: :vscode_json_languageserver,
        command: "vscode-json-language-server",
        args: ["--stdio"],
        root_markers: [],
        init_options: %{}
      }
    ],
    yaml: [
      %{
        name: :yaml_language_server,
        command: "yaml-language-server",
        args: ["--stdio"],
        root_markers: [],
        init_options: %{}
      }
    ],
    css: [
      %{
        name: :vscode_css_languageserver,
        command: "vscode-css-language-server",
        args: ["--stdio"],
        root_markers: ["package.json"],
        init_options: %{}
      }
    ],
    html: [
      %{
        name: :vscode_html_languageserver,
        command: "vscode-html-language-server",
        args: ["--stdio"],
        root_markers: ["package.json"],
        init_options: %{}
      }
    ],
    bash: [
      %{
        name: :bash_language_server,
        command: "bash-language-server",
        args: ["start"],
        root_markers: [],
        init_options: %{}
      }
    ]
  }

  @doc """
  Returns the list of language server configs for a filetype.

  Returns an empty list if no servers are configured for the filetype.

  ## Examples

      iex> configs = Minga.LSP.ServerRegistry.servers_for(:elixir)
      iex> length(configs)
      1
      iex> hd(configs).name
      :lexical

      iex> Minga.LSP.ServerRegistry.servers_for(:unknown_language)
      []
  """
  @spec servers_for(atom()) :: [server_config()]
  def servers_for(filetype) when is_atom(filetype) do
    Map.get(@servers, filetype, [])
  end

  @doc """
  Returns all filetypes that have at least one server configured.

  ## Examples

      iex> filetypes = Minga.LSP.ServerRegistry.supported_filetypes()
      iex> :elixir in filetypes
      true
  """
  @spec supported_filetypes() :: [atom()]
  def supported_filetypes do
    Map.keys(@servers)
  end

  @doc """
  Checks if a server's command binary is available on `$PATH`.

  ## Examples

      iex> config = %{name: :test, command: "nonexistent_binary_xyz", args: [], root_markers: [], init_options: %{}}
      iex> Minga.LSP.ServerRegistry.available?(config)
      false
  """
  @spec available?(server_config()) :: boolean()
  def available?(%{command: command}) when is_binary(command) do
    System.find_executable(command) != nil
  end

  @doc """
  Returns only the available servers for a filetype (binary found on PATH).

  Filters `servers_for/1` through `available?/1`.
  """
  @spec available_servers_for(atom()) :: [server_config()]
  def available_servers_for(filetype) when is_atom(filetype) do
    filetype
    |> servers_for()
    |> Enum.filter(&available?/1)
  end
end
