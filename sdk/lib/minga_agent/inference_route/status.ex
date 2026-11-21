defmodule MingaAgent.InferenceRoute.Status do
  @moduledoc """
  Last known readiness of one contributed route.

  This is a compile-time stub.
  """

  @enforce_keys [:availability]
  defstruct availability: :unknown, plan_usage: nil

  @type availability ::
          :unknown
          | {:ready, String.t()}
          | {:unavailable, atom(), String.t()}

  @type t :: %__MODULE__{availability: availability(), plan_usage: nil}
end
