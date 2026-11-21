defmodule MingaAgent.InferenceRoute.Response do
  @moduledoc """
  A route's streaming reply: a lazy enumerable of `MingaAgent.InferenceRoute.Event` values and a cancel function.

  This is a compile-time stub.
  """

  @enforce_keys [:events, :cancel]
  defstruct @enforce_keys

  @type t :: %__MODULE__{events: Enumerable.t(), cancel: (-> :ok)}
end
