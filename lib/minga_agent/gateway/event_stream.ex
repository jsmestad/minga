defmodule MingaAgent.Gateway.EventStream do
  @moduledoc """
  Event subscription and JSON-RPC notification formatting.

  Subscribes to domain events from `Minga.Events`. Each WebSocket
  connection calls `subscribe_all/0` in its init and receives
  `{:minga_event, topic, payload}` messages that `format_notification/1`
  converts to JSON-RPC notification strings.

  Only domain events are exposed. Rendered state (chrome, display lists)
  is never pushed to API clients.
  """

  @topics [
    :agent_session_stopped,
    :buffer_saved,
    :buffer_changed,
    :log_message
  ]

  @doc """
  Subscribes the calling process to all gateway-relevant event topics.

  Call this in the WebSocket handler's `init/1`. The process will
  receive `{:minga_event, topic, payload}` messages for each event.
  """
  @spec subscribe_all() :: :ok
  def subscribe_all do
    Enum.each(@topics, &Minga.Events.subscribe/1)
    :ok
  end

  @doc """
  Formats a Minga event as a JSON-RPC notification string.

  Returns `{:ok, json}` if the event should be pushed to the client,
  or `:skip` if the event has no meaningful external representation.
  """
  @spec format_notification({:minga_event, atom(), term()}) :: {:ok, String.t()} | :skip
  def format_notification({:minga_event, topic, payload}) do
    case encode_event(topic, payload) do
      nil -> :skip
      params -> {:ok, encode_notification("event.#{topic}", params)}
    end
  end

  # ── Per-topic encoders ──────────────────────────────────────────────────────

  @spec encode_event(atom(), term()) :: map() | nil
  defp encode_event(:agent_session_stopped, payload) do
    %{
      session_id: Map.get(payload, :session_id),
      reason: inspect(Map.get(payload, :reason))
    }
  end

  defp encode_event(:log_message, payload) do
    %{
      text: Map.get(payload, :text),
      level: Map.get(payload, :level)
    }
  end

  defp encode_event(:buffer_saved, payload) do
    %{path: Map.get(payload, :path)}
  end

  defp encode_event(:buffer_changed, payload) do
    %{
      path: Map.get(payload, :path, nil),
      source: inspect(Map.get(payload, :source))
    }
  end

  defp encode_event(_topic, _payload), do: nil

  @spec encode_notification(String.t(), map()) :: String.t()
  defp encode_notification(method, params) do
    JSON.encode!(%{jsonrpc: "2.0", method: method, params: params})
  end
end
