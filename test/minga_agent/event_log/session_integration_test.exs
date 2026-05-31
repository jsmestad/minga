defmodule MingaAgent.EventLog.SessionIntegrationTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Event
  alias MingaAgent.EventLog
  alias MingaAgent.EventLog.Store
  alias MingaAgent.Session

  @moduletag :tmp_dir

  defmodule SteeringProvider do
    @behaviour MingaAgent.Provider

    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl MingaAgent.Provider
    def send_prompt(pid, text), do: GenServer.call(pid, {:prompt, text})

    @impl MingaAgent.Provider
    def abort(pid), do: GenServer.cast(pid, :abort)

    @impl MingaAgent.Provider
    def new_session(pid), do: GenServer.cast(pid, :new_session)

    @impl MingaAgent.Provider
    def seed_messages(_pid, _messages), do: :ok

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: "test", is_streaming: true, token_usage: nil}}

    @impl true
    def init(opts) do
      {:ok, %{subscriber: Keyword.fetch!(opts, :subscriber)}}
    end

    @impl true
    def handle_call({:prompt, text}, _from, state) do
      send(state.subscriber, {:agent_provider_event, %Event.AgentStart{}})
      send(state.subscriber, {:agent_provider_event, %Event.TextDelta{delta: text}})
      {:reply, :ok, state}
    end

    @impl true
    def handle_cast(:abort, state), do: {:noreply, state}
    def handle_cast(:new_session, state), do: {:noreply, state}
  end

  defmodule ReplayProvider do
    @behaviour MingaAgent.Provider

    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl MingaAgent.Provider
    def send_prompt(pid, text), do: GenServer.cast(pid, {:prompt, text})

    @impl MingaAgent.Provider
    def abort(pid), do: GenServer.cast(pid, :abort)

    @impl MingaAgent.Provider
    def new_session(pid), do: GenServer.cast(pid, :new_session)

    @impl MingaAgent.Provider
    def seed_messages(_pid, _messages), do: :ok

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: "test", is_streaming: false, token_usage: nil}}

    @impl true
    def init(opts) do
      {:ok, %{subscriber: Keyword.fetch!(opts, :subscriber)}}
    end

    @impl true
    def handle_cast({:prompt, text}, state) do
      send(state.subscriber, {:agent_provider_event, %Event.AgentStart{}})
      send(state.subscriber, {:agent_provider_event, %Event.TextDelta{delta: text}})

      send(
        state.subscriber,
        {:agent_provider_event,
         %Event.ToolStart{
           tool_call_id: "tool-1",
           name: "read_file",
           args: %{path: "secret.txt", api_key: "nope"}
         }}
      )

      send(
        state.subscriber,
        {:agent_provider_event,
         %Event.ToolEnd{tool_call_id: "tool-1", name: "read_file", result: "ok", is_error: false}}
      )

      send(state.subscriber, {:agent_provider_event, %Event.AgentEnd{}})
      {:noreply, state}
    end

    def handle_cast(:abort, state), do: {:noreply, state}
    def handle_cast(:new_session, state), do: {:noreply, state}
  end

  test "session broadcasts are durably recorded for replay", %{tmp_dir: tmp_dir} do
    log_name = unique_name("session-log")

    log_pid =
      start_supervised!(
        {EventLog, name: log_name, db_dir: tmp_dir, retention_sweep?: false, health_check: :none}
      )

    session =
      start_supervised!(
        {Session,
         session_id: "stable-session",
         provider: ReplayProvider,
         event_log_server: log_name,
         persist?: false,
         hooks_enabled?: false}
      )

    :sys.get_state(session)
    assert :ok = Session.send_prompt(session, "hello")
    :sys.get_state(session)
    :sys.get_state(log_pid)

    {:ok, db} = EventLog.open_read_connection(db_dir: tmp_dir)
    events = wait_for_event(db, "stable-session", :waiting_for_input, session, log_pid)
    event_types = Enum.map(events, & &1.event_type)

    assert :session_started in event_types
    assert :user_message in event_types
    assert :assistant_delta in event_types
    assert :tool_call_started in event_types
    assert :tool_call_finished in event_types
    assert :waiting_for_input in event_types

    user_message = Enum.find(events, &(&1.event_type == :user_message))
    assert user_message.payload["text"] == "hello"

    tool_start = Enum.find(events, &(&1.event_type == :tool_call_started))
    assert tool_start.payload["tool_call_id"] == "tool-1"
    assert tool_start.payload["args"]["api_key"] == "[REDACTED]"

    tool_end = Enum.find(events, &(&1.event_type == :tool_call_finished))
    assert tool_end.payload["tool_call_id"] == "tool-1"
    :ok = Store.close(db)
  end

  test "subscriber disconnects are durably recorded", %{tmp_dir: tmp_dir} do
    log_name = unique_name("disconnect-log")

    log_pid =
      start_supervised!(
        {EventLog, name: log_name, db_dir: tmp_dir, retention_sweep?: false, health_check: :none}
      )

    session =
      start_supervised!(
        {Session,
         session_id: "disconnect-session",
         provider: ReplayProvider,
         event_log_server: log_name,
         persist?: false,
         hooks_enabled?: false,
         idle_gc_timeout_ms: 0}
      )

    client =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(client, :kill) end)

    assert :ok = Session.subscribe(session, client, role: :driver)
    assert :ok = Session.unsubscribe(session, client)

    {:ok, db} = EventLog.open_read_connection(db_dir: tmp_dir)
    events = wait_for_event(db, "disconnect-session", :user_disconnected, session, log_pid)
    disconnected = Enum.find(events, &(&1.event_type == :user_disconnected))

    assert disconnected.payload["role"] == "driver"
    assert disconnected.payload["reason"] == ":detached"
    assert Session.status(session) == :idle
    :ok = Store.close(db)
  end

  test "dequeued steering prompts are recorded with content", %{tmp_dir: tmp_dir} do
    log_name = unique_name("steering-log")

    log_pid =
      start_supervised!(
        {EventLog, name: log_name, db_dir: tmp_dir, retention_sweep?: false, health_check: :none}
      )

    session =
      start_supervised!(
        {Session,
         session_id: "steering-session",
         provider: SteeringProvider,
         event_log_server: log_name,
         persist?: false,
         hooks_enabled?: false}
      )

    :sys.get_state(session)
    assert :ok = Session.send_prompt(session, "first")
    wait_for_status(session, :thinking)
    assert {:queued, :steering} = Session.send_prompt(session, "while busy")
    assert ["while busy"] = Session.dequeue_steering(session)
    {:ok, db} = EventLog.open_read_connection(db_dir: tmp_dir)
    user_texts = wait_for_user_texts(db, "steering-session", session, log_pid)

    assert "first" in user_texts
    assert "while busy" in user_texts
    :ok = Store.close(db)
  end

  test "history remains queryable after the session process dies", %{tmp_dir: tmp_dir} do
    log_name = unique_name("crash-log")

    log_pid =
      start_supervised!(
        {EventLog, name: log_name, db_dir: tmp_dir, retention_sweep?: false, health_check: :none}
      )

    session =
      start_supervised!(
        {Session,
         session_id: "crash-session",
         provider: ReplayProvider,
         event_log_server: log_name,
         persist?: false,
         hooks_enabled?: false}
      )

    :sys.get_state(session)
    Session.add_system_message(session, "before crash", :info)
    :sys.get_state(session)
    :sys.get_state(log_pid)

    ref = Process.monitor(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^ref, :process, ^session, :killed}

    {:ok, db} = EventLog.open_read_connection(db_dir: tmp_dir)
    assert {:ok, events} = EventLog.events_after(db, "crash-session", 0, 50)
    assert Enum.any?(events, &(&1.event_type == :message_changed))
    :ok = Store.close(db)
  end

  @spec wait_for_status(pid(), Session.status(), non_neg_integer()) :: Session.status()
  defp wait_for_status(session, status, attempts \\ 20)

  defp wait_for_status(session, status, attempts) when attempts > 0 do
    current = Session.status(session)

    if current == status do
      current
    else
      wait_for_status(session, status, attempts - 1)
    end
  end

  defp wait_for_status(session, _status, 0), do: Session.status(session)

  @spec wait_for_user_texts(Store.db(), String.t(), pid(), pid(), non_neg_integer()) :: [
          String.t()
        ]
  defp wait_for_user_texts(db, session_id, session_pid, log_pid, attempts \\ 20)

  defp wait_for_user_texts(db, session_id, session_pid, log_pid, attempts) when attempts > 0 do
    :sys.get_state(session_pid)
    :sys.get_state(log_pid)
    {:ok, events} = EventLog.events_after(db, session_id, 0, 50)

    user_texts =
      events |> Enum.filter(&(&1.event_type == :user_message)) |> Enum.map(& &1.payload["text"])

    if "first" in user_texts and "while busy" in user_texts do
      user_texts
    else
      wait_for_user_texts(db, session_id, session_pid, log_pid, attempts - 1)
    end
  end

  defp wait_for_user_texts(db, session_id, _session_pid, _log_pid, 0) do
    {:ok, events} = EventLog.events_after(db, session_id, 0, 50)
    events |> Enum.filter(&(&1.event_type == :user_message)) |> Enum.map(& &1.payload["text"])
  end

  @spec wait_for_event(
          Store.db(),
          String.t(),
          MingaAgent.EventLog.EventRecord.event_type(),
          pid(),
          pid(),
          non_neg_integer()
        ) :: [MingaAgent.EventLog.EventRecord.t()]
  defp wait_for_event(db, session_id, event_type, session_pid, log_pid, attempts \\ 20)

  defp wait_for_event(db, session_id, event_type, session_pid, log_pid, attempts)
       when attempts > 0 do
    :sys.get_state(session_pid)
    :sys.get_state(log_pid)
    {:ok, events} = EventLog.events_after(db, session_id, 0, 50)

    if Enum.any?(events, &(&1.event_type == event_type)) do
      events
    else
      wait_for_event(db, session_id, event_type, session_pid, log_pid, attempts - 1)
    end
  end

  defp wait_for_event(db, session_id, _event_type, _session_pid, _log_pid, 0) do
    {:ok, events} = EventLog.events_after(db, session_id, 0, 50)
    events
  end

  @spec unique_name(String.t()) :: atom()
  defp unique_name(prefix) do
    String.to_atom("#{prefix}-#{System.unique_integer([:positive])}")
  end
end
