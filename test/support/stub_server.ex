defmodule Minga.Test.StubServer do
  @moduledoc """
  A minimal GenServer that mimics the Agent.Session API surface.

  Used in tests as a stand-in for a real agent session to avoid starting
  a provider (which spawns OS processes and takes ~700ms). Handles the
  calls that the renderer, agent commands, and buffer management make
  on the session (messages, usage, subscribe, unsubscribe, status, etc.)
  and returns sensible defaults.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts), do: {:ok, Map.new(opts)}

  @impl GenServer
  def handle_call(:messages, _from, state), do: {:reply, Map.get(state, :messages, []), state}

  def handle_call(:messages_with_ids, _from, state) do
    messages = Map.get(state, :messages, [])
    pairs = Map.get_lazy(state, :message_ids, fn -> default_message_ids(messages) end)
    {:reply, pairs, state}
  end

  def handle_call(:pinned_ids, _from, state),
    do: {:reply, Map.get(state, :pinned_ids, MapSet.new()), state}

  def handle_call({:toggle_pin, id}, _from, state) do
    pinned_ids = Map.get(state, :pinned_ids, MapSet.new())
    pinned_ids = toggle_pinned_id(pinned_ids, id)
    {:reply, :ok, Map.put(state, :pinned_ids, pinned_ids)}
  end

  def handle_call(:usage, _from, state),
    do: {:reply, %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}, state}

  def handle_call(:status, _from, state), do: {:reply, Map.get(state, :status, :idle), state}

  def handle_call(:cycle_model, _from, state),
    do: {:reply, Map.get(state, :cycle_model, {:error, :not_configured}), state}

  def handle_call({:subscribe, _pid}, _from, state), do: {:reply, :ok, state}
  def handle_call({:unsubscribe, _pid}, _from, state), do: {:reply, :ok, state}

  def handle_call(:editor_snapshot, _from, state) do
    snapshot = %{
      status: Map.get(state, :status, :idle),
      pending_approval: Map.get(state, :pending_approval),
      error: Map.get(state, :error),
      active_tool_name: Map.get(state, :active_tool_name)
    }

    {:reply, snapshot, state}
  end

  def handle_call(_msg, _from, state), do: {:reply, :ok, state}

  @spec toggle_pinned_id(MapSet.t(pos_integer()), pos_integer()) :: MapSet.t(pos_integer())
  defp toggle_pinned_id(pinned_ids, id) do
    if MapSet.member?(pinned_ids, id) do
      MapSet.delete(pinned_ids, id)
    else
      MapSet.put(pinned_ids, id)
    end
  end

  @spec default_message_ids([term()]) :: [{pos_integer(), term()}]
  defp default_message_ids(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.map(fn {msg, id} -> {id, msg} end)
  end

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end
