defmodule MingaAgent.InferenceRoute.Options do
  @moduledoc """
  Request options a route can act on: the output token cap and the selected reasoning level.

  This is a compile-time stub.
  """

  @enforce_keys [:max_output_tokens]
  defstruct max_output_tokens: nil, reasoning: nil

  @type t :: %__MODULE__{max_output_tokens: pos_integer(), reasoning: String.t() | nil}
end
