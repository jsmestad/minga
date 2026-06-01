defmodule MingaAgent.SessionManagerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MingaAgent.Providers.RecordingProvider
  alias MingaAgent.SessionManager
  alias MingaAgent.SessionManager.SessionRestartedEvent
  alias MingaAgent.SessionManager.SessionStoppedEvent
  alias MingaAgent.SessionStore
  alias MingaAgent.Subagent.Handle

  setup do
    # Start an isolated SessionManager with a unique name per test.
    name = :"session_manager_#{System.unique_integer([:positive])}"

    manager =
      start_supervised!({SessionManager, [name: name]}, id: name)

    %{manager: manager}
  end

  describe "start_session/2" do
    test "starts a session and returns a human-readable ID", %{manager: manager} do
      assert {:ok, session_id, pid} = SessionManager.start_session(manager, [])
      assert session_id == "session-1"
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "increments session IDs", %{manager: manager} do
      {:ok, "session-1", _pid1} = SessionManager.start_session(manager, [])
      {:ok, "session-2", _pid2} = SessionManager.start_session(manager, [])
      {:ok, "session-3", _pid3} = SessionManager.start_session(manager, [])
    end

    test "honors a supplied stable session id", %{manager: manager} do
      assert {:ok, "workdir-stable", pid} =
               SessionManager.start_session(manager, session_id: "workdir-stable")

      assert {:ok, ^pid} = SessionManager.get_session(manager, "workdir-stable")
    end

    test "start_or_get_session reuses an existing stable session", %{manager: manager} do
      assert {:ok, "workdir-stable", pid} =
               SessionManager.start_or_get_session(manager, "workdir-stable", [])

      assert {:ok, "workdir-stable", ^pid} =
               SessionManager.start_or_get_session(manager, "workdir-stable", [])
    end

    test "stable_session_id_for_workdir is deterministic" do
      id = SessionManager.stable_session_id_for_workdir("/tmp/my-project")
      assert id == SessionManager.stable_session_id_for_workdir("/tmp/my-project")
      assert String.starts_with?(id, "workdir-")
    end

    test "mints a token for brokered remote control", %{manager: manager} do
      {:ok, session_id, _pid} = SessionManager.start_session(manager, [])
      assert {:ok, token} = SessionManager.session_token(manager, session_id)
      assert is_binary(token)
      assert byte_size(token) > 20
    end

    test "reuses a persisted remote token for a stable session", %{manager: manager} do
      dir =
        Path.join(
          System.tmp_dir!(),
          "session-manager-token-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf(dir) end)

      :ok =
        MingaAgent.SessionStore.save(
          %{
            id: "workdir-stable",
            remote_token: "persisted-token",
            timestamp: DateTime.to_iso8601(DateTime.utc_now()),
            model_name: "test",
            messages: [],
            usage: MingaAgent.TurnUsage.new()
          },
          dir
        )

      {:ok, "workdir-stable", _pid} =
        SessionManager.start_or_get_session(manager, "workdir-stable", session_store_dir: dir)

      assert {:ok, "persisted-token"} = SessionManager.session_token(manager, "workdir-stable")
    end

    test "logs and mints a new token when persisted remote token file is corrupt", %{
      manager: manager
    } do
      dir =
        Path.join(
          System.tmp_dir!(),
          "session-manager-token-corrupt-#{System.unique_integer([:positive])}"
        )

      session_id = "token-corrupt-#{System.unique_integer([:positive])}"
      sessions_dir = SessionStore.sessions_dir(dir)
      File.mkdir_p!(sessions_dir)
      File.write!(Path.join(sessions_dir, "#{session_id}.json"), "{not json")

      on_exit(fn -> File.rm_rf(dir) end)

      log =
        capture_log(fn ->
          assert {:ok, ^session_id, pid} =
                   SessionManager.start_session(manager,
                     session_id: session_id,
                     session_store_dir: dir
                   )

          assert {:ok, token} = SessionManager.session_token(manager, session_id)
          assert is_binary(token)
          assert Process.alive?(pid)
        end)

      assert log =~ "Failed to load persisted remote token"
      assert log =~ session_id
      assert log =~ dir
    end
  end

  describe "stop_session/2" do
    test "stops an existing session", %{manager: manager} do
      {:ok, session_id, pid} = SessionManager.start_session(manager, [])
      assert Process.alive?(pid)

      assert :ok = SessionManager.stop_session(manager, session_id)
      refute Process.alive?(pid)
    end

    test "returns error for unknown session ID", %{manager: manager} do
      assert {:error, :not_found} = SessionManager.stop_session(manager, "nonexistent")
    end
  end

  describe "get_session/2" do
    test "returns pid for known session", %{manager: manager} do
      {:ok, session_id, pid} = SessionManager.start_session(manager, [])
      assert {:ok, ^pid} = SessionManager.get_session(manager, session_id)
    end

    test "returns error for unknown session", %{manager: manager} do
      assert {:error, :not_found} = SessionManager.get_session(manager, "nope")
    end
  end

  describe "session_id_for_pid/2" do
    test "returns session ID for known pid", %{manager: manager} do
      {:ok, session_id, pid} = SessionManager.start_session(manager, [])
      assert {:ok, ^session_id} = SessionManager.session_id_for_pid(manager, pid)
    end

    test "returns error for unknown pid", %{manager: manager} do
      assert {:error, :not_found} = SessionManager.session_id_for_pid(manager, self())
    end
  end

  describe "list_sessions/1" do
    test "returns empty list when no sessions", %{manager: manager} do
      assert [] = SessionManager.list_sessions(manager)
    end

    test "returns all active sessions", %{manager: manager} do
      {:ok, id1, pid1} = SessionManager.start_session(manager, [])
      {:ok, id2, pid2} = SessionManager.start_session(manager, [])

      sessions = SessionManager.list_sessions(manager)
      assert length(sessions) == 2

      ids = Enum.map(sessions, &elem(&1, 0))
      pids = Enum.map(sessions, &elem(&1, 1))

      assert id1 in ids
      assert id2 in ids
      assert pid1 in pids
      assert pid2 in pids
    end
  end

  describe "abort/2" do
    test "returns error for unknown session", %{manager: manager} do
      assert {:error, :not_found} = SessionManager.abort(manager, "unknown")
    end
  end

  describe "stop_session_by_pid/2" do
    test "stops a session by its PID", %{manager: manager} do
      {:ok, session_id, pid} = SessionManager.start_session(manager, [])
      assert Process.alive?(pid)

      assert :ok = SessionManager.stop_session_by_pid(manager, pid)
      refute Process.alive?(pid)

      assert {:error, :not_found} = SessionManager.get_session(manager, session_id)
    end

    test "returns error for unknown pid", %{manager: manager} do
      assert {:error, :not_found} = SessionManager.stop_session_by_pid(manager, self())
    end
  end

  describe "session DOWN monitoring" do
    test "restarts a crashed session, refreshes child handles, and keeps the registry consistent",
         %{manager: manager} do
      Minga.Events.subscribe(:agent_session_restarted)
      Minga.Events.subscribe(:agent_session_stopped)

      session_id = "restart-#{System.unique_integer([:positive])}"

      assert {:ok, ^session_id, pid} =
               SessionManager.start_session(manager, session_id: session_id)

      assert {:ok, token} = SessionManager.session_token(manager, session_id)

      assert {:ok, %Handle{} = child_handle} =
               SessionManager.start_background_subagent(manager, pid, "child work",
                 session_opts: []
               )

      assert child_handle.parent_pid == pid
      assert [^child_handle] = SessionManager.list_background_subagents(manager, pid)

      :sys.get_state(manager)
      assert MingaAgent.Session.status(child_handle.pid) in [:idle, :thinking]

      new_pid = crash_and_wait_for_restart(manager, session_id, pid)

      assert_receive {
                       :minga_event,
                       :agent_session_restarted,
                       %SessionRestartedEvent{
                         session_id: ^session_id,
                         old_pid: ^pid,
                         new_pid: ^new_pid,
                         reason: :killed
                       }
                     },
                     1000

      assert {:ok, ^new_pid} = SessionManager.get_session(manager, session_id)
      assert {:ok, ^session_id} = SessionManager.session_id_for_pid(manager, new_pid)
      assert {:ok, ^token} = SessionManager.session_token(manager, session_id)

      sessions = SessionManager.list_sessions(manager)

      assert Enum.any?(sessions, fn {listed_id, listed_pid, _metadata} ->
               listed_id == session_id and listed_pid == new_pid
             end)

      refute Enum.any?(sessions, fn {listed_id, listed_pid, _metadata} ->
               listed_id == session_id and listed_pid == pid
             end)

      assert [updated_child_handle] = SessionManager.list_background_subagents(manager, new_pid)
      assert updated_child_handle.session_id == child_handle.session_id
      assert updated_child_handle.pid == child_handle.pid
      assert updated_child_handle.parent_pid == new_pid
      assert [] = SessionManager.list_background_subagents(manager, pid)

      refute_receive {:minga_event, :agent_session_stopped,
                      %SessionStoppedEvent{session_id: ^session_id, pid: ^pid, reason: :killed}},
                     50
    end

    test "restarts a background subagent and refreshes its pid in listings", %{manager: manager} do
      Minga.Events.subscribe(:agent_session_restarted)

      assert {:ok, %Handle{} = handle} =
               SessionManager.start_background_subagent(manager, nil, "child work",
                 session_opts: []
               )

      old_pid = handle.pid
      session_id = handle.session_id
      new_pid = crash_and_wait_for_restart(manager, session_id, old_pid)

      assert_receive {
                       :minga_event,
                       :agent_session_restarted,
                       %SessionRestartedEvent{
                         session_id: ^session_id,
                         old_pid: ^old_pid,
                         new_pid: ^new_pid,
                         reason: :killed
                       }
                     },
                     1000

      [updated_handle] = SessionManager.list_background_subagents(manager, nil)
      assert updated_handle.session_id == handle.session_id
      assert updated_handle.pid == new_pid
      assert updated_handle.parent_pid == nil
      refute_receive {:minga_event, :agent_session_stopped, _}, 50
    end
  end

  test "idle GC shutdown stops a managed session without restart", %{manager: manager} do
    Minga.Events.subscribe(:agent_session_stopped)

    {:ok, session_id, pid} = SessionManager.start_session(manager, idle_gc_timeout_ms: 1)

    assert :ok = MingaAgent.Session.subscribe(pid)

    ref = Process.monitor(pid)
    assert :ok = MingaAgent.Session.unsubscribe(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

    assert_receive {
                     :minga_event,
                     :agent_session_stopped,
                     %SessionStoppedEvent{session_id: ^session_id, pid: ^pid, reason: :normal}
                   },
                   1000

    refute_receive {:minga_event, :agent_session_restarted, _}, 50
    assert {:error, :not_found} = SessionManager.get_session(manager, session_id)
  end

  test "repeated crash restarts eventually exhaust and stop terminally", %{manager: manager} do
    Minga.Events.subscribe(:agent_session_restarted)
    Minga.Events.subscribe(:agent_session_stopped)

    {:ok, session_id, pid} =
      SessionManager.start_session(manager,
        restart_max_attempts: 2,
        restart_backoff_base_ms: 1,
        restart_backoff_max_ms: 1,
        restart_window_ms: 60_000
      )

    first_restart = crash_and_wait_for_restart(manager, session_id, pid)

    assert_receive {
                     :minga_event,
                     :agent_session_restarted,
                     %SessionRestartedEvent{
                       session_id: ^session_id,
                       old_pid: ^pid,
                       new_pid: ^first_restart,
                       reason: :killed
                     }
                   },
                   1000

    second_restart = crash_and_wait_for_restart(manager, session_id, first_restart)

    assert_receive {
                     :minga_event,
                     :agent_session_restarted,
                     %SessionRestartedEvent{
                       session_id: ^session_id,
                       old_pid: ^first_restart,
                       new_pid: ^second_restart,
                       reason: :killed
                     }
                   },
                   1000

    ref = Process.monitor(second_restart)
    Process.exit(second_restart, :kill)
    assert_receive {:DOWN, ^ref, :process, ^second_restart, :killed}, 1000

    assert_receive {
                     :minga_event,
                     :agent_session_stopped,
                     %SessionStoppedEvent{
                       session_id: ^session_id,
                       pid: ^second_restart,
                       reason: {:restart_exhausted, :killed}
                     }
                   },
                   1000

    refute_receive {:minga_event, :agent_session_restarted, _}, 50
    assert {:error, :not_found} = SessionManager.get_session(manager, session_id)
  end

  test "restart attempt counters reset after the window expires", %{manager: manager} do
    Minga.Events.subscribe(:agent_session_restarted)

    {:ok, session_id, pid} =
      SessionManager.start_session(manager,
        restart_max_attempts: 1,
        restart_backoff_base_ms: 1,
        restart_backoff_max_ms: 1,
        restart_window_ms: 1
      )

    first_restart = crash_and_wait_for_restart(manager, session_id, pid)

    assert_receive {
                     :minga_event,
                     :agent_session_restarted,
                     %SessionRestartedEvent{
                       session_id: ^session_id,
                       old_pid: ^pid,
                       new_pid: ^first_restart,
                       reason: :killed
                     }
                   },
                   1000

    receive do
    after
      10 -> :ok
    end

    second_restart = crash_and_wait_for_restart(manager, session_id, first_restart)

    assert_receive {
                     :minga_event,
                     :agent_session_restarted,
                     %SessionRestartedEvent{
                       session_id: ^session_id,
                       old_pid: ^first_restart,
                       new_pid: ^second_restart,
                       reason: :killed
                     }
                   },
                   1000
  end

  test "managed restarts restore persisted state before broadcasting", %{manager: manager} do
    Minga.Events.subscribe(:agent_session_restarted)

    dir =
      Path.join(
        System.tmp_dir!(),
        "session-manager-restore-#{System.unique_integer([:positive])}"
      )

    session_id = "restore-#{System.unique_integer([:positive])}"

    on_exit(fn -> File.rm_rf(dir) end)

    :ok =
      SessionStore.save(
        %{
          id: session_id,
          timestamp: DateTime.to_iso8601(DateTime.utc_now()),
          model_name: "test-model",
          messages: [{:user, "restored"}, {:assistant, "reply"}],
          usage: MingaAgent.TurnUsage.new()
        },
        dir
      )

    {:ok, ^session_id, pid} =
      SessionManager.start_session(manager,
        session_id: session_id,
        provider: RecordingProvider,
        provider_opts: [],
        session_store_dir: dir
      )

    new_pid = crash_and_wait_for_restart(manager, session_id, pid)

    assert_receive {
                     :minga_event,
                     :agent_session_restarted,
                     %SessionRestartedEvent{
                       session_id: ^session_id,
                       old_pid: ^pid,
                       new_pid: ^new_pid
                     }
                   },
                   1000

    assert Enum.any?(MingaAgent.Session.messages(new_pid), fn
             {:user, "restored"} -> true
             _ -> false
           end)

    provider = MingaAgent.Session.get_provider(new_pid)
    assert {:ok, %{seeded_messages: seeded_messages}} = RecordingProvider.get_state(provider)

    assert Enum.any?(seeded_messages, fn
             {:user, "restored"} -> true
             _ -> false
           end)
  end

  test "managed restarts surface degraded restore when prior context is missing", %{
    manager: manager
  } do
    Minga.Events.subscribe(:agent_session_restarted)

    dir =
      Path.join(
        System.tmp_dir!(),
        "session-manager-restore-missing-#{System.unique_integer([:positive])}"
      )

    session_id = "restore-missing-#{System.unique_integer([:positive])}"

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    log =
      capture_log(fn ->
        {:ok, ^session_id, pid} =
          SessionManager.start_session(manager,
            session_id: session_id,
            session_store_dir: dir
          )

        new_pid = crash_and_wait_for_restart(manager, session_id, pid)

        assert_receive {
                         :minga_event,
                         :agent_session_restarted,
                         %SessionRestartedEvent{
                           session_id: ^session_id,
                           old_pid: ^pid,
                           new_pid: ^new_pid
                         }
                       },
                       1000

        :sys.get_state(new_pid)

        assert Enum.any?(MingaAgent.Session.messages(new_pid), fn
                 {:system, text, level} ->
                   level == :error and text =~ "prior context could not be restored"

                 _ ->
                   false
               end)
      end)

    assert log =~ session_id
    assert log =~ dir
    assert log =~ "could not restore prior context"
  end

  describe "background prompt retry logging" do
    test "logs an actionable error when retries exhaust after an exit", %{manager: manager} do
      {:ok, session_id, _live_pid} =
        SessionManager.start_session(manager,
          provider: Minga.Test.StubProvider,
          provider_opts: []
        )

      dead_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      ref = Process.monitor(dead_pid)
      send(dead_pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, :normal}

      :sys.replace_state(manager, fn state ->
        %{state | sessions: Map.update!(state.sessions, session_id, &%{&1 | pid: dead_pid})}
      end)

      log =
        capture_log(fn ->
          send(manager, {:send_background_prompt, session_id, "child work", 100})
          :sys.get_state(manager)
        end)

      assert log =~ session_id
      assert log =~ inspect(dead_pid)
      assert log =~ "after 101 attempts"
      assert log =~ "failed to accept prompt"
    end
  end

  @spec crash_and_wait_for_restart(GenServer.server(), String.t(), pid()) :: pid()
  defp crash_and_wait_for_restart(manager, session_id, pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
    wait_until_restarted_session(manager, session_id, pid)
  end

  @spec wait_until_restarted_session(GenServer.server(), String.t(), pid(), non_neg_integer()) ::
          pid()
  defp wait_until_restarted_session(manager, session_id, old_pid, attempts \\ 100)

  defp wait_until_restarted_session(_manager, session_id, old_pid, 0) do
    flunk("session #{session_id} did not restart after #{inspect(old_pid)} crashed")
  end

  defp wait_until_restarted_session(manager, session_id, old_pid, attempts) do
    :sys.get_state(manager)

    case SessionManager.get_session(manager, session_id) do
      {:ok, ^old_pid} ->
        receive do
        after
          10 -> wait_until_restarted_session(manager, session_id, old_pid, attempts - 1)
        end

      {:ok, pid} ->
        pid

      {:error, :not_found} ->
        receive do
        after
          10 -> wait_until_restarted_session(manager, session_id, old_pid, attempts - 1)
        end
    end
  end
end
