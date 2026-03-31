defmodule Minga.Test.StubProvider do
  @moduledoc """
  A no-op agent provider for tests.

  Starts instantly (no OS processes, no API key checks, no tool loading).
  Responds to the Provider behaviour callbacks with sensible defaults so
  that Session GenServer lifecycle works end-to-end without the ~700ms
  cost of a real provider.

  Used via application config in test.exs:

      config :minga, test_provider_module: Minga.Test.StubProvider
  """

  @behaviour MingaAgent.Provider

  use GenServer

  @impl MingaAgent.Provider
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl MingaAgent.Provider
  def send_prompt(_pid, _text), do: :ok

  @impl MingaAgent.Provider
  def abort(_pid), do: :ok

  @impl MingaAgent.Provider
  def new_session(_pid), do: :ok

  @impl MingaAgent.Provider
  def get_state(_pid) do
    {:ok,
     %{
       model: %{id: "test-model", name: "Test Model", provider: "test"},
       is_streaming: false,
       token_usage: nil
     }}
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    subscriber = Keyword.get(opts, :subscriber)
    if subscriber, do: Process.monitor(subscriber)
    {:ok, %{subscriber: subscriber}}
  end

  @impl GenServer
  def handle_call(_msg, _from, state), do: {:reply, :ok, state}

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end
