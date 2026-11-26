defmodule Minga.Command.Registry do
  @moduledoc """
  ETS-backed registry for named editor commands.

  Commands and their contribution sources share one ETS row keyed by command name. Lookups read the table directly; the registry process serializes writes and source removal.

  ## Sources

  A command can be owned by `:builtin`, `:config`, or `{:extension, name}`. Registering the same command name from the same source replaces that source's previous value. Registering a duplicate name from a different source is rejected deterministically.

  Built-in command providers are seeded through the same source-owned registration path used by config and extensions.
  """

  use GenServer

  alias Minga.Command

  @typedoc "Registry server name or pid. Used as the ETS table name."
  @type server :: GenServer.server()

  @typedoc "Source that contributed registry entries."
  @type contribution_source :: :builtin | :config | {:extension, atom()}

  @typedoc "Command registration failure reason."
  @type register_error ::
          {:duplicate_name, atom(), existing_source :: contribution_source(),
           attempted_source :: contribution_source()}
          | {:duplicate_names, [atom()]}

  @command_modules [
    MingaEditor.Commands.Movement,
    MingaEditor.Commands.Editing,
    MingaEditor.Commands.Operators,
    MingaEditor.Commands.Visual,
    MingaEditor.Commands.Search,
    MingaEditor.Commands.Marks,
    MingaEditor.Commands.BufferManagement,
    MingaEditor.Commands.Folding,
    MingaEditor.Commands.Diagnostics,
    MingaEditor.Commands.EditTimeline,
    MingaEditor.Commands.Autobiography,
    MingaEditor.Commands.Lsp,
    MingaEditor.Commands.Project,
    MingaEditor.Commands.Agent,
    MingaEditor.Commands.InlineAsk,
    MingaEditor.Commands.InlineEdit,
    MingaEditor.Commands.RemoteFiles,
    MingaEditor.Commands.FileTree,
    MingaEditor.Commands.GitStatus,
    MingaEditor.Commands.Testing,
    MingaEditor.Commands.Extensions,
    MingaEditor.Commands.Macros,
    MingaEditor.Commands.Formatting,
    MingaEditor.Commands.Health,
    MingaEditor.Commands.Help,
    MingaEditor.Commands.Launchpad,
    MingaEditor.Commands.Tutor,
    MingaEditor.Commands.Tasks,
    MingaEditor.Commands.UI,
    MingaEditor.Commands.Tool,
    MingaEditor.Commands.Workspace
  ]

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the command registry as a named GenServer that owns the ETS table."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc "Registers a config-owned command with the given name, description, and execute function."
  @spec register(server(), atom(), String.t(), function()) :: :ok | {:error, register_error()}
  def register(server, name, description, execute),
    do: register(server, :config, name, description, execute)

  @doc "Registers a command with an explicit source."
  @spec register(server(), contribution_source(), atom(), String.t(), function()) ::
          :ok | {:error, register_error()}
  def register(server, source, name, description, execute)
      when is_atom(name) and is_binary(description) and is_function(execute) do
    cmd = %Command{name: name, description: description, execute: execute}
    register_command(server, source, cmd)
  end

  @doc "Registers a config-owned pre-built `%Command{}` struct."
  @spec register_command(server(), Command.t()) :: :ok | {:error, register_error()}
  def register_command(server, %Command{} = cmd), do: register_command(server, :config, cmd)

  @doc "Registers a pre-built `%Command{}` struct with an explicit source."
  @spec register_command(server(), contribution_source(), Command.t()) ::
          :ok | {:error, register_error()}
  def register_command(server, source, %Command{} = cmd) do
    register_commands(server, source, [cmd])
  end

  @doc "Registers every command returned by a provider module for one source."
  @spec register_provider(server(), contribution_source(), module()) ::
          :ok | {:error, register_error()}
  def register_provider(server, source, module) when is_atom(module) do
    register_commands(server, source, module.__commands__())
  end

  @doc "Registers multiple commands for one source as a group."
  @spec register_commands(server(), contribution_source(), [Command.t()]) ::
          :ok | {:error, register_error()}
  def register_commands(server, source, commands) when is_list(commands) do
    GenServer.call(server, {:register_commands, source, commands})
  end

  @doc "Removes a command by name regardless of source."
  @spec unregister(server(), atom()) :: :ok
  def unregister(server, name) when is_atom(name) do
    GenServer.call(server, {:unregister, name})
  end

  @doc "Removes every command contributed by a source."
  @spec unregister_source(contribution_source()) :: :ok
  @spec unregister_source(server(), contribution_source()) :: :ok
  def unregister_source(source), do: unregister_source(__MODULE__, source)

  def unregister_source(server, source) do
    GenServer.call(server, {:unregister_source, source})
  end

  @doc "Looks up a command by name."
  @spec lookup(server(), atom()) :: {:ok, Command.t()} | :error
  def lookup(server, name) when is_atom(name) do
    table = ets_table_name(server)

    case :ets.lookup_element(table, name, 3, nil) do
      nil -> :error
      cmd -> {:ok, cmd}
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Returns all registered commands as a list."
  @spec all(server()) :: [Command.t()]
  def all(server) do
    server
    |> ets_table_name()
    |> :ets.select([{{:_, :_, :"$1"}, [], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  @doc "Resets the registry to built-in commands only."
  @spec reset() :: :ok
  @spec reset(server()) :: :ok
  def reset, do: reset(__MODULE__)

  def reset(server) do
    GenServer.call(server, :reset)
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  @spec init(atom()) :: {:ok, atom(), {:continue, :populate}}
  def init(name) do
    table = ets_table_name(name)
    :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, table, {:continue, :populate}}
  end

  @impl true
  def handle_continue(:populate, table) do
    populate_from_providers(table)
    {:noreply, table}
  end

  @impl true
  def handle_call({:register_commands, source, commands}, _from, table) do
    reply = insert_commands(table, source, commands)
    {:reply, reply, table}
  end

  @impl true
  def handle_call({:unregister, name}, _from, table) do
    :ets.delete(table, name)
    {:reply, :ok, table}
  end

  def handle_call({:unregister_source, source}, _from, table) do
    :ets.select_delete(table, [{{:_, :"$1", :_}, [{:"=:=", :"$1", {:const, source}}], [true]}])
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
    commands = Enum.flat_map(@command_modules, & &1.__commands__())

    case insert_commands(table, :builtin, commands) do
      :ok ->
        :ok

      {:error, reason} ->
        raise CompileError, description: "Invalid built-in commands: #{inspect(reason)}"
    end
  end

  @spec insert_commands(atom(), contribution_source(), [Command.t()]) ::
          :ok | {:error, register_error()}
  defp insert_commands(table, source, commands) do
    with :ok <- validate_command_names(commands),
         :ok <- validate_no_foreign_duplicates(table, source, commands) do
      Enum.each(commands, fn %Command{name: name} = cmd ->
        :ets.insert(table, {name, source, cmd})
      end)

      :ok
    end
  end

  @spec validate_command_names([Command.t()]) :: :ok | {:error, register_error()}
  defp validate_command_names(commands) do
    names = Enum.map(commands, & &1.name)
    duplicates = names -- Enum.uniq(names)

    case Enum.uniq(duplicates) do
      [] -> :ok
      duplicate_names -> {:error, {:duplicate_names, duplicate_names}}
    end
  end

  @spec validate_no_foreign_duplicates(atom(), contribution_source(), [Command.t()]) ::
          :ok | {:error, register_error()}
  defp validate_no_foreign_duplicates(table, source, commands) do
    Enum.reduce_while(commands, :ok, fn %Command{name: name}, :ok ->
      case :ets.lookup_element(table, name, 2, nil) do
        nil -> {:cont, :ok}
        ^source -> {:cont, :ok}
        existing_source -> {:halt, {:error, {:duplicate_name, name, existing_source, source}}}
      end
    end)
  end
end
