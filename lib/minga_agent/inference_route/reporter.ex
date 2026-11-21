defmodule MingaAgent.InferenceRoute.Reporter do
  @moduledoc """
  Capability to report status for one registered route.

  Registration returns a reporter. Any process that holds it can report the route's availability, so an extension can report from its own long-lived process. The token is unforgeable and changes whenever the route is registered again, so a reporter from an earlier registration or a removed route is rejected.
  """

  @derive {Inspect, only: [:route_id]}
  @enforce_keys [:route_id, :token]
  defstruct @enforce_keys

  @opaque token :: reference()
  @type t :: %__MODULE__{route_id: String.t(), token: token()}

  @doc "Issues a reporter for one registration of a route."
  @spec issue(String.t()) :: t()
  def issue(route_id) when is_binary(route_id) and route_id != "",
    do: %__MODULE__{route_id: route_id, token: make_ref()}
end
