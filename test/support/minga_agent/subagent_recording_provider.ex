defmodule Minga.Test.SubagentRecordingProvider do
  @moduledoc false

  @behaviour MingaAgent.Provider

  use GenServer

  alias MingaAgent.Event

  @type state :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  @impl MingaAgent.Provider
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec send_prompt(GenServer.server(), String.t()) :: :ok
  @impl MingaAgent.Provider
  def send_prompt(pid, text) do
    GenServer.call(pid, {:send_prompt, text})
  end

  @spec abort(GenServer.server()) :: :ok
  @impl MingaAgent.Provider
  def abort(pid) do
    GenServer.cast(pid, :abort)
    :ok
  end

  @spec new_session(GenServer.server()) :: :ok
  @impl MingaAgent.Provider
  def new_session(pid) do
    GenServer.cast(pid, :new_session)
    :ok
  end

  @spec seed_messages(GenServer.server(), [term()]) :: :ok
  @impl MingaAgent.Provider
  def seed_messages(_pid, _messages), do: :ok

  @spec get_state(GenServer.server()) :: {:ok, map()}
  @impl MingaAgent.Provider
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @spec init(keyword()) :: {:ok, state()}
  @impl GenServer
  def init(opts) do
    notify_test(opts, {:provider_started, self(), opts})

    state = %{
      subscriber: Keyword.fetch!(opts, :subscriber),
      model: Keyword.get(opts, :model),
      provider: Keyword.get(opts, :provider, "recording"),
      thinking_level: Keyword.get(opts, :thinking_level),
      active_skill_names: Keyword.get(opts, :active_skill_names, []),
      project_root: Keyword.get(opts, :project_root),
      blocking: Keyword.get(opts, :blocking, false),
      test_pid: Keyword.get(opts, :test_pid),
      test_ref: Keyword.get(opts, :test_ref)
    }

    {:ok, state}
  end

  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  @impl GenServer
  def handle_call({:send_prompt, text}, _from, state) do
    notify_test(state, {:prompt_received, self(), state.subscriber, text})
    notify_session(state, %Event.AgentStart{})

    if state.blocking do
      {:reply, :ok, state}
    else
      notify_session(state, %Event.TextDelta{delta: "child response"})
      notify_session(state, %Event.AgentEnd{usage: nil})
      {:reply, :ok, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    provider_state = %{
      model: %{id: state.model, name: state.model, provider: state.provider},
      is_streaming: false,
      token_usage: nil,
      thinking_level: state.thinking_level,
      active_skill_names: state.active_skill_names,
      project_root: state.project_root
    }

    {:reply, {:ok, provider_state}, state}
  end

  @spec handle_cast(term(), state()) :: {:noreply, state()}
  @impl GenServer
  def handle_cast(:finish, state) do
    notify_session(state, %Event.TextDelta{delta: "blocked child response"})
    notify_session(state, %Event.AgentEnd{usage: nil})
    {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @spec finish(GenServer.server()) :: :ok
  def finish(pid) do
    GenServer.cast(pid, :finish)
  end

  @spec notify_session(map(), Event.t()) :: :ok
  defp notify_session(state, event) do
    send(state.subscriber, {:agent_provider_event, event})
    :ok
  end

  @spec notify_test(keyword() | map(), tuple()) :: :ok
  defp notify_test(opts_or_state, message) do
    test_pid = get_opt(opts_or_state, :test_pid)
    test_ref = get_opt(opts_or_state, :test_ref)

    if is_pid(test_pid) and test_ref != nil do
      send(test_pid, {test_ref, message})
    end

    :ok
  end

  @spec get_opt(keyword() | map(), atom()) :: term()
  defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp get_opt(state, key) when is_map(state), do: Map.get(state, key)
end
