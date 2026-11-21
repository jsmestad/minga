defmodule MingaAgent.InferenceRoute.Event do
  @moduledoc """
  One event in a route's response stream. Emit a tool call only once its arguments are final. A stream without a finish event finishes with `:stop`; `{:finish, {:error, term}}` fails the request and Minga passes `term` to `classify_error/1`.

  This is a compile-time stub.
  """

  alias MingaAgent.InferenceRoute.{ToolCall, Usage}

  @type finish_reason :: :stop | :tool_calls | :length | :refusal | {:error, term()}

  @type t ::
          {:text, String.t()}
          | {:thinking, String.t()}
          | {:tool_call, ToolCall.t()}
          | {:usage, Usage.t()}
          | {:finish, finish_reason()}
end
