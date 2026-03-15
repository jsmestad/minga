defmodule Minga.Command.Registry do
  @moduledoc """
  ETS-backed registry for named editor commands.

  Commands are stored by name (atom) in an ETS table with
  `read_concurrency: true` for lock-free lookups on the hot path
  (every keystroke dispatches through this registry).

  ## Built-in commands

  At startup, the registry aggregates commands from all modules that
  implement `Minga.Command.Provider`. Each provider declares its
  commands via `__commands__/0`. Adding a new command means adding
  one entry in the sub-module that implements it. Zero changes here.

  ## Extension commands

  Extensions register commands at runtime via `register/4` or
  `Minga.Config.command/3`. Both paths write to the same ETS table,
  so extension commands are immediately dispatchable through the same
  `Minga.Editor.Commands.execute/2` lookup.

  ## Usage

      {:ok, _pid} = Minga.Command.Registry.start_link(name: MyRegistry)
      {:ok, cmd} = Minga.Command.Registry.lookup(MyRegistry, :save)
  """

  use GenServer

  alias Minga.Command

  @typedoc "Registry server name or pid. Used as the ETS table name."
  @type server :: GenServer.server()

  # Modules that implement Minga.Command.Provider.
  # The registry calls __commands__/0 on each at startup to populate
  # the ETS table. This is the ONLY place that needs updating when
  # a new command module is added.
  @command_modules [
    Minga.Editor.Commands.Movement,
    Minga.Editor.Commands.Editing,
    Minga.Editor.Commands.Operators,
    Minga.Editor.Commands.Visual,
    Minga.Editor.Commands.Search,
    Minga.Editor.Commands.Marks,
    Minga.Editor.Commands.BufferManagement,
    Minga.Editor.Commands.Folding,
    Minga.Editor.Commands.Diagnostics,
    Minga.Editor.Commands.Lsp,
    Minga.Editor.Commands.Git,
    Minga.Editor.Commands.Project,
    Minga.Editor.Commands.Agent,
    Minga.Editor.Commands.FileTree,
    Minga.Editor.Commands.Testing,
    Minga.Editor.Commands.Extensions,
    Minga.Editor.Commands.Macros,
    Minga.Editor.Commands.Formatting,
    Minga.Editor.Commands.UI
  ]

  # Compile-time check: verify no duplicate command names across providers.
  # This catches copy-paste errors where two modules declare the same command.
  @all_provider_names (for mod <- @command_modules,
                           %Command{name: name} <- mod.__commands__() do
                         name
                       end)
  @provider_dupes @all_provider_names -- Enum.uniq(@all_provider_names)
  if @provider_dupes != [] do
    raise CompileError,
      description:
        "Duplicate command names across providers: #{inspect(Enum.uniq(@provider_dupes))}"
  end

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc """
  Starts the command registry as a named GenServer that owns an ETS table.

  ## Options

  * `:name` — the name to register under (default: `#{__MODULE__}`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc """
  Registers a command with the given name, description, and execute function.

  If a command with the same name already exists it is overwritten.
  Writes go through the GenServer to ensure ETS table ownership is respected.

  This is the primary API for extensions to register commands at runtime.
  Built-in commands are registered via the `Minga.Command.Provider` behaviour.
  """
  @spec register(server(), atom(), String.t(), function()) :: :ok
  def register(server, name, description, execute)
      when is_atom(name) and is_binary(description) and is_function(execute) do
    cmd = %Command{name: name, description: description, execute: execute}
    GenServer.call(server, {:register, cmd})
  end

  @doc """
  Looks up a command by name.

  Returns `{:ok, command}` if found, `:error` otherwise.
  Reads directly from ETS (no GenServer call) for lock-free concurrency.
  """
  @spec lookup(server(), atom()) :: {:ok, Command.t()} | :error
  def lookup(server, name) when is_atom(name) do
    table = ets_table_name(server)

    case :ets.lookup(table, name) do
      [{^name, cmd}] -> {:ok, cmd}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  Returns all registered commands as a list.
  Reads directly from ETS.
  """
  @spec all(server()) :: [Command.t()]
  def all(server) do
    table = ets_table_name(server)

    :ets.tab2list(table)
    |> Enum.map(fn {_name, cmd} -> cmd end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Resets the registry to built-in commands only.

  Removes all user-registered commands and re-registers the defaults
  from all Provider modules. Used by hot reload to clear stale user
  commands before re-evaluating config.
  """
  @spec reset() :: :ok
  @spec reset(server()) :: :ok
  def reset, do: reset(__MODULE__)

  def reset(server) do
    GenServer.call(server, :reset)
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  @spec init(atom()) :: {:ok, atom()}
  def init(name) do
    table = ets_table_name(name)
    :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])
    populate_from_providers(table)
    {:ok, table}
  end

  @impl true
  def handle_call({:register, %Command{} = cmd}, _from, table) do
    :ets.insert(table, {cmd.name, cmd})
    {:reply, :ok, table}
  end

  def handle_call(:reset, _from, table) do
    :ets.delete_all_objects(table)
    populate_from_providers(table)
    {:reply, :ok, table}
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec ets_table_name(server()) :: atom()
  defp ets_table_name(name) when is_atom(name), do: :"#{name}_ets"

  defp ets_table_name(pid) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> :"#{name}_ets"
      _ -> raise ArgumentError, "Registry must be started with a name"
    end
  end

  @spec populate_from_providers(atom()) :: :ok
  defp populate_from_providers(table) do
    entries =
      for mod <- @command_modules,
          %Command{} = cmd <- mod.__commands__() do
        {cmd.name, cmd}
      end

    :ets.insert(table, entries)
    :ok
  end
end
