defmodule Minga.Test.SessionMockProvider do
  @behaviour MingaAgent.Provider

  use GenServer

  alias MingaAgent.Event
  alias Minga.Test.ProviderRequest

  @impl MingaAgent.Provider
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl MingaAgent.Provider
  def send_prompt(pid, request) do
    GenServer.cast(pid, {:prompt, request})
    :ok
  end

  @impl MingaAgent.Provider
  def abort(pid) do
    GenServer.cast(pid, :abort)
    :ok
  end

  @impl MingaAgent.Provider

  @spec continue(GenServer.server(), MingaAgent.Session.Request.t()) :: :ok
  def continue(_pid, _request), do: :ok

  @impl MingaAgent.Provider
  def new_session(pid) do
    GenServer.cast(pid, :new_session)
    :ok
  end

  @impl MingaAgent.Provider
  def get_state(_pid) do
    {:ok, %{model: nil, is_streaming: false, token_usage: nil}}
  end

  @impl GenServer
  def init(opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)
    {:ok, %{subscriber: subscriber}}
  end

  @impl GenServer
  def handle_cast({:prompt, request}, state) do
    ProviderRequest.emit(state.subscriber, request, %Event.AgentStart{})
    ProviderRequest.emit(state.subscriber, request, %Event.TextDelta{delta: "Hello "})
    ProviderRequest.emit(state.subscriber, request, %Event.TextDelta{delta: "world!"})

    usage = %MingaAgent.TurnUsage{
      input: 100,
      output: 50,
      cache_read: 0,
      cache_write: 0,
      cost: 0.01
    }

    ProviderRequest.complete(state.subscriber, request, "Hello world!", usage)
    {:noreply, state}
  end

  def handle_cast(:abort, state), do: {:noreply, state}
  def handle_cast(:new_session, state), do: {:noreply, state}

  @impl GenServer
  def handle_call({:set_model, model}, _from, state) do
    {:reply, :ok, Map.put(state, :model, model)}
  end

  @impl MingaAgent.Provider
  def set_model(pid, model) do
    GenServer.call(pid, {:set_model, model})
  end
end
