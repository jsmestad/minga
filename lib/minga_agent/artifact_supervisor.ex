defmodule MingaAgent.ArtifactSupervisor do
  @moduledoc "Dedicated retained-artifact subtree, isolated from agent session supervision."

  use Supervisor

  alias MingaAgent.ArtifactQuota
  alias MingaAgent.ArtifactStores.Runtime

  @doc "Starts the quota, unique record registry, and lazy store supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, supervisor_name(name))
  end

  @impl Supervisor
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(opts) do
    {:ok, runtime} = runtime(opts)
    true = named_children?(runtime)

    quota_opts =
      [name: runtime.quota, root: runtime.root, limits: runtime.limits]
      |> maybe_put(:fault_injector, Keyword.get(opts, :fault_injector))

    children = [
      Supervisor.child_spec({ArtifactQuota, quota_opts}, id: :artifact_quota),
      Supervisor.child_spec(
        {Registry, keys: :unique, name: runtime.registry},
        id: :artifact_store_registry
      ),
      Supervisor.child_spec(
        {DynamicSupervisor, strategy: :one_for_one, name: runtime.store_supervisor},
        id: :artifact_store_supervisor
      )
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Builds the runtime represented by production defaults plus explicit test name overrides."
  @spec runtime(keyword()) :: {:ok, Runtime.t()} | {:error, :invalid_artifact_runtime}
  def runtime(opts \\ []) when is_list(opts) do
    Runtime.new(
      root: Keyword.get(opts, :root, MingaAgent.Config.artifact_root()),
      quota: Keyword.get(opts, :quota, MingaAgent.ArtifactQuota),
      registry: Keyword.get(opts, :registry, MingaAgent.ArtifactStores.Registry),
      store_supervisor:
        Keyword.get(opts, :store_supervisor, MingaAgent.ArtifactStores.StoreSupervisor),
      limits: Keyword.get(opts, :limits, MingaAgent.Config.artifact_limits())
    )
  end

  @spec named_children?(Runtime.t()) :: boolean()
  defp named_children?(runtime) do
    is_atom(runtime.quota) and not is_nil(runtime.quota) and
      is_atom(runtime.store_supervisor) and not is_nil(runtime.store_supervisor)
  end

  @spec supervisor_name(atom() | nil) :: keyword()
  defp supervisor_name(nil), do: []
  defp supervisor_name(name) when is_atom(name), do: [name: name]

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
