defmodule MingaAgent.InferenceRoute.SetupAction do
  @moduledoc """
  An optional setup row a route shows in `/model`. Selecting it runs the route's `availability/2` check.

  This is a compile-time stub.
  """

  @enforce_keys [:label, :description]
  defstruct @enforce_keys

  @type t :: %__MODULE__{label: String.t(), description: String.t()}
end
