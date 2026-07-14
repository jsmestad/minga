defmodule MingaAgent.EventLog.SessionIntegrationTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Event
  alias MingaAgent.EventLog
  alias MingaAgent.EventLog.ControllableStore
  alias MingaAgent.EventLog.Failure
  alias MingaAgent.EventLog.Store
  alias MingaAgent.Session
  alias MingaAgent.TodoItem

  @moduletag :tmp_dir
  @event_timeout 2_000

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
      {:ok,
       %{
         subscriber: Keyword.fetch!(opts, :subscriber),
         prompt_observer: Keyword.get(opts, :prompt_observer)
       }}
    end

    @impl true
    def handle_call({:prompt, text}, _from, state) do
      send(state.subscriber, {:agent_provider_event, %Event.AgentStart{}})
      send(state.subscriber, {:agent_provider_event, %Event.TextDelta{delta: text}})
      notify_prompt_observer(state.prompt_observer, text)
      {:reply, :ok, state}
    end

    @impl true
    def handle_cast(:abort, state), do: {:noreply, state}
    def handle_cast(:new_session, state), do: {:noreply, state}

    defp notify_prompt_observer(nil, _text), do: :ok
    defp notify_prompt_observer(pid, text), do: send(pid, {:steering_provider_prompt, text})
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

  defmodule TodoProvider do
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
         %Event.TodoPlan{
           todos: [
             %TodoItem{id: "1", description: "Inspect files", status: :in_progress}
           ]
         }}
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

    db = open_read_connection!(tmp_dir, log_pid)
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

  test "todo plans are recorded as JSON-safe payloads for replay", %{tmp_dir: tmp_dir} do
    log_name = unique_name("todo-log")

    log_pid =
      start_supervised!(
        {EventLog, name: log_name, db_dir: tmp_dir, retention_sweep?: false, health_check: :none}
      )

    session =
      start_supervised!(
        {Session,
         session_id: "todo-session",
         provider: TodoProvider,
         event_log_server: log_name,
         persist?: false,
         hooks_enabled?: false}
      )

    :sys.get_state(session)
    assert :ok = Session.send_prompt(session, "plan this")
    :sys.get_state(session)
    :sys.get_state(log_pid)

    db = open_read_connection!(tmp_dir, log_pid)
    events = wait_for_event(db, "todo-session", :todo_plan_updated, session, log_pid)
    todo_event = Enum.find(events, &(&1.event_type == :todo_plan_updated))

    assert todo_event.payload["todos"] == [
             %{"id" => "1", "description" => "Inspect files", "status" => "in_progress"}
           ]

    assert JSON.decode!(JSON.encode!(todo_event.payload)) == todo_event.payload
    :ok = Store.close(db)
  end

  test "event log recursively redacts secrets and process identifiers", %{tmp_dir: tmp_dir} do
    log_name = unique_name("redaction-log")

    log_pid =
      start_supervised!(
        {EventLog, name: log_name, db_dir: tmp_dir, retention_sweep?: false, health_check: :none}
      )

    assert {:queued, receipt} =
             EventLog.record(
               "redaction-session",
               :system_message,
               %{
                 remote_token: "remote-secret",
                 nested: %{
                   access_token: "access-secret",
                   refresh_token: "refresh-secret",
                   authorization: "Bearer secret",
                   owner_pid: self(),
                   owner_ref: make_ref()
                 }
               },
               log_name
             )

    assert {:persisted, _event_id} = EventLog.await(receipt)
    assert :ok = EventLog.await_idle(log_pid)

    db = open_read_connection!(tmp_dir, log_pid)
    {:ok, [event]} = EventLog.events_after(db, "redaction-session", 0, 10)
    :ok = Store.close(db)

    assert event.payload["remote_token"] == "[REDACTED]"
    assert event.payload["nested"]["access_token"] == "[REDACTED]"
    assert event.payload["nested"]["refresh_token"] == "[REDACTED]"
    assert event.payload["nested"]["authorization"] == "[REDACTED]"
    assert event.payload["nested"]["owner_pid"] == "[PID]"
    assert event.payload["nested"]["owner_ref"] == "[REFERENCE]"
  end

  test "session stays responsive to a stalled critical write and exposes commitment failure" do
    log_name = unique_name("session-failure-log")

    start_supervised!(
      {EventLog,
       name: log_name,
       store_backend: ControllableStore,
       store_backend_opts: [controller: self()],
       writer_restart_delay_ms: 60_000,
       retention_sweep?: false,
       health_check: :none}
    )

    assert_receive {:event_log_store_open, writer, _path}, @event_timeout
    send(writer, {:event_log_store_open_result, :ok})

    session =
      start_supervised!(
        {Session,
         session_id: "failure-session",
         provider: ReplayProvider,
         event_log_server: log_name,
         persist?: false,
         hooks_enabled?: false}
      )

    assert :ok = Session.subscribe(session, self(), role: :viewer)
    assert_receive {:agent_event, ^session, {:credentials_status, _configured?}}
    assert_receive {:event_log_store_insert, ^writer, %{event_type: :session_started}}
    assert Session.status(session) == :idle

    send(writer, {:event_log_store_insert_result, {:error, :disk_full}})

    assert_receive {:agent_event, ^session,
                    %Failure{
                      stage: :persistence,
                      receipt: receipt,
                      event_type: :session_started,
                      reason: :disk_full
                    }}

    assert is_reference(receipt)

    Session.add_system_message(session, "persistence recovered", :info)
    :sys.get_state(session)
    assert_receive {:event_log_store_insert, ^writer, %{event_type: :system_message}}
    send(writer, {:event_log_store_insert_result, {:ok, 41}})
    assert :ok = EventLog.await_idle(log_name)
    :sys.get_state(session)

    parent = self()

    late_subscriber =
      spawn(fn ->
        Enum.each(1..2, fn _index ->
          receive do
            event -> send(parent, {:late_subscriber, event})
          end
        end)
      end)

    assert :ok = Session.subscribe(session, late_subscriber, role: :viewer)

    assert_receive {:late_subscriber,
                    {:agent_event, ^session, {:credentials_status, _configured?}}}

    assert_receive {:late_subscriber,
                    {:agent_event, ^session,
                     %Failure{
                       stage: :persistence,
                       receipt: nil,
                       event_type: :session_started,
                       reason: :disk_full
                     }}}

    refute_receive {:event_log_store_insert, ^writer, %{event_type: :error}}
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
    :sys.get_state(log_pid)

    db = open_read_connection!(tmp_dir, log_pid)
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
         hooks_enabled?: false,
         provider_opts: [prompt_observer: self()]}
      )

    :sys.get_state(session)
    assert :ok = Session.send_prompt(session, "first")
    assert_receive {:steering_provider_prompt, "first"}
    wait_for_status(session, :thinking)
    assert {:queued, :steering} = Session.send_prompt(session, "while busy")
    assert ["while busy"] = Session.dequeue_steering(session)
    db = open_read_connection!(tmp_dir, log_pid)
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
    assert :ok = EventLog.await_idle(log_pid)

    ref = Process.monitor(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^ref, :process, ^session, :killed}

    db = open_read_connection!(tmp_dir, log_pid)
    assert {:ok, events} = EventLog.events_after(db, "crash-session", 0, 50)
    assert Enum.any?(events, &(&1.event_type == :session_started))
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
    assert :ok = EventLog.await_idle(log_pid)
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

  @spec open_read_connection!(String.t(), pid()) :: Store.db()
  defp open_read_connection!(tmp_dir, log_pid) do
    assert :ok = EventLog.await_idle(log_pid)
    assert {:ok, db} = EventLog.open_read_connection(db_dir: tmp_dir)
    db
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
    assert :ok = EventLog.await_idle(log_pid)
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
