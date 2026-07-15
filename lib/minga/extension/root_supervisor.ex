defmodule Minga.Extension.RootSupervisor do
  @moduledoc "Dynamic supervisor owning one ordered `Root(name)` per declaration."

  use DynamicSupervisor

  alias Minga.Extension.Instance.State
  alias Minga.Extension.InstanceRegistry
  alias Minga.Extension.Root

  @doc "Starts the extension root supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc "Ensures one root exists and returns its stable Instance server."
  @spec ensure_root(
          GenServer.server(),
          atom(),
          Minga.Extension.Entry.t(),
          GenServer.server(),
          keyword()
        ) ::
          {:ok, GenServer.server()} | {:error, term()}
  def ensure_root(supervisor, name, declaration, declaration_registry, opts \\ []) do
    instance_registry =
      Keyword.get(opts, :instance_registry, InstanceRegistry.registry_for_root(supervisor))

    child_opts = [
      extension: name,
      declaration: declaration,
      declaration_registry: declaration_registry,
      instance_registry: instance_registry,
      collaborators: State.stable_collaborators(opts)
    ]

    case InstanceRegistry.whereis(instance_registry, :root, name) do
      pid when is_pid(pid) -> await_instance(pid, instance_registry, name)
      nil -> start_root(supervisor, child_opts, instance_registry, name)
    end
  end

  @doc "Locates an existing root authority, synchronizing through Instance registration."
  @spec existing_authority(GenServer.server(), atom(), keyword()) ::
          {:ok, GenServer.server()} | :absent | {:error, term()}
  def existing_authority(supervisor, name, opts \\ []) do
    instance_registry =
      Keyword.get(opts, :instance_registry, InstanceRegistry.registry_for_root(supervisor))

    case InstanceRegistry.whereis(instance_registry, :root, name) do
      pid when is_pid(pid) ->
        await_instance(pid, instance_registry, name)

      nil ->
        :absent
    end
  end

  @doc "Terminates the root for a declaration which no longer exists."
  @spec terminate_root(GenServer.server(), atom(), keyword()) :: :ok | {:error, term()}
  def terminate_root(supervisor, name, opts \\ []) do
    instance_registry =
      Keyword.get(opts, :instance_registry, InstanceRegistry.registry_for_root(supervisor))

    case InstanceRegistry.whereis(instance_registry, :root, name) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(supervisor, pid)
    end
  catch
    :exit, reason -> {:error, {:authority_unavailable, name, reason}}
  end

  @doc "Waits through root initialization/restart and returns its permanent authority."
  @spec await_instance(pid(), atom(), atom()) :: {:ok, GenServer.server()} | {:error, term()}
  def await_instance(root, instance_registry, name)
      when is_pid(root) and is_atom(instance_registry) and is_atom(name) do
    _children = Supervisor.which_children(root)

    case InstanceRegistry.await(instance_registry, :instance, name) do
      {:ok, _pid} -> {:ok, InstanceRegistry.via(instance_registry, :instance, name)}
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, {:authority_unavailable, name, reason}}
  end

  @doc "Returns declared root names without inspecting runtime children."
  @spec names(GenServer.server(), keyword()) :: [atom()]
  def names(supervisor, opts \\ []) do
    registry =
      Keyword.get(opts, :instance_registry, InstanceRegistry.registry_for_root(supervisor))

    InstanceRegistry.root_names(registry)
  end

  @impl true
  @spec init(keyword()) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_root(GenServer.server(), keyword(), atom(), atom()) ::
          {:ok, GenServer.server()} | {:error, term()}
  defp start_root(supervisor, child_opts, instance_registry, name) do
    case DynamicSupervisor.start_child(supervisor, {Root, child_opts}) do
      {:ok, pid} -> await_instance(pid, instance_registry, name)
      {:error, {:already_started, pid}} -> await_instance(pid, instance_registry, name)
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, {:authority_unavailable, name, reason}}
  end
end
