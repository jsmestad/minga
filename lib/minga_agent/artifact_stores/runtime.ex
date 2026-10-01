defmodule MingaAgent.ArtifactStores.Runtime do
  @moduledoc "Explicit process names and policy for one retained-artifact runtime."

  alias MingaAgent.ArtifactStore.Limits

  @type t :: %__MODULE__{
          root: String.t(),
          quota: GenServer.server(),
          registry: atom(),
          store_supervisor: GenServer.server(),
          limits: map()
        }

  @enforce_keys [:root, :quota, :registry, :store_supervisor, :limits]
  defstruct @enforce_keys

  @doc "Builds a validated artifact runtime for production or an isolated test subtree."
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_artifact_runtime}
  def new(opts) when is_list(opts) do
    root = Keyword.get(opts, :root)
    quota = Keyword.get(opts, :quota)
    registry = Keyword.get(opts, :registry)
    store_supervisor = Keyword.get(opts, :store_supervisor)
    requested_limits = Keyword.get(opts, :limits, [])

    with true <- is_binary(root) and String.trim(root) != "",
         true <- valid_server?(quota),
         true <- is_atom(registry) and not is_nil(registry),
         true <- valid_server?(store_supervisor),
         {:ok, limits} <- Limits.new(requested_limits, MingaAgent.Config.artifact_limits()) do
      {:ok,
       %__MODULE__{
         root: Path.expand(root),
         quota: quota,
         registry: registry,
         store_supervisor: store_supervisor,
         limits: Map.from_struct(limits)
       }}
    else
      _ -> {:error, :invalid_artifact_runtime}
    end
  end

  def new(_opts), do: {:error, :invalid_artifact_runtime}

  @spec valid_server?(term()) :: boolean()
  defp valid_server?(server) when is_pid(server), do: true
  defp valid_server?(server) when is_atom(server), do: not is_nil(server)
  defp valid_server?({:global, _name}), do: true
  defp valid_server?({:via, module, _name}) when is_atom(module), do: true
  defp valid_server?(_server), do: false
end
