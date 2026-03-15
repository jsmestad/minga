defmodule Minga.LSP.ServerRegistry do
  @moduledoc """
  Maps filetypes to language server configurations.

  A pure module with hardcoded defaults for well-known language servers,
  following the pattern established by `Minga.Filetype`. No GenServer,
  no config files — if the server binary is on `$PATH`, it just works.

  ## Adding a new server

  Add an entry to `@servers` mapping a filetype atom to a list of
  `ServerConfig` structs. Multiple servers per filetype are supported
  (e.g., TypeScript files may use both `typescript-language-server` and
  `eslint`).

  ## Future

  A config file (`~/.config/minga/lsp.exs`) will allow users to override
  or extend these defaults without modifying source code.
  """

  alias Minga.Language.Registry, as: LangRegistry
  alias Minga.LSP.ServerConfig

  @typedoc "Configuration for a single language server."
  @type server_config :: ServerConfig.t()

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
    case LangRegistry.get(filetype) do
      %{language_servers: servers} when is_list(servers) -> servers
      _ -> []
    end
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
    LangRegistry.all()
    |> Enum.filter(fn lang -> lang.language_servers != [] end)
    |> Enum.map(fn lang -> lang.name end)
  end

  @doc """
  Checks if a server's command binary is available on `$PATH`.

  ## Examples

      iex> config = %Minga.LSP.ServerConfig{name: :test, command: "nonexistent_binary_xyz"}
      iex> Minga.LSP.ServerRegistry.available?(config)
      false
  """
  @spec available?(server_config()) :: boolean()
  def available?(%ServerConfig{command: command}) when is_binary(command) do
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

  @doc """
  Finds a server config by name across all filetypes.

  Returns `nil` if no server with the given name is registered.
  """
  @spec find_config(atom()) :: server_config() | nil
  def find_config(server_name) when is_atom(server_name) do
    LangRegistry.all()
    |> Enum.flat_map(fn lang -> lang.language_servers end)
    |> Enum.find(fn %ServerConfig{name: name} -> name == server_name end)
  end
end
