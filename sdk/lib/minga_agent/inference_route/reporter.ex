defmodule MingaAgent.InferenceRoute.Reporter do
  @moduledoc """
  Capability returned by `Minga.Extension.ModelRoutes.register/2` to report one route's status from any process.

  This is a compile-time stub.
  """

  @enforce_keys [:route_id, :token]
  defstruct @enforce_keys

  @opaque token :: reference()
  @type t :: %__MODULE__{route_id: String.t(), token: token()}
end
