defmodule Minga.Test.SessionSlowMockProvider do
  @behaviour MingaAgent.Provider

  use GenServer

  alias MingaAgent.Event
  alias Minga.Test.ProviderRequest

  @impl MingaAgent.Provider
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl MingaAgent.Provider
  def send_prompt(pid, request), do: GenServer.cast(pid, {:prompt, request})

  @impl MingaAgent.Provider
  def abort(pid), do: GenServer.cast(pid, :abort)

  @impl MingaAgent.Provider
  def new_session(pid), do: GenServer.cast(pid, :new_session)

  @impl MingaAgent.Provider
  def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

  @impl MingaAgent.Provider
  def set_model(_pid, _model), do: :ok

  @spec proceed(GenServer.server()) :: :ok
  def proceed(pid), do: GenServer.cast(pid, :proceed)

  @impl GenServer
  def init(opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)
    {:ok, %{subscriber: subscriber, test_pid: Keyword.get(opts, :test_pid), pending: nil}}
  end

  @impl GenServer
  def handle_cast({:prompt, request}, state) do
    text = ProviderRequest.text(request)
    ProviderRequest.emit(state.subscriber, request, %Event.AgentStart{})
    ProviderRequest.emit(state.subscriber, request, %Event.TextDelta{delta: text})
    {:noreply, %{state | pending: request}}
  end

  def handle_cast(:proceed, state) do
    usage = %MingaAgent.TurnUsage{
      input: 10,
      output: 5,
      cache_read: 0,
      cache_write: 0,
      cost: 0.001
    }

    ProviderRequest.complete(
      state.subscriber,
      state.pending,
      ProviderRequest.text(state.pending),
      usage
    )

    {:noreply, %{state | pending: nil}}
  end

  def handle_cast(:abort, state) do
    if is_pid(state.test_pid), do: send(state.test_pid, :provider_abort_called)
    {:noreply, state}
  end

  def handle_cast(:new_session, state), do: {:noreply, state}
end
