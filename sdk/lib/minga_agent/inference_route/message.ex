defmodule MingaAgent.InferenceRoute.Message do
  @moduledoc """
  One conversation message sent to a route. The system prompt travels in `Request.system`.

  This is a compile-time stub.
  """

  alias MingaAgent.InferenceRoute.ToolCall

  @enforce_keys [:role, :content]
  defstruct @enforce_keys

  @type part ::
          {:text, String.t()}
          | {:image, media_type :: String.t(), data :: binary()}
          | {:thinking, String.t(), signature :: String.t() | nil}
          | {:tool_call, ToolCall.t()}
          | {:tool_result, id :: String.t(), [part()], is_error :: boolean()}

  @type role :: :user | :assistant | :tool

  @type t :: %__MODULE__{role: role(), content: [part()]}
end
