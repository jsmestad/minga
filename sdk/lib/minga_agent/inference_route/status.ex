defmodule MingaAgent.InferenceRoute.Status do
  @moduledoc """
  Last known readiness and plan usage of one contributed route. `plan_usage` is nil when the route has reported no usage.

  This is a compile-time stub.
  """

  @enforce_keys [:availability]
  defstruct availability: :unknown, plan_usage: nil

  @type availability ::
          :unknown
          | {:ready, String.t()}
          | {:unavailable, atom(), String.t()}

  @type t :: %__MODULE__{
          availability: availability(),
          plan_usage: [MingaAgent.InferenceRoute.PlanWindow.t()] | nil
        }
end
