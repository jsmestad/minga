defmodule MingaAgent.InferenceRoute.Event do
  @moduledoc """
  One event in a route's response stream.

  - `{:text, text}` and `{:thinking, text}` append to the reply as they arrive.
  - `{:tool_call, tool_call}` is a complete call. Emit it once its arguments are final.
  - `{:usage, usage}` reports token counts. The last report wins.
  - `{:finish, reason}` ends the reply. `{:error, term}` fails the request; Minga passes `term` to the route's `classify_error/1`. A stream that ends without a finish event finishes with `:stop`.
  """

  alias MingaAgent.InferenceRoute.{ToolCall, Usage}

  @type finish_reason :: :stop | :tool_calls | :length | :refusal | {:error, term()}

  @type t ::
          {:text, String.t()}
          | {:thinking, String.t()}
          | {:tool_call, ToolCall.t()}
          | {:usage, Usage.t()}
          | {:finish, finish_reason()}

  @doc "Checks one route event before Minga acts on it."
  @spec validate(term()) :: {:ok, t()} | {:error, {:invalid_event, term()}}
  def validate({kind, text} = event) when kind in [:text, :thinking] and is_binary(text),
    do: {:ok, event}

  def validate({:tool_call, %ToolCall{} = call}) do
    case ToolCall.new(Map.from_struct(call)) do
      {:ok, call} -> {:ok, {:tool_call, call}}
      {:error, _reason} -> invalid({:tool_call, call})
    end
  end

  def validate({:usage, usage} = event) do
    case Usage.validate(usage) do
      {:ok, usage} -> {:ok, {:usage, usage}}
      {:error, _reason} -> invalid(event)
    end
  end

  def validate({:finish, reason} = event)
      when reason in [:stop, :tool_calls, :length, :refusal],
      do: {:ok, event}

  def validate({:finish, {:error, _reason}} = event), do: {:ok, event}
  def validate(event), do: invalid(event)

  @spec invalid(term()) :: {:error, {:invalid_event, term()}}
  defp invalid(event), do: {:error, {:invalid_event, event}}
end
