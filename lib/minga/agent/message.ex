defmodule Minga.Agent.Message do
  @moduledoc """
  Conversation message types for the agent chat.

  Each message represents one entry in the conversation history:
  a user prompt, an assistant response, a tool call, or a thinking block.
  """

  @typedoc "Tool call status."
  @type tool_status :: :running | :complete | :error

  @typedoc "System message severity level."
  @type system_level :: :info | :error

  @typedoc "Per-turn token usage data."
  @type turn_usage :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          cost: float()
        }

  @typedoc "A single conversation message."
  @type t ::
          {:user, String.t()}
          | {:assistant, String.t()}
          | {:thinking, String.t(), boolean()}
          | {:tool_call, tool_call()}
          | {:system, String.t(), system_level()}
          | {:usage, turn_usage()}

  @typedoc "Tool call details."
  @type tool_call :: %{
          id: String.t(),
          name: String.t(),
          args: map(),
          status: tool_status(),
          result: String.t(),
          is_error: boolean(),
          collapsed: boolean(),
          started_at: integer() | nil,
          duration_ms: non_neg_integer() | nil
        }

  @doc "Creates a new user message."
  @spec user(String.t()) :: t()
  def user(text) when is_binary(text), do: {:user, text}

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
  def text({:assistant, t}), do: t
  def text({:thinking, t, _collapsed}), do: t
  def text({:tool_call, tc}), do: "#{tc.name}: #{tc.result}"
  def text({:system, t, _level}), do: t
  def text({:usage, u}), do: "↑#{u.input} ↓#{u.output} $#{u.cost}"

  @doc "Creates a per-turn usage message."
  @spec usage(turn_usage()) :: t()
  def usage(data) when is_map(data), do: {:usage, data}

  @doc "Creates a new tool call message."
  @spec tool_call(String.t(), String.t(), map()) :: t()
  def tool_call(id, name, args \\ %{}) do
    {:tool_call,
     %{
       id: id,
       name: name,
       args: args,
       status: :running,
       result: "",
       is_error: false,
       collapsed: true,
       started_at: System.monotonic_time(:millisecond),
       duration_ms: nil
     }}
  end
end
