defmodule MingaAgent.InferenceRoute.StatusChangedEvent do
  @moduledoc """
  Payload for `:inference_route_status_changed` events: a route's availability or plan usage changed.

  `short_name` is the route's sentence name (`Spec.short_name/1`), so subscribers can describe the route without asking the registry.
  """

  alias MingaAgent.InferenceRoute.Status

  @enforce_keys [:route_id, :short_name, :status]
  defstruct @enforce_keys

  @type t :: %__MODULE__{route_id: String.t(), short_name: String.t(), status: Status.t()}
end
