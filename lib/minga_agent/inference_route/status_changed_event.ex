defmodule MingaAgent.InferenceRoute.StatusChangedEvent do
  @moduledoc "Payload for `:inference_route_status_changed` events: a route's availability or plan usage changed."

  alias MingaAgent.InferenceRoute.Status

  @enforce_keys [:route_id, :status]
  defstruct @enforce_keys

  @type t :: %__MODULE__{route_id: String.t(), status: Status.t()}
end
