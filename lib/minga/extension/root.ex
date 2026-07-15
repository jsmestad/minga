defmodule Minga.Extension.Root do
  @moduledoc """
  Ordered supervision root for one extension declaration.

  `:rest_for_one` keeps the local runtime supervisor before the permanent
  lifecycle authority. Replacing the runtime supervisor therefore restarts the
  Instance only after an empty local supervisor exists, while an Instance crash
  leaves its runtime supervisor available for local adoption.
  """

  use Supervisor

  alias Minga.Extension.Instance
  alias Minga.Extension.InstanceRegistry
  alias Minga.Extension.RuntimeSupervisor

  @doc "Builds the dynamic child spec for an extension root."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :extension)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :supervisor
    }
  end

  @doc "Starts one extension root."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :extension)
    registry = Keyword.get(opts, :instance_registry, InstanceRegistry)
    Supervisor.start_link(__MODULE__, opts, name: InstanceRegistry.via(registry, :root, name))
  end

  @impl true
  @spec init(keyword()) :: {:ok, {Supervisor.sup_flags(), [Supervisor.child_spec()]}}
  def init(opts) do
    name = Keyword.fetch!(opts, :extension)
    registry = Keyword.get(opts, :instance_registry, InstanceRegistry)

    children = [
      Supervisor.child_spec(
        {RuntimeSupervisor, extension: name, instance_registry: registry},
        id: RuntimeSupervisor
      ),
      Supervisor.child_spec({Instance, opts}, id: Instance)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
