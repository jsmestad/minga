defmodule MingaAgent.RemoteAPITest do
  # Uses the global MingaAgent.SessionManager broker boundary.
  use ExUnit.Case, async: false

  alias MingaAgent.EventLog
  alias MingaAgent.RemoteAPI
  alias MingaAgent.Session
  alias MingaAgent.SessionManager

  test "start_session returns a broker token and rejects the wrong token" do
    assert {:ok, %{session_id: session_id, pid: pid, token: token}} = RemoteAPI.start_session([])
    on_exit(fn -> SessionManager.stop_session(session_id) end)

    assert is_pid(pid)
    assert is_binary(token)
    assert :ok = RemoteAPI.authorize(session_id, token)
    assert {:error, :unauthorized} = RemoteAPI.authorize(session_id, "wrong-token")
  end

  test "attach assigns one driver and refuses viewer mutations" do
    assert {:ok, %{session_id: session_id, token: token}} = RemoteAPI.start_session([])
    on_exit(fn -> SessionManager.stop_session(session_id) end)

    driver = idle_process()
    viewer = idle_process()

    on_exit(fn ->
      Process.exit(driver, :kill)
      Process.exit(viewer, :kill)
    end)

    assert {:ok, %{role: :driver, messages: messages, snapshot: snapshot}} =
             RemoteAPI.attach(session_id, token, driver, role: :driver)

    assert is_list(messages)
    assert is_map(snapshot)

    assert {:ok, %{role: :viewer}} = RemoteAPI.attach(session_id, token, viewer, role: :driver)
    assert {:error, :not_driver} = RemoteAPI.send_prompt(session_id, token, viewer, "not allowed")
  end

  test "detach removes the subscriber without stopping the session" do
    assert {:ok, %{session_id: session_id, token: token}} = RemoteAPI.start_session([])
    on_exit(fn -> SessionManager.stop_session(session_id) end)

    client = idle_process()
    on_exit(fn -> Process.exit(client, :kill) end)

    assert {:ok, %{role: :driver}} = RemoteAPI.attach(session_id, token, client, role: :driver)
    assert :ok = RemoteAPI.detach(session_id, token, client)
    assert {:error, :not_driver} = RemoteAPI.send_prompt(session_id, token, client, "not allowed")
    assert {:ok, _pid} = SessionManager.get_session(session_id)
  end

  test "broker starts OAuth flows only for the attached driver" do
    assert {:ok, %{session_id: session_id, token: token}} = RemoteAPI.start_session([])
    on_exit(fn -> SessionManager.stop_session(session_id) end)

    driver = idle_process()
    viewer = idle_process()
    on_exit(fn -> Process.exit(driver, :kill) end)
    on_exit(fn -> Process.exit(viewer, :kill) end)

    assert {:ok, %{role: :driver}} = RemoteAPI.attach(session_id, token, driver, role: :driver)
    assert {:ok, %{role: :viewer}} = RemoteAPI.attach(session_id, token, viewer, role: :viewer)
    assert {:error, :not_driver} = RemoteAPI.begin_oauth(session_id, token, viewer)

    assert {:ok, url, ref} = RemoteAPI.begin_oauth(session_id, token, driver)
    assert is_binary(url)
    assert is_binary(ref)

    assert {:error, message} =
             RemoteAPI.complete_oauth(session_id, token, driver, "missing-ref", "code")

    assert message =~ "Unknown OAuth flow"
  end

  test "attach returns cursor catch-up events" do
    session_id = "remote-api-catchup-#{System.unique_integer([:positive])}"
    assert {:ok, ^session_id, pid} = SessionManager.start_session(session_id: session_id)
    assert {:ok, token} = SessionManager.session_token(session_id)
    on_exit(fn -> SessionManager.stop_session(session_id) end)

    :sys.get_state(pid)
    Session.add_system_message(pid, "missed while away", :info)
    :sys.get_state(pid)
    :sys.get_state(EventLog)
    wait_for_events(session_id, 0, 1)

    driver = idle_process()
    on_exit(fn -> Process.exit(driver, :kill) end)

    assert {:ok, %{events: catchup, latest_event_id: attach_latest}} =
             RemoteAPI.attach(session_id, token, driver, role: :driver, last_seen_event_id: 0)

    assert Enum.any?(catchup, &(&1.event_type in [:system_message, :message_changed]))

    assert {:ok, %{events: reattach_events, latest_event_id: reattach_latest}} =
             RemoteAPI.attach(session_id, token, driver,
               role: :driver,
               last_seen_event_id: attach_latest
             )

    assert reattach_latest >= attach_latest
    assert Enum.all?(reattach_events, &(&1.id > attach_latest))
  end

  test "stop_session ends a remote session and removes it from the list" do
    assert {:ok, %{session_id: session_id, token: token}} = RemoteAPI.start_session([])
    assert Enum.any?(RemoteAPI.list_sessions(), &(&1.session_id == session_id))

    assert :ok = RemoteAPI.stop_session(session_id, token)
    refute Enum.any?(RemoteAPI.list_sessions(), &(&1.session_id == session_id))
    assert {:error, :not_found} = SessionManager.get_session(session_id)
  end

  test "start_or_get_for_workdir reuses the deterministic normalized session" do
    parent = Path.join(System.tmp_dir!(), "remote-api-workdir")
    workdir = Path.join(parent, "app")
    equivalent_workdir = Path.join([parent, "app", "..", "app"])

    assert {:ok, %{session_id: session_id, pid: pid, metadata: metadata}} =
             RemoteAPI.start_or_get_for_workdir(equivalent_workdir)

    on_exit(fn -> SessionManager.stop_session(session_id) end)

    assert metadata.workdir == Path.expand(workdir)

    assert {:ok, %{session_id: ^session_id, pid: ^pid}} =
             RemoteAPI.start_or_get_for_workdir(workdir)
  end

  test "stop_workdir_session stops the normalized workdir session" do
    parent = Path.join(System.tmp_dir!(), "remote-api-stop-workdir")
    workdir = Path.join(parent, "app")
    equivalent_workdir = Path.join([parent, "app", "..", "app"])

    assert {:ok, %{session_id: session_id}} =
             RemoteAPI.start_or_get_for_workdir(equivalent_workdir)

    assert :ok = RemoteAPI.stop_workdir_session(workdir)
    assert {:error, :not_found} = SessionManager.get_session(session_id)
  end

  @spec wait_for_events(String.t(), non_neg_integer(), pos_integer(), non_neg_integer()) :: [
          MingaAgent.EventLog.EventRecord.t()
        ]
  defp wait_for_events(session_id, last_seen_event_id, count, attempts \\ 20)

  defp wait_for_events(session_id, last_seen_event_id, count, attempts) when attempts > 0 do
    {:ok, db} = EventLog.open_read_connection()
    {:ok, events} = EventLog.events_after(db, session_id, last_seen_event_id, 100)
    MingaAgent.EventLog.Store.close(db)

    if length(events) >= count do
      events
    else
      wait_for_events(session_id, last_seen_event_id, count, attempts - 1)
    end
  end

  defp wait_for_events(session_id, last_seen_event_id, _count, 0) do
    {:ok, db} = EventLog.open_read_connection()
    {:ok, events} = EventLog.events_after(db, session_id, last_seen_event_id, 100)
    MingaAgent.EventLog.Store.close(db)
    events
  end

  @spec idle_process() :: pid()
  defp idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end
end
