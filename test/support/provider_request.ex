defmodule Minga.Test.ProviderRequest do
  @moduledoc false

  alias MingaAgent.Event
  alias MingaAgent.Session.Outcome
  alias MingaAgent.Session.Request
  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart

  @spec text(Request.t()) :: String.t()
  def text(%Request{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: :user, content: content} -> text_parts(content)
      _message -> nil
    end)
  end

  @spec emit(pid(), Request.t(), Event.t()) :: Event.t()
  def emit(subscriber, request, event) do
    send(subscriber, {:agent_provider_event, request.request_id, event})
    event
  end

  @spec complete(pid(), Request.t(), String.t(), Event.token_usage() | nil) :: :ok
  def complete(subscriber, request, text, usage \\ nil) do
    messages = request.messages ++ [Context.assistant(text)]

    emit(subscriber, request, %Event.AgentEnd{
      usage: usage,
      outcome: Outcome.new(request, messages)
    })

    :ok
  end

  @spec text_parts([ContentPart.t()]) :: String.t()
  defp text_parts(parts) when is_list(parts) do
    parts
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", &(&1.text || ""))
  end
end
