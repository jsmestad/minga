defmodule Minga.Test.SubagentGatedProvider do
  @moduledoc false

  @behaviour MingaAgent.Provider

  use GenServer

  alias MingaAgent.Event
  alias Minga.Test.ProviderRequest
  alias MingaAgent.Session.Request

  @type state :: %{subscriber: pid(), test_pid: pid(), active_request: Request.t() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  @impl MingaAgent.Provider
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec send_prompt(GenServer.server(), Request.t()) :: :ok
  @impl MingaAgent.Provider
  def send_prompt(pid, request), do: GenServer.call(pid, {:prompt, request})

  @spec abort(GenServer.server()) :: :ok
  @impl MingaAgent.Provider
  def abort(pid), do: GenServer.call(pid, :abort)

  @spec new_session(GenServer.server()) :: :ok
  @impl MingaAgent.Provider
  def new_session(pid), do: GenServer.call(pid, :new_session)

  @spec get_state(GenServer.server()) :: {:ok, map()}
  @impl MingaAgent.Provider
  def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

  @spec proceed(GenServer.server(), String.t()) :: :ok
  def proceed(pid, text \\ "child done"), do: GenServer.call(pid, {:proceed, text})

  @spec init(keyword()) :: {:ok, state()}
  @impl GenServer
  def init(opts) do
    await_startup_gate(opts)

    {:ok,
     %{
       subscriber: Keyword.fetch!(opts, :subscriber),
       test_pid: Keyword.fetch!(opts, :test_pid),
       active_request: nil
     }}
  end

  @spec await_startup_gate(keyword()) :: :ok
  defp await_startup_gate(opts) do
    case Keyword.get(opts, :startup_gate) do
      {test_pid, ref} ->
        send(test_pid, {:provider_starting, ref, self(), Keyword.fetch!(opts, :subscriber)})

        receive do
          {^ref, :continue} -> :ok
        end

      nil ->
        :ok
    end
  end

  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, :ok, state()}
  @impl GenServer
  def handle_call({:prompt, request}, _from, state) do
    ProviderRequest.emit(state.subscriber, request, %Event.AgentStart{})
    send(state.test_pid, {:provider_prompt, self(), ProviderRequest.text(request)})
    {:reply, :ok, %{state | active_request: request}}
  end

  def handle_call({:proceed, text}, _from, state) do
    ProviderRequest.emit(state.subscriber, state.active_request, %Event.TextDelta{delta: text})
    ProviderRequest.complete(state.subscriber, state.active_request, text)
    {:reply, :ok, %{state | active_request: nil}}
  end

  def handle_call(:abort, _from, state), do: {:reply, :ok, state}
  def handle_call(:new_session, _from, state), do: {:reply, :ok, state}
end
