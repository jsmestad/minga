defmodule Minga.Agent.Event do
  @moduledoc """
  Provider-agnostic event types for agent communication.

  These structs represent the events that flow from a provider (pi RPC,
  direct API, etc.) to the `Agent.Session`. The session uses them to
  update conversation state, status, and UI without knowing anything
  about the underlying provider protocol.
  """

  @typedoc "Token usage statistics from a completed response."
  @type token_usage :: Minga.Agent.TurnUsage.t()

  @typedoc "Union of all agent event types."
  @type t ::
          agent_start()
          | agent_end()
          | text_delta()
          | thinking_delta()
          | tool_start()
          | tool_update()
          | tool_end()
          | tool_approval()
          | tool_file_changed()
          | context_usage()
          | turn_limit_reached()
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

  @typedoc "A destructive tool call needs user approval before executing."
  @type tool_approval :: %__MODULE__.ToolApproval{
          tool_call_id: String.t(),
          name: String.t(),
          args: map(),
          reply_to: pid()
        }

  @typedoc "A file-modifying tool captured before/after content for diff review."
  @type tool_file_changed :: %__MODULE__.ToolFileChanged{
          tool_call_id: String.t(),
          path: String.t(),
          before_content: String.t(),
          after_content: String.t()
        }

  @typedoc "Pre-send estimated context usage."
  @type context_usage :: %__MODULE__.ContextUsage{
          estimated_tokens: non_neg_integer(),
          context_limit: non_neg_integer() | nil
        }

  @typedoc "The agent reached its per-prompt turn limit."
  @type turn_limit_reached :: %__MODULE__.TurnLimitReached{
          current: non_neg_integer(),
          limit: pos_integer()
        }

  @typedoc "An error occurred in the agent."
  @type error :: %__MODULE__.Error{message: String.t()}

  defmodule AgentStart do
    @moduledoc false
    defstruct []
    @type t :: %__MODULE__{}
  end

  defmodule AgentEnd do
    @moduledoc false
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

  defmodule ToolApproval do
    @moduledoc false
    @enforce_keys [:tool_call_id, :name, :reply_to]
    defstruct [:tool_call_id, :name, :reply_to, args: %{}]

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            name: String.t(),
            args: map(),
            reply_to: pid()
          }
  end

  defmodule ToolFileChanged do
    @moduledoc false
    @enforce_keys [:tool_call_id, :path, :before_content, :after_content]
    defstruct [:tool_call_id, :path, :before_content, :after_content]

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            path: String.t(),
            before_content: String.t(),
            after_content: String.t()
          }
  end

  defmodule ContextUsage do
    @moduledoc false
    @enforce_keys [:estimated_tokens]
    defstruct [:estimated_tokens, :context_limit]

    @type t :: %__MODULE__{
            estimated_tokens: non_neg_integer(),
            context_limit: non_neg_integer() | nil
          }
  end

  defmodule TurnLimitReached do
    @moduledoc false
    @enforce_keys [:current, :limit]
    defstruct [:current, :limit]

    @type t :: %__MODULE__{
            current: non_neg_integer(),
            limit: pos_integer()
          }
  end

  defmodule Error do
    @moduledoc false
    @enforce_keys [:message]
    defstruct [:message]
    @type t :: %__MODULE__{message: String.t()}
  end
end
