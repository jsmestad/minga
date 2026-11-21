defmodule MingaAgent.InferenceRoute.Message do
  @moduledoc """
  One conversation message sent to a route.

  The system prompt travels separately in `Request.system`. A `:tool` message carries `{:tool_result, ...}` parts; an `:assistant` message carries its tool calls as `{:tool_call, ...}` parts after its text and thinking.
  """

  alias MingaAgent.InferenceRoute.ToolCall

  @enforce_keys [:role, :content]
  defstruct @enforce_keys

  @typedoc """
  One content part.

  - `{:text, text}`
  - `{:image, media_type, data}` with raw image bytes
  - `{:thinking, text, signature}`; `signature` is nil unless the route supplied one
  - `{:tool_call, tool_call}`
  - `{:tool_result, tool_call_id, parts, is_error}`; `parts` holds only text and image parts
  """
  @type part ::
          {:text, String.t()}
          | {:image, media_type :: String.t(), data :: binary()}
          | {:thinking, String.t(), signature :: String.t() | nil}
          | {:tool_call, ToolCall.t()}
          | {:tool_result, id :: String.t(), [part()], is_error :: boolean()}

  @type role :: :user | :assistant | :tool

  @type t :: %__MODULE__{role: role(), content: [part()]}
end
