defmodule Minga.Frontend.WaitRequestCompletion do
  @moduledoc """
  Terminal outcome delivered from the wait-request tracker to its IPC waiter.

  Request identity travels with the outcome so a connection cannot accidentally
  consume a completion intended for another request.
  """

  @typedoc "Terminal wait-request outcome."
  @type outcome :: :accepted | {:cancelled, String.t()}

  @enforce_keys [:request_id, :outcome]
  defstruct [:request_id, :outcome]

  @typedoc "Typed cross-process wait-request completion payload."
  @type t :: %__MODULE__{request_id: String.t(), outcome: outcome()}

  @doc "Builds a terminal completion for a request."
  @spec new(String.t(), outcome()) :: t()
  def new(request_id, outcome) when is_binary(request_id) do
    %__MODULE__{request_id: request_id, outcome: outcome}
  end
end
