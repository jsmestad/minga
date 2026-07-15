defmodule Minga.Extension.RuntimeSupervisor do
  @moduledoc """
  Local `DynamicSupervisor` for one extension's runtime implementation.

  Child mechanics live here. Every child spec is forced to `:temporary`; the
  sibling `Instance` is the only process that interprets the declaration's
  original restart policy.
  """

  use DynamicSupervisor

  alias Minga.Extension.InstanceRegistry

  @doc "Starts the runtime supervisor for one extension root."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :extension)
    registry = Keyword.get(opts, :instance_registry, InstanceRegistry)

    DynamicSupervisor.start_link(__MODULE__, opts,
      name: InstanceRegistry.via(registry, :runtime, name)
    )
  end

  @doc "Starts one temporary runtime child."
  @spec start_child(GenServer.server(), Supervisor.child_spec()) ::
          {:ok, pid()} | {:error, term()}
  def start_child(supervisor, child_spec) do
    DynamicSupervisor.start_child(supervisor, Map.put(child_spec, :restart, :temporary))
  end

  @doc "Terminates the currently owned runtime child."
  @spec terminate_child(GenServer.server(), pid()) :: :ok | {:error, term()}
  def terminate_child(supervisor, pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(supervisor, pid)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "Returns this supervisor's sole local runtime child, bounded by the caller's deadline."
  @spec local_child(GenServer.server(), timeout()) :: {:ok, pid()} | :empty | {:error, term()}
  def local_child(supervisor, timeout \\ 5_000) do
    case GenServer.call(supervisor, :which_children, timeout) do
      [{_id, pid, _type, _modules}] when is_pid(pid) -> {:ok, pid}
      [] -> :empty
      children -> {:error, {:multiple_local_runtime_children, length(children)}}
    end
  catch
    :exit, {:timeout, _call} -> {:error, {:runtime_supervisor_unavailable, :timeout}}
    :exit, reason -> {:error, {:runtime_supervisor_unavailable, reason}}
  end

  @impl true
  @spec init(keyword()) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
