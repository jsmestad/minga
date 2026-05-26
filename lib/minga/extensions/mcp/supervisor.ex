defmodule Minga.Extensions.MCP.Supervisor do
  @moduledoc """
  Dynamic supervisor for MCP clients owned by the optional MCP extension.

  MCP clients are session-scoped, but their processes run under this extension-owned supervisor so server crashes stay isolated and extension shutdown has a single cleanup point.
  """

  use DynamicSupervisor

  @doc "Starts the MCP client supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc "Starts a supervised MCP client."
  @spec start_client(keyword(), GenServer.server()) :: DynamicSupervisor.on_start_child()
  def start_client(client_opts, supervisor \\ __MODULE__) when is_list(client_opts) do
    child_spec = %{
      id: {MingaAgent.MCP.Client, System.unique_integer([:positive])},
      start: {MingaAgent.MCP.Client, :start_link, [client_opts]},
      restart: :temporary,
      type: :worker
    }

    DynamicSupervisor.start_child(supervisor, child_spec)
  end

  @impl DynamicSupervisor
  @spec init(keyword()) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
