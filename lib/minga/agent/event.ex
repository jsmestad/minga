defmodule Minga.Agent.Event do
  @moduledoc """
  Provider-agnostic event types for agent communication.

  These structs represent the events that flow from a provider (pi RPC,
  direct API, etc.) to the `Agent.Session`. The session uses them to
  update conversation state, status, and UI without knowing anything
  about the underlying provider protocol.
  """

  @typedoc "Token usage statistics from a completed response."
  @type token_usage :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          cost: float()
        }

  @typedoc "Union of all agent event types."
  @type t ::
          agent_start()
          | agent_end()
          | text_delta()
          | thinking_delta()
          | tool_start()
          | tool_update()
          | tool_end()
          | error()

  @typedoc "Agent has started processing a prompt."
  @type agent_start :: %__MODULE__.AgentStart{}

  @typedoc "Agent has finished processing."
  @type agent_end :: %__MODULE__.AgentEnd{usage: token_usage() | nil}

  @typedoc "A chunk of assistant response text."
  @type text_delta :: %__MODULE__.TextDelta{delta: String.t()}

  @typedoc "A chunk of the agent's internal reasoning."
  @type thinking_delta :: %__MODULE__.ThinkingDelta{delta: String.t()}

  @typedoc "A tool call has started."
  @type tool_start :: %__MODULE__.ToolStart{
          tool_call_id: String.t(),
          name: String.t(),
          args: map()
        }

  @typedoc "Partial progress on a running tool call."
  @type tool_update :: %__MODULE__.ToolUpdate{
          tool_call_id: String.t(),
          name: String.t(),
          partial_result: String.t()
        }

  @typedoc "A tool call has completed."
  @type tool_end :: %__MODULE__.ToolEnd{
          tool_call_id: String.t(),
          name: String.t(),
          result: String.t(),
          is_error: boolean()
        }

  @typedoc "An error occurred in the agent."
  @type error :: %__MODULE__.Error{message: String.t()}

  defmodule AgentStart do
    @moduledoc false
    @enforce_keys []
    defstruct []
    @type t :: %__MODULE__{}
  end

  defmodule AgentEnd do
    @moduledoc false
    @enforce_keys []
    defstruct usage: nil
    @type t :: %__MODULE__{usage: Minga.Agent.Event.token_usage() | nil}
  end

  defmodule TextDelta do
    @moduledoc false
    @enforce_keys [:delta]
    defstruct [:delta]
    @type t :: %__MODULE__{delta: String.t()}
  end

  defmodule ThinkingDelta do
    @moduledoc false
    @enforce_keys [:delta]
    defstruct [:delta]
    @type t :: %__MODULE__{delta: String.t()}
  end

  defmodule ToolStart do
    @moduledoc false
    @enforce_keys [:tool_call_id, :name]
    defstruct [:tool_call_id, :name, args: %{}]
    @type t :: %__MODULE__{tool_call_id: String.t(), name: String.t(), args: map()}
  end

  defmodule ToolUpdate do
    @moduledoc false
    @enforce_keys [:tool_call_id, :name]
    defstruct [:tool_call_id, :name, partial_result: ""]

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            name: String.t(),
            partial_result: String.t()
          }
  end

  defmodule ToolEnd do
    @moduledoc false
    @enforce_keys [:tool_call_id, :name]
    defstruct [:tool_call_id, :name, result: "", is_error: false]

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            name: String.t(),
            result: String.t(),
            is_error: boolean()
          }
  end

  defmodule Error do
    @moduledoc false
    @enforce_keys [:message]
    defstruct [:message]
    @type t :: %__MODULE__{message: String.t()}
  end
end
