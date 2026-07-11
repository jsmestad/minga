defmodule Minga.Test.SessionDeferredMockProvider do
  @behaviour MingaAgent.Provider

  use GenServer

  alias MingaAgent.Event
  alias MingaAgent.Session

  @impl MingaAgent.Provider
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl MingaAgent.Provider
  def send_prompt(pid, text) do
    GenServer.cast(pid, {:prompt, text})
    :ok
  end

  @impl MingaAgent.Provider
  def abort(pid), do: GenServer.cast(pid, :abort)

  @impl MingaAgent.Provider
  def new_session(pid), do: GenServer.cast(pid, :new_session)

  @impl MingaAgent.Provider
  def seed_messages(_pid, _messages), do: :ok

  @impl MingaAgent.Provider
  def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

  @spec release_start(GenServer.server()) :: :ok
  def release_start(pid), do: GenServer.call(pid, :release_start)

  @spec release_end(GenServer.server()) :: :ok
  def release_end(pid), do: GenServer.call(pid, :release_end)

  @impl GenServer
  def init(opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)
    test_pid = Keyword.get(opts, :test_pid)
    {:ok, %{subscriber: subscriber, test_pid: test_pid, pending_prompt: nil, started?: false}}
  end

  @impl GenServer
  def handle_cast({:prompt, text}, state) do
    notify_test(state.test_pid, {:deferred_provider_prompt_received, self(), text})
    {:noreply, %{state | pending_prompt: text}}
  end

  def handle_cast(:abort, state), do: {:noreply, state}
  def handle_cast(:new_session, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:release_start, _from, %{pending_prompt: text, started?: false} = state)
      when is_binary(text) do
    send(state.subscriber, {:agent_provider_event, %Event.AgentStart{}})
    :thinking = Session.status(state.subscriber)
    {:reply, :ok, %{state | started?: true}}
  end

  def handle_call(:release_start, _from, state), do: {:reply, :ok, state}

  def handle_call(:release_end, _from, %{started?: true} = state) do
    usage = %MingaAgent.TurnUsage{
      input: 10,
      output: 5,
      cache_read: 0,
      cache_write: 0,
      cost: 0.001
    }

    send(state.subscriber, {:agent_provider_event, %Event.AgentEnd{usage: usage}})
    :idle = Session.status(state.subscriber)
    {:reply, :ok, state}
  end

  def handle_call(:release_end, _from, state), do: {:reply, :ok, state}

  @spec notify_test(pid() | nil, term()) :: :ok
  defp notify_test(nil, _message), do: :ok
  defp notify_test(pid, message) when is_pid(pid), do: send(pid, message)
end
