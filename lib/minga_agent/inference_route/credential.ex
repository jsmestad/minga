defmodule MingaAgent.InferenceRoute.Credential do
  @moduledoc """
  Opaque route credential from the `routes.<route_id>.env` entry in `credentials.json`.

  Minga never interprets `env`; it only delivers it to the route that owns the entry.
  """

  @derive {Inspect, only: []}
  @enforce_keys [:env]
  defstruct @enforce_keys

  @type t :: %__MODULE__{env: %{String.t() => String.t()}}

  @doc "Wraps a validated map of variable names to string values."
  @spec new(%{String.t() => String.t()}) :: t()
  def new(env) when is_map(env), do: %__MODULE__{env: env}
end
