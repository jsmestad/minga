defmodule Minga.Agent.Message do
  @moduledoc """
  Conversation message types for the agent chat.

  Each message represents one entry in the conversation history:
  a user prompt, an assistant response, a tool call, or a thinking block.
  """

  alias Minga.Agent.ToolCall
  alias Minga.Agent.TurnUsage

  @typedoc "System message severity level."
  @type system_level :: :info | :error

  @typedoc "Image attachment metadata for display in chat."
  @type image_attachment :: %{filename: String.t(), size_kb: non_neg_integer()}

  @typedoc "A single conversation message."
  @type t ::
          {:user, String.t()}
          | {:user, String.t(), [image_attachment()]}
          | {:assistant, String.t()}
          | {:thinking, String.t(), boolean()}
          | {:tool_call, ToolCall.t()}
          | {:system, String.t(), system_level()}
          | {:usage, TurnUsage.t()}

  # Keep these type aliases for backward compatibility with consumers
  # that reference Message.tool_call() or Message.turn_usage() in specs.
  @typedoc "Deprecated: use `Minga.Agent.ToolCall.t()` directly."
  @type tool_call :: ToolCall.t()

  @typedoc "Deprecated: use `Minga.Agent.TurnUsage.t()` directly."
  @type turn_usage :: TurnUsage.t()

  @typedoc "Deprecated: use `Minga.Agent.ToolCall.status()` directly."
  @type tool_status :: ToolCall.status()

  @doc "Creates a new user message."
  @spec user(String.t()) :: t()
  def user(text) when is_binary(text), do: {:user, text}

  @doc "Creates a new user message with image attachments."
  @spec user(String.t(), [image_attachment()]) :: t()
  def user(text, []) when is_binary(text), do: {:user, text}

  def user(text, attachments) when is_binary(text) and is_list(attachments),
    do: {:user, text, attachments}

  @doc "Creates a new assistant message (initially empty)."
  @spec assistant(String.t()) :: t()
  def assistant(text \\ ""), do: {:assistant, text}

  @doc "Creates a new thinking message (initially empty, expanded)."
  @spec thinking(String.t(), boolean()) :: t()
  def thinking(text \\ "", collapsed \\ false), do: {:thinking, text, collapsed}

  @doc "Creates a system message (session events, status changes)."
  @spec system(String.t(), system_level()) :: t()
  def system(text, level \\ :info) when is_binary(text) and level in [:info, :error] do
    {:system, text, level}
  end

  @doc "Extracts the plain text content of a message for clipboard copy."
  @spec text(t()) :: String.t()
  def text({:user, t}), do: t
  def text({:user, t, _attachments}), do: t
  def text({:assistant, t}), do: t
  def text({:thinking, t, _collapsed}), do: t
  def text({:tool_call, tc}), do: "#{tc.name}: #{tc.result}"
  def text({:system, t, _level}), do: t
  def text({:usage, u}), do: TurnUsage.format_short(u)

  @doc "Creates a per-turn usage message."
  @spec usage(TurnUsage.t()) :: t()
  def usage(%TurnUsage{} = data), do: {:usage, data}

  @doc "Creates a new tool call message."
  @spec tool_call(String.t(), String.t(), map()) :: t()
  def tool_call(id, name, args \\ %{}) do
    {:tool_call, ToolCall.new(id, name, args)}
  end
end
