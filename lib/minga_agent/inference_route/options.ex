defmodule MingaAgent.InferenceRoute.Options do
  @moduledoc """
  Request options a route can act on.

  `max_output_tokens` is the output cap fixed in the selection policy. `reasoning` is the selected level from `Model.reasoning_levels`, or nil when Minga has no selection for the request.
  """

  @enforce_keys [:max_output_tokens]
  defstruct max_output_tokens: nil, reasoning: nil

  @type t :: %__MODULE__{max_output_tokens: pos_integer(), reasoning: String.t() | nil}
end
