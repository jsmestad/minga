defmodule MingaAgent.InferenceRoute.Credential do
  @moduledoc """
  The route's `routes.<route_id>.env` entry from `credentials.json`, passed as `Request.credential`.

  This is a compile-time stub.
  """

  @enforce_keys [:env]
  defstruct @enforce_keys

  @type t :: %__MODULE__{env: %{String.t() => String.t()}}
end
