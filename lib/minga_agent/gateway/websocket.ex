defmodule MingaAgent.Gateway.WebSocket do
  @moduledoc """
  WebSocket handler for external clients.

  Each connection gets its own process (Bandit does this automatically).
  On connect, subscribes to relevant Minga.Events topics for push
  notifications. Incoming frames are JSON-RPC requests dispatched
  through `Gateway.JsonRpc`.
  """

  @behaviour WebSock

  alias MingaAgent.Gateway.{JsonRpc, EventStream}

  @type state :: %{events: :ok}

  @impl WebSock
  @spec init(term()) :: {:ok, state()}
  def init(_opts) do
    event_state = EventStream.subscribe_all()
    {:ok, %{events: event_state}}
  end

  @impl WebSock
  def handle_in({text, [opcode: :text]}, state) do
    case JsonRpc.dispatch(text) do
      {:ok, response_json} ->
        {:push, {:text, response_json}, state}

      {:error, error_json} ->
        {:push, {:text, error_json}, state}

      :notification ->
        {:ok, state}
    end
  end

  def handle_in(_other, state) do
    {:ok, state}
  end

  @impl WebSock
  def handle_info({:minga_event, _topic, _payload} = event, state) do
    case EventStream.format_notification(event) do
      {:ok, json} -> {:push, {:text, json}, state}
      :skip -> {:ok, state}
    end
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state), do: :ok
end
