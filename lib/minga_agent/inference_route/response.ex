defmodule MingaAgent.InferenceRoute.Response do
  @moduledoc """
  A route's streaming reply.

  `events` is a lazy enumerable of `MingaAgent.InferenceRoute.Event` values; Minga consumes it once. `cancel` stops the work behind it and must be safe to call more than once.
  """

  @enforce_keys [:events, :cancel]
  defstruct @enforce_keys

  @type t :: %__MODULE__{events: Enumerable.t(), cancel: (-> :ok)}
end
