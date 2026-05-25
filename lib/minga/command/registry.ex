defmodule Minga.Command.Registry do
  @moduledoc """
  ETS-backed registry for named editor commands.

  Commands are stored by name (atom) in an ETS table with `read_concurrency: true` for lock-free lookups on the hot path. A companion ETS table stores the source that contributed each command so config reloads and extension unloads can remove everything owned by one source without touching other contributions.

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
    MingaEditor.Commands.Lsp,
    MingaEditor.Commands.Git,
    MingaEditor.Commands.Project,
    MingaEditor.Commands.Agent,
    MingaEditor.Commands.InlineAsk,
    MingaEditor.Commands.InlineEdit,
    MingaEditor.Commands.RemoteFiles,
    MingaEditor.Commands.Dired,
    MingaEditor.Commands.Testing,
    MingaEditor.Commands.Extensions,
    MingaEditor.Commands.Macros,
    MingaEditor.Commands.Formatting,
    MingaEditor.Commands.Help,
    MingaEditor.Commands.Tutor,
    MingaEditor.Commands.UI,
    MingaEditor.Commands.Tool,
    MingaEditor.Commands.Workspace
  ]

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the command registry as a named GenServer that owns ETS tables."
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

    case :ets.lookup(table, name) do
      [{^name, cmd}] -> {:ok, cmd}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Returns all registered commands as a list."
  @spec all(server()) :: [Command.t()]
  def all(server) do
    server
    |> ets_table_name()
    |> :ets.tab2list()
    |> Enum.map(fn {_name, cmd} -> cmd end)
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
  @spec init(atom()) :: {:ok, atom()}
  def init(name) do
    table = ets_table_name(name)
    sources = source_table_for_table(table)
    :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(sources, [:named_table, :set, :protected, read_concurrency: true])
    populate_from_providers(table, sources)
    {:ok, table}
  end

  @impl true
  def handle_call({:register_commands, source, commands}, _from, table) do
    sources = source_table_for_table(table)

    reply = insert_commands(table, sources, source, commands)
    {:reply, reply, table}
  end

  @impl true
  def handle_call({:unregister, name}, _from, table) do
    sources = source_table_for_table(table)
    :ets.delete(table, name)
    :ets.delete(sources, name)
    {:reply, :ok, table}
  end

  def handle_call({:unregister_source, source}, _from, table) do
    sources = source_table_for_table(table)
    unregister_source_entries(table, sources, source)
    {:reply, :ok, table}
  end

  def handle_call(:reset, _from, table) do
    sources = source_table_for_table(table)
    :ets.delete_all_objects(table)
    :ets.delete_all_objects(sources)
    populate_from_providers(table, sources)
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

  @spec source_table_for_table(atom()) :: atom()
  defp source_table_for_table(table), do: :"#{table}_sources"

  @spec populate_from_providers(atom(), atom()) :: :ok
  defp populate_from_providers(table, sources) do
    @command_modules
    |> Enum.flat_map(& &1.__commands__())
    |> then(fn commands ->
      case insert_commands(table, sources, :builtin, commands) do
        :ok ->
          :ok

        {:error, reason} ->
          raise CompileError, description: "Invalid built-in commands: #{inspect(reason)}"
      end
    end)
  end

  @spec insert_commands(atom(), atom(), contribution_source(), [Command.t()]) ::
          :ok | {:error, register_error()}
  defp insert_commands(table, sources, source, commands) do
    with :ok <- validate_command_names(commands),
         :ok <- validate_no_foreign_duplicates(sources, source, commands) do
      Enum.each(commands, fn %Command{name: name} = cmd ->
        :ets.insert(table, {name, cmd})
        :ets.insert(sources, {name, source})
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
  defp validate_no_foreign_duplicates(sources, source, commands) do
    Enum.reduce_while(commands, :ok, fn %Command{name: name}, :ok ->
      case :ets.lookup(sources, name) do
        [{^name, ^source}] ->
          {:cont, :ok}

        [{^name, existing_source}] ->
          {:halt, {:error, {:duplicate_name, name, existing_source, source}}}

        [] ->
          {:cont, :ok}
      end
    end)
  end

  @spec unregister_source_entries(atom(), atom(), contribution_source()) :: :ok
  defp unregister_source_entries(table, sources, source) do
    sources
    |> :ets.tab2list()
    |> Enum.each(fn
      {name, ^source} ->
        :ets.delete(table, name)
        :ets.delete(sources, name)

      _entry ->
        :ok
    end)

    :ok
  end
end
