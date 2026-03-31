defmodule MingaAgent.ToolApproval do
  @moduledoc """
  Pending tool approval data.

  When a tool requires user confirmation before execution, this struct
  captures the tool call identity and the reply-to PID for the blocked
  Task process. Flows from `Agent.Session` through editor state, input
  handling, chat decorations, and GUI protocol encoding.
  """

  @typedoc "A pending tool approval."
  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          name: String.t(),
          args: map(),
          reply_to: pid() | nil
        }

  @enforce_keys [:tool_call_id, :name]
  defstruct tool_call_id: nil,
            name: nil,
            args: %{},
            reply_to: nil
end
