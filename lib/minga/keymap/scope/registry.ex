defmodule Minga.Keymap.Scope.Registry do
  @moduledoc """
  Sole writer of the keymap scope registry.

  Scope registrations arrive from several processes: extension instances during `init`, the config loader during a reload, and contribution cleanup. Each change is a read-modify-write of the registered scope names, so two unsynchronized writers can lose one update. This GenServer serializes every change and publishes the complete result as one `:persistent_term` snapshot.

  Reads never call this process. Key resolution runs on every keystroke and reads the published snapshot directly with `snapshot/0`. Before the owner starts, reads see the built-in scopes.

  The owner makes no calls to other processes while it handles a request, so a caller that holds other locks or runs inside an extension `init` cannot deadlock with it. Callers resolve a scope module's name before they call the owner.
  """

  use GenServer

  alias Minga.Keymap.Scope

  @typedoc "One coherent publication of scope declarations and their sources."
  @type snapshot :: %{
          modules: %{Scope.scope_name() => module()},
          sources: %{Scope.scope_name() => Scope.contribution_source()}
        }

  @snapshot_key {__MODULE__, :snapshot}

  @builtin_scopes [
    Minga.Keymap.Scope.Editor,
    Minga.Keymap.Scope.Agent,
    Minga.Keymap.Scope.FileTree
  ]

  @doc "Starts the scope registry owner. It adopts a snapshot that survived a restart."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Returns the canonical built-in scope declarations without extension contributions."
  @spec builtin_modules() :: [module()]
  def builtin_modules, do: @builtin_scopes

  @doc "Returns the published snapshot, or the built-in snapshot before the owner has started."
  @spec snapshot() :: snapshot()
  def snapshot do
    case :persistent_term.get(@snapshot_key, nil) do
      nil -> builtin_snapshot()
      snapshot -> snapshot
    end
  end

  @doc "Registers a resolved scope name for a source."
  @spec register(Scope.contribution_source(), Scope.scope_name(), module()) ::
          :ok | {:error, Scope.register_error()}
  def register(source, name, module) when is_atom(name) and is_atom(module) do
    GenServer.call(__MODULE__, {:register, source, name, module})
  end

  @doc "Removes one scope by name."
  @spec unregister(Scope.scope_name()) :: :ok
  def unregister(name) when is_atom(name), do: GenServer.call(__MODULE__, {:unregister, name})

  @doc "Removes every scope contributed by a source."
  @spec unregister_source(Scope.contribution_source()) :: :ok
  def unregister_source(source), do: GenServer.call(__MODULE__, {:unregister_source, source})

  @doc "Replaces the registry with the built-in scopes."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  @spec init(:ok) :: {:ok, snapshot()}
  def init(:ok) do
    case :persistent_term.get(@snapshot_key, nil) do
      nil -> {:ok, publish(builtin_snapshot())}
      published -> {:ok, published}
    end
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), snapshot()) ::
          {:reply, :ok | {:error, Scope.register_error()}, snapshot()}
  def handle_call({:register, source, name, module}, _from, snapshot) do
    case Map.fetch(snapshot.sources, name) do
      {:ok, existing} when existing != source ->
        {:reply, {:error, {:duplicate_scope, name, existing, source}}, snapshot}

      _owned_or_absent ->
        updated = %{
          modules: Map.put(snapshot.modules, name, module),
          sources: Map.put(snapshot.sources, name, source)
        }

        {:reply, :ok, publish_changed(snapshot, updated)}
    end
  end

  def handle_call({:unregister, name}, _from, snapshot) do
    {:reply, :ok, publish_changed(snapshot, drop_names(snapshot, [name]))}
  end

  def handle_call({:unregister_source, source}, _from, snapshot) do
    names = for {name, ^source} <- snapshot.sources, do: name
    {:reply, :ok, publish_changed(snapshot, drop_names(snapshot, names))}
  end

  def handle_call(:reset, _from, snapshot) do
    {:reply, :ok, publish_changed(snapshot, builtin_snapshot())}
  end

  @spec drop_names(snapshot(), [Scope.scope_name()]) :: snapshot()
  defp drop_names(snapshot, names) do
    %{modules: Map.drop(snapshot.modules, names), sources: Map.drop(snapshot.sources, names)}
  end

  @spec builtin_snapshot() :: snapshot()
  defp builtin_snapshot do
    modules = Map.new(@builtin_scopes, fn module -> {module.name(), module} end)
    %{modules: modules, sources: Map.new(modules, fn {name, _module} -> {name, :builtin} end)}
  end

  # Every :persistent_term write triggers a global literal-area scan, so an unchanged registry is not republished.
  @spec publish_changed(snapshot(), snapshot()) :: snapshot()
  defp publish_changed(snapshot, snapshot), do: snapshot
  defp publish_changed(_previous, updated), do: publish(updated)

  @spec publish(snapshot()) :: snapshot()
  defp publish(snapshot) do
    :persistent_term.put(@snapshot_key, snapshot)
    snapshot
  end
end
