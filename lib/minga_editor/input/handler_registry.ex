defmodule MingaEditor.Input.HandlerRegistry do
  @moduledoc """
  Serialized owner of the surface-handler registration list.

  One GenServer validates every register, unregister, and reset mutation.
  It publishes a pre-sorted, immutable snapshot through one
  `:persistent_term` key so the input dispatch hot path reads one term
  with no sorting, filtering, or extension code execution.

  Reads go through `snapshot/0` (a single `:persistent_term.get`).
  Mutations go through GenServer calls so concurrent registrations
  from extensions, config reload, and cleanup never lose an update.
  """

  use GenServer

  @typedoc "Source that contributed registry entries."
  @type contribution_source :: :builtin | :config | {:extension, atom()}

  @typedoc "Full entry with priority, kept only in GenServer state."
  @type handler_entry :: {module(), contribution_source(), integer()}

  @typedoc "Published entry without priority, used by dispatch."
  @type sourced_handler :: {module(), contribution_source()}

  @snapshot_key {__MODULE__, :snapshot}

  @doc "Starts the sole writer of the surface-handler registry."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Registers a surface handler contributed by a source, using the global registry."
  @spec register(contribution_source(), module(), keyword()) :: :ok
  def register(source, module, opts \\ []) when is_atom(module) and is_list(opts) do
    priority = Keyword.get(opts, :priority, 100)
    GenServer.call(__MODULE__, {:register, source, module, priority})
  end

  @doc "Registers a surface handler on an explicit server. Used by tests with isolated registries."
  @spec register_on(GenServer.server(), contribution_source(), module(), keyword()) :: :ok
  def register_on(server, source, module, opts \\ [])
      when is_atom(module) and is_list(opts) do
    priority = Keyword.get(opts, :priority, 100)
    GenServer.call(server, {:register, source, module, priority})
  end

  @doc "Removes every surface handler contributed by a source."
  @spec unregister_source(contribution_source()) :: :ok
  def unregister_source(:builtin), do: :ok
  def unregister_source(source), do: GenServer.call(__MODULE__, {:unregister_source, source})

  @doc "Removes every surface handler contributed by a source on an explicit server."
  @spec unregister_source_on(GenServer.server(), contribution_source()) :: :ok
  def unregister_source_on(_server, :builtin), do: :ok

  def unregister_source_on(server, source) do
    GenServer.call(server, {:unregister_source, source})
  end

  @doc "Resets the registry to built-in handlers only."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Resets the registry on an explicit server."
  @spec reset_on(GenServer.server()) :: :ok
  def reset_on(server), do: GenServer.call(server, :reset)

  @doc "Returns the current pre-sorted snapshot for hot-path reads."
  @spec snapshot() :: [sourced_handler()]
  def snapshot, do: :persistent_term.get(@snapshot_key, [])

  @doc "Returns the snapshot held by an explicit server. Used by tests with isolated registries."
  @spec snapshot_on(GenServer.server()) :: [sourced_handler()]
  def snapshot_on(server), do: GenServer.call(server, :snapshot)

  @typep state :: {[handler_entry()], boolean()}

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    builtins = Keyword.get(opts, :builtins, MingaEditor.Input.builtin_handler_entries())
    global? = name == __MODULE__
    if global?, do: publish(builtins)
    {:ok, {builtins, global?}}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) ::
          {:reply, term(), state()}
  def handle_call(:snapshot, _from, {entries, global?}) do
    sorted = sort_snapshot(entries)
    {:reply, sorted, {entries, global?}}
  end

  def handle_call({:register, source, module, priority}, _from, {entries, global?}) do
    entry = {module, source, priority}

    updated =
      Enum.reject(entries, fn {m, s, _p} -> m == module and s == source end)

    updated = [entry | updated]
    if global?, do: publish(updated)
    {:reply, :ok, {updated, global?}}
  end

  def handle_call({:unregister_source, source}, _from, {entries, global?}) do
    updated = Enum.reject(entries, fn {_m, s, _p} -> s == source end)
    if global?, do: publish(updated)
    {:reply, :ok, {updated, global?}}
  end

  def handle_call(:reset, _from, {_entries, global?}) do
    builtins = MingaEditor.Input.builtin_handler_entries()
    if global?, do: publish(builtins)
    {:reply, :ok, {builtins, global?}}
  end

  @spec sort_snapshot([handler_entry()]) :: [sourced_handler()]
  defp sort_snapshot(entries) do
    entries
    |> Enum.sort_by(fn {module, _source, priority} ->
      {priority, Atom.to_string(module)}
    end)
    |> Enum.map(fn {module, source, _priority} -> {module, source} end)
  end

  @spec publish([handler_entry()]) :: :ok
  defp publish(entries) do
    :persistent_term.put(@snapshot_key, sort_snapshot(entries))
    :ok
  end
end
