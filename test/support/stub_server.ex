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
  def init(_opts), do: {:ok, %{}}

  @impl GenServer
  def handle_call(:messages, _from, state), do: {:reply, [], state}

  def handle_call(:usage, _from, state),
    do: {:reply, %{input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0.0}, state}

  def handle_call(:status, _from, state), do: {:reply, :idle, state}
  def handle_call({:subscribe, _pid}, _from, state), do: {:reply, :ok, state}
  def handle_call({:unsubscribe, _pid}, _from, state), do: {:reply, :ok, state}
  def handle_call(:editor_snapshot, _from, state), do: {:reply, %{}, state}
  def handle_call(_msg, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end
