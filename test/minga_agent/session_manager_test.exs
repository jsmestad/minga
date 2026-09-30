defmodule MingaAgent.SessionManagerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias MingaAgent.Providers.RecordingProvider
  alias MingaAgent.Session
  alias MingaAgent.Session.SubscriberLifecycle
  alias MingaAgent.SessionListing
  alias MingaAgent.SessionManager
  alias MingaAgent.SessionManager.SessionRestartedEvent
  alias MingaAgent.SessionManager.SessionStoppedEvent
  alias MingaAgent.SessionStore
  alias MingaAgent.Subagent.Handle

  setup do
    session_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    # Start an isolated SessionManager and session supervisor per test.
    name = :"session_manager_#{System.unique_integer([:positive])}"

    {:ok, manager} =
      SessionManager.start_link(name: name, session_supervisor: session_supervisor)

    Process.unlink(manager)

    on_exit(fn ->
      if Process.alive?(manager) do
        for %SessionListing{id: session_id} <- SessionManager.list_sessions(manager) do
          SessionManager.stop_session(manager, session_id)
        end

        GenServer.stop(manager)
      end
    end)

    %{manager: manager, session_supervisor: session_supervisor}
  end

  describe "start_session/2" do
    test "starts and stops sessions under the configured supervisor", %{
      manager: manager,
      session_supervisor: session_supervisor
    } do
      assert {:ok, session_id, pid} = SessionManager.start_session(manager, [])

      assert [{:undefined, ^pid, :worker, [Session]}] =
               DynamicSupervisor.which_children(session_supervisor)

      assert :ok = SessionManager.stop_session(manager, session_id)
      refute Process.alive?(pid)
      assert {:error, :not_found} = SessionManager.get_session(manager, session_id)
      assert [] = DynamicSupervisor.which_children(session_supervisor)
    end

    test "starts a session and returns a human-readable unique ID", %{manager: manager} do
      assert {:ok, session_id, pid} = SessionManager.start_session(manager, [])
      assert String.match?(session_id, ~r/^session-1-[0-9a-f]{8}$/)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "increments the human-readable session ID prefix while keeping IDs unique", %{
      manager: manager
    } do
      {:ok, session_id1, _pid1} = SessionManager.start_session(manager, [])
      {:ok, session_id2, _pid2} = SessionManager.start_session(manager, [])
      {:ok, session_id3, _pid3} = SessionManager.start_session(manager, [])

      assert String.match?(session_id1, ~r/^session-1-[0-9a-f]{8}$/)
      assert String.match?(session_id2, ~r/^session-2-[0-9a-f]{8}$/)
      assert String.match?(session_id3, ~r/^session-3-[0-9a-f]{8}$/)

      assert Enum.uniq([session_id1, session_id2, session_id3]) == [
               session_id1,
               session_id2,
               session_id3
             ]
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

    @tag :tmp_dir
    test "mints and persists a token before returning the session", %{
      manager: manager,
      tmp_dir: dir
    } do
      {:ok, session_id, pid} =
        SessionManager.start_session(manager, session_store_dir: dir)

      assert {:ok, token} = SessionManager.session_token(manager, session_id)
      assert is_binary(token)
      assert byte_size(token) > 20

      assert {:ok, ^token} =
               SessionStore.establish_remote_token(session_id, "replacement-token", dir)

      refute Map.has_key?(:sys.get_state(pid), :remote_token)
    end

    @tag :tmp_dir
    test "keeps the existing remote_token option at the manager boundary", %{
      manager: manager,
      tmp_dir: dir
    } do
      session_id = "supplied-token"

      assert {:ok, ^session_id, pid} =
               SessionManager.start_session(manager,
                 session_id: session_id,
                 remote_token: "caller-token",
                 session_store_dir: dir
               )

      assert {:ok, "caller-token"} = SessionManager.session_token(manager, session_id)

      assert {:ok, "caller-token"} =
               SessionStore.establish_remote_token(session_id, "replacement-token", dir)

      refute Map.has_key?(:sys.get_state(pid), :remote_token)
    end

    @tag :tmp_dir
    test "does not publish a token when durable identity cannot be established", %{
      manager: manager,
      tmp_dir: dir
    } do
      session_id = "blocked-token-store"
      sessions_dir = SessionStore.sessions_dir(dir)
      File.mkdir_p!(sessions_dir)
      File.write!(Path.join(sessions_dir, ".remote_tokens"), "blocks token directory")

      assert {:error, {:remote_token_persistence_failed, _reason}} =
               SessionManager.start_session(manager,
                 session_id: session_id,
                 session_store_dir: dir
               )

      assert {:error, :not_found} = SessionManager.get_session(manager, session_id)
    end

    @tag :tmp_dir
    test "migrates a legacy token and preserves it across transcript saves and manager recovery",
         %{
           manager: manager,
           session_supervisor: session_supervisor,
           tmp_dir: dir
         } do
      session_id = "workdir-stable"
      write_legacy_session(session_id, "persisted-token", dir)

      {:ok, ^session_id, pid} =
        SessionManager.start_or_get_session(manager, session_id,
          session_store_dir: dir,
          hooks_enabled?: false
        )

      assert {:ok, "persisted-token"} = SessionManager.session_token(manager, session_id)

      assert {:ok, "persisted-token"} =
               SessionStore.establish_remote_token(session_id, "replacement-token", dir)

      :ok = Session.add_system_message(pid, "persist transcript without broker identity", :info)
      send(pid, :save_session)

      assert {:system, "persist transcript without broker identity", :info} in Session.messages(
               pid
             )

      assert {:ok, transcript} = SessionStore.load(session_id, dir)
      refute Map.has_key?(transcript, :remote_token)

      assert {:system, "persist transcript without broker identity", :info} in transcript.messages
      refute File.read!(session_path(session_id, dir)) =~ "remote_token"

      :ok = SessionManager.stop_session(manager, session_id)
      GenServer.stop(manager)

      replacement_name = :"replacement_manager_#{System.unique_integer([:positive])}"

      {:ok, replacement_manager} =
        SessionManager.start_link(
          name: replacement_name,
          session_supervisor: session_supervisor
        )

      Process.unlink(replacement_manager)

      on_exit(fn ->
        if Process.alive?(replacement_manager) do
          SessionManager.stop_session(replacement_manager, session_id)
          GenServer.stop(replacement_manager)
        end
      end)

      assert {:ok, ^session_id, replacement_pid} =
               SessionManager.start_or_get_session(replacement_manager, session_id,
                 session_store_dir: dir,
                 hooks_enabled?: false
               )

      assert replacement_pid != pid

      assert {:ok, "persisted-token"} =
               SessionManager.session_token(replacement_manager, session_id)
    end

    @tag :tmp_dir
    test "fails closed when canonical remote identity is corrupt", %{
      manager: manager,
      tmp_dir: dir
    } do
      session_id = "token-corrupt-#{System.unique_integer([:positive])}"
      token_path = remote_token_path(session_id, dir)
      File.mkdir_p!(Path.dirname(token_path))
      File.write!(token_path, "42")

      assert {:error, {:remote_token_persistence_failed, _reason}} =
               SessionManager.start_session(manager,
                 session_id: session_id,
                 session_store_dir: dir
               )

      assert {:error, :not_found} = SessionManager.get_session(manager, session_id)
      assert File.read!(token_path) == "42"
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
      assert Enum.count(sessions) == 2

      ids = Enum.map(sessions, & &1.id)
      pids = Enum.map(sessions, & &1.pid)

      assert id1 in ids
      assert id2 in ids
      assert pid1 in pids
      assert pid2 in pids
    end

    test "keeps a timed-out registration and restores its metadata on a later query", %{
      manager: manager
    } do
      Minga.Events.subscribe(:agent_session_restarted)
      {:ok, slow_id, slow_pid} = SessionManager.start_session(manager, [])
      {:ok, healthy_id, healthy_pid} = SessionManager.start_session(manager, [])
      :ok = :sys.suspend(slow_pid)

      on_exit(fn ->
        if Process.info(slow_pid, :status) == {:status, :suspended}, do: :sys.resume(slow_pid)
      end)

      listings = SessionManager.list_sessions(manager)

      assert %SessionListing{
               id: ^slow_id,
               pid: ^slow_pid,
               details: {:unavailable, :timeout}
             } = Enum.find(listings, &(&1.id == slow_id))

      assert %SessionListing{
               id: ^healthy_id,
               pid: ^healthy_pid,
               details: {:available, healthy_metadata}
             } = Enum.find(listings, &(&1.id == healthy_id))

      assert healthy_metadata.id == healthy_id
      assert {:ok, ^slow_pid} = SessionManager.get_session(manager, slow_id)
      assert Process.alive?(slow_pid)
      refute_receive {:minga_event, :agent_session_restarted, _event}

      :ok = :sys.resume(slow_pid)

      assert %SessionListing{
               id: ^slow_id,
               pid: ^slow_pid,
               details: {:available, restored_metadata}
             } =
               manager
               |> SessionManager.list_sessions()
               |> Enum.find(&(&1.id == slow_id))

      assert restored_metadata.id == slow_id
    end

    test "marks conflicting session-owned metadata as invalid without changing registration", %{
      manager: manager
    } do
      {:ok, session_id, pid} = SessionManager.start_session(manager, [])
      metadata = Session.metadata(pid)

      listing = SessionListing.available(session_id, pid, %{metadata | id: "different-id"})

      assert %SessionListing{
               id: ^session_id,
               pid: ^pid,
               details: {:unavailable, :invalid_details}
             } = listing

      assert %SessionListing{details: {:unavailable, :invalid_details}} =
               SessionListing.available(session_id, pid, %{id: session_id})

      assert {:ok, ^pid} = SessionManager.get_session(manager, session_id)
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

    test "stopping a live session reserves its ID until registered effects exit", %{
      manager: manager
    } do
      {:ok, session_id, session_pid} =
        SessionManager.start_session(manager,
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [],
          persist?: false
        )

      provider_pid = Session.get_provider(session_pid)
      assert is_pid(provider_pid)

      worker_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert :ok =
               SessionManager.register_effect_workers(
                 manager,
                 session_pid,
                 provider_pid,
                 [worker_pid]
               )

      provider_ref = Process.monitor(provider_pid)
      worker_ref = Process.monitor(worker_pid)

      assert :ok = SessionManager.stop_session_by_pid(manager, session_pid)
      assert_receive {:DOWN, ^provider_ref, :process, ^provider_pid, _reason}, 1_000

      assert {:error, :restart_pending} =
               SessionManager.start_session(manager, session_id: session_id)

      send(worker_pid, :stop)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :normal}, 1_000
      :sys.get_state(manager)

      assert {:error, :not_found} = SessionManager.get_session(manager, session_id)
    end

    test "returns error for unknown pid", %{manager: manager} do
      assert {:error, :not_found} = SessionManager.stop_session_by_pid(manager, self())
    end
  end

  describe "session DOWN monitoring" do
    test "does not restart a crashed session until its provider and effect workers exit", %{
      manager: manager
    } do
      Minga.Events.subscribe(:agent_session_restarted)
      session_id = "provider-drain-#{System.unique_integer([:positive])}"

      assert {:ok, ^session_id, session_pid} =
               SessionManager.start_session(manager,
                 session_id: session_id,
                 restart_backoff_base_ms: 1,
                 restart_backoff_max_ms: 1
               )

      provider_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      worker_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :sys.replace_state(manager, fn state ->
        Map.update!(state, :sessions, fn sessions ->
          Map.update!(sessions, session_id, fn entry ->
            %{
              entry
              | provider_pid: provider_pid,
                provider_monitor_ref: Process.monitor(provider_pid)
            }
          end)
        end)
      end)

      assert :ok =
               SessionManager.register_effect_workers(
                 manager,
                 session_pid,
                 provider_pid,
                 [worker_pid]
               )

      session_ref = Process.monitor(session_pid)
      Process.exit(session_pid, :kill)
      assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :killed}, 1_000

      :sys.get_state(manager)

      assert {:error, :restart_pending} =
               SessionManager.start_session(manager, session_id: session_id)

      send(provider_pid, :stop)
      :sys.get_state(manager)

      assert {:error, :restart_pending} =
               SessionManager.start_session(manager, session_id: session_id)

      refute_receive {:minga_event, :agent_session_restarted, _event}, 20

      send(worker_pid, :stop)

      assert_receive {
                       :minga_event,
                       :agent_session_restarted,
                       %SessionRestartedEvent{
                         session_id: ^session_id,
                         old_pid: ^session_pid,
                         new_pid: new_pid,
                         reason: :killed
                       }
                     },
                     3_000

      assert {:ok, ^new_pid} = SessionManager.get_session(manager, session_id)
    end

    test "a late worker registration cancels a queued restart until the generation drains", %{
      manager: manager
    } do
      Minga.Events.subscribe(:agent_session_restarted)
      session_id = "late-worker-#{System.unique_integer([:positive])}"

      assert {:ok, ^session_id, session_pid} =
               SessionManager.start_session(manager,
                 session_id: session_id,
                 provider: RecordingProvider,
                 provider_opts: [],
                 persist?: false,
                 restart_backoff_base_ms: 100,
                 restart_backoff_max_ms: 100
               )

      provider_pid = Session.get_provider(session_pid)
      assert is_pid(provider_pid)

      :sys.replace_state(manager, fn state ->
        Map.update!(state, :sessions, fn sessions ->
          Map.update!(sessions, session_id, fn entry ->
            if is_reference(entry.provider_monitor_ref) do
              Process.demonitor(entry.provider_monitor_ref, [:flush])
            end

            %{entry | provider_pid: nil, provider_monitor_ref: nil}
          end)
        end)
      end)

      worker_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      worker_ref = Process.monitor(worker_pid)
      session_ref = Process.monitor(session_pid)
      Process.exit(session_pid, :kill)
      assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :killed}, 1_000
      :sys.get_state(manager)

      assert :ok =
               SessionManager.register_effect_workers(
                 manager,
                 session_pid,
                 provider_pid,
                 [worker_pid]
               )

      assert is_nil(:sys.get_state(manager).sessions[session_id].restart_state.timer_token)

      assert {:error, :restart_pending} =
               SessionManager.start_session(manager, session_id: session_id)

      refute_receive {:minga_event, :agent_session_restarted, _event}, 20

      send(worker_pid, :stop)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :normal}, 1_000

      assert_receive {
                       :minga_event,
                       :agent_session_restarted,
                       %SessionRestartedEvent{session_id: ^session_id, new_pid: new_pid}
                     },
                     1_000

      assert {:ok, ^new_pid} = SessionManager.get_session(manager, session_id)
    end

    test "stopping a restart-pending session keeps its ID reserved until the provider exits", %{
      manager: manager
    } do
      session_id = "stopped-provider-drain-#{System.unique_integer([:positive])}"

      assert {:ok, ^session_id, session_pid} =
               SessionManager.start_session(manager, session_id: session_id)

      provider_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :sys.replace_state(manager, fn state ->
        Map.update!(state, :sessions, fn sessions ->
          Map.update!(sessions, session_id, fn entry ->
            %{
              entry
              | provider_pid: provider_pid,
                provider_monitor_ref: Process.monitor(provider_pid)
            }
          end)
        end)
      end)

      session_ref = Process.monitor(session_pid)
      Process.exit(session_pid, :kill)
      assert_receive {:DOWN, ^session_ref, :process, ^session_pid, :killed}, 1_000
      :sys.get_state(manager)

      assert :ok = SessionManager.stop_session(manager, session_id)

      assert {:error, :restart_pending} =
               SessionManager.start_session(manager, session_id: session_id)

      provider_ref = Process.monitor(provider_pid)
      send(provider_pid, :stop)
      assert_receive {:DOWN, ^provider_ref, :process, ^provider_pid, :normal}, 1_000
      :sys.get_state(manager)

      assert {:error, :not_found} = SessionManager.get_session(manager, session_id)

      assert {:ok, ^session_id, _new_pid} =
               SessionManager.start_session(manager, session_id: session_id)
    end

    test "a session that dies during metadata lookup is listed under its old registration and restarted only by its matching monitor",
         %{manager: manager} do
      Minga.Events.subscribe(:agent_session_restarted)
      session_id = "metadata-death-#{System.unique_integer([:positive])}"

      assert {:ok, ^session_id, old_pid} =
               SessionManager.start_session(manager,
                 session_id: session_id,
                 provider: Minga.Test.StubProvider,
                 persist?: false,
                 restart_backoff_base_ms: 1,
                 restart_backoff_max_ms: 1
               )

      :ok = :sys.suspend(old_pid)
      listing_task = Task.async(fn -> SessionManager.list_sessions(manager) end)
      await_metadata_call(old_pid)

      old_ref = Process.monitor(old_pid)
      Process.exit(old_pid, :kill)
      assert_receive {:DOWN, ^old_ref, :process, ^old_pid, :killed}, 1_000

      assert %SessionListing{
               id: ^session_id,
               pid: ^old_pid,
               details: {:unavailable, :unreachable}
             } =
               listing_task
               |> Task.await(1_000)
               |> Enum.find(&(&1.id == session_id))

      assert_receive {
                       :minga_event,
                       :agent_session_restarted,
                       %SessionRestartedEvent{
                         session_id: ^session_id,
                         old_pid: ^old_pid,
                         new_pid: new_pid,
                         reason: :killed
                       }
                     },
                     1_000

      assert {:ok, ^new_pid} = SessionManager.get_session(manager, session_id)

      send(manager, {:DOWN, make_ref(), :process, new_pid, :killed})
      :sys.get_state(manager)
      assert {:ok, ^new_pid} = SessionManager.get_session(manager, session_id)
    end

    test "restarts a crashed session, refreshes child handles, and keeps the registry consistent",
         %{manager: manager, session_supervisor: session_supervisor} do
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

      assert Enum.any?(DynamicSupervisor.which_children(session_supervisor), fn
               {:undefined, ^new_pid, :worker, [Session]} -> true
               _ -> false
             end)

      sessions = SessionManager.list_sessions(manager)

      assert Enum.any?(sessions, fn %SessionListing{id: listed_id, pid: listed_pid} ->
               listed_id == session_id and listed_pid == new_pid
             end)

      refute Enum.any?(sessions, fn %SessionListing{id: listed_id, pid: listed_pid} ->
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

    test "delivers the startup prompt and refreshes the background subagent pid on restart",
         %{manager: manager} do
      Minga.Events.subscribe(:agent_session_restarted)

      assert {:ok, %Handle{} = handle} =
               SessionManager.start_background_subagent(manager, nil, "child work",
                 session_opts: [
                   provider: Minga.Test.StubProvider,
                   provider_opts: [],
                   persist?: false
                 ]
               )

      assert :ok = Session.subscribe(handle.pid)

      prompt_recorded? = fn ->
        Enum.any?(Session.messages(handle.pid), &match?({:user, "child work"}, &1))
      end

      unless prompt_recorded?.() do
        assert_receive {:agent_event, session_pid, :messages_changed}, 1_000
        assert session_pid == handle.pid
      end

      assert prompt_recorded?.()

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

    {:ok, session_id, pid} =
      SessionManager.start_session(manager,
        persist?: false,
        idle_gc_timeout_ms: 60_000
      )

    assert :ok = MingaAgent.Session.subscribe(pid)
    assert :ok = MingaAgent.Session.unsubscribe(pid)
    timer_ref = :sys.get_state(pid).subscriber_lifecycle |> SubscriberLifecycle.reclaim_timer()
    send(pid, {:timeout, timer_ref, :idle_gc})

    assert_receive {
                     :minga_event,
                     :agent_session_stopped,
                     %SessionStoppedEvent{session_id: ^session_id, pid: ^pid, reason: :normal}
                   },
                   5_000

    assert {:error, :not_found} = SessionManager.get_session(manager, session_id)

    refute_receive {:minga_event, :agent_session_restarted,
                    %SessionRestartedEvent{session_id: ^session_id}},
                   50
  end

  test "repeated crash restarts eventually exhaust and stop terminally", %{manager: manager} do
    Minga.Events.subscribe(:agent_session_restarted)
    Minga.Events.subscribe(:agent_session_stopped)

    {:ok, session_id, pid} =
      SessionManager.start_session(manager,
        provider: RecordingProvider,
        provider_opts: [],
        persist?: false,
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

    provider_pid = Session.get_provider(second_restart)
    provider_ref = Process.monitor(provider_pid)

    worker_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    worker_ref = Process.monitor(worker_pid)

    assert :ok =
             SessionManager.register_effect_workers(
               manager,
               second_restart,
               provider_pid,
               [worker_pid]
             )

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

    refute_receive {:minga_event, :agent_session_restarted,
                    %SessionRestartedEvent{session_id: ^session_id}},
                   50

    assert {:error, :restart_pending} =
             SessionManager.start_session(manager, session_id: session_id)

    send(worker_pid, :stop)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :normal}, 1_000
    assert_receive {:DOWN, ^provider_ref, :process, ^provider_pid, _reason}, 1_000
    :sys.get_state(manager)

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

    continuation_messages = [
      ReqLLM.Context.user("restored"),
      ReqLLM.Context.assistant("reply")
    ]

    {:ok, continuation} =
      MingaAgent.Session.Continuation.restore(
        continuation_messages,
        1,
        1,
        [],
        %{},
        :lossless
      )

    :ok =
      SessionStore.save(
        %{
          id: session_id,
          timestamp: DateTime.to_iso8601(DateTime.utc_now()),
          model_name: "test-model",
          messages: [{:user, "restored"}, {:assistant, "reply"}],
          continuation: continuation,
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

    assert :sys.get_state(new_pid).continuation.messages == continuation_messages
  end

  test "managed restart follows the durable ID loaded into its Session", %{manager: manager} do
    Minga.Events.subscribe(:agent_session_restarted)

    dir =
      Path.join(
        System.tmp_dir!(),
        "session-manager-identity-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)
    loaded_id = "loaded-identity-#{System.unique_integer([:positive])}"
    messages = [ReqLLM.Context.user("loaded prompt"), ReqLLM.Context.assistant("loaded reply")]

    {:ok, continuation} =
      MingaAgent.Session.Continuation.restore(messages, 1, 1, [], %{}, :lossless)

    assert :ok =
             SessionStore.save(
               %{
                 id: loaded_id,
                 timestamp: DateTime.to_iso8601(DateTime.utc_now()),
                 model_name: "test-model",
                 messages: [{:user, "loaded prompt"}, {:assistant, "loaded reply"}],
                 continuation: continuation,
                 usage: MingaAgent.TurnUsage.new()
               },
               dir
             )

    assert {:ok, "canonical-target-token"} =
             SessionStore.establish_remote_token(loaded_id, "canonical-target-token", dir)

    scratch_id = "scratch-identity-#{System.unique_integer([:positive])}"

    assert {:ok, ^scratch_id, old_pid} =
             SessionManager.start_session(manager,
               session_id: scratch_id,
               provider: RecordingProvider,
               provider_opts: [],
               persist?: true,
               session_store_dir: dir
             )

    assert :ok = Session.load_session(old_pid, loaded_id)
    assert {:ok, "canonical-target-token"} = SessionManager.session_token(manager, loaded_id)
    assert {:error, :not_found} = SessionManager.session_token(manager, scratch_id)
    :sys.get_state(manager)
    assert {:ok, ^old_pid} = SessionManager.get_session(manager, loaded_id)
    assert {:error, :not_found} = SessionManager.get_session(manager, scratch_id)

    new_pid = crash_and_wait_for_restart(manager, loaded_id, old_pid)

    assert_receive {
                     :minga_event,
                     :agent_session_restarted,
                     %SessionRestartedEvent{
                       session_id: ^loaded_id,
                       old_pid: ^old_pid,
                       new_pid: ^new_pid
                     }
                   },
                   1_000

    assert :sys.get_state(new_pid).continuation.messages == messages
  end

  test "starting a new session commits the manager identity and canonical token", %{
    manager: manager
  } do
    dir =
      Path.join(
        System.tmp_dir!(),
        "session-manager-new-identity-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)
    old_id = "old-identity-#{System.unique_integer([:positive])}"

    assert {:ok, ^old_id, pid} =
             SessionManager.start_session(manager,
               session_id: old_id,
               provider: RecordingProvider,
               provider_opts: [],
               persist?: true,
               session_store_dir: dir
             )

    assert {:ok, old_token} = SessionManager.session_token(manager, old_id)
    assert :ok = Session.new_session(pid)
    new_id = Session.session_id(pid)

    assert new_id != old_id
    assert {:error, :session_id_changed} = Session.send_prompt_for_id(pid, old_id, "stale prompt")
    assert :ok = Session.add_system_message_for_id(pid, old_id, "stale failure", :error)
    :sys.get_state(pid)
    refute Enum.any?(Session.messages(pid), &match?({:system, "stale failure", :error}, &1))
    assert {:ok, ^pid} = SessionManager.get_session(manager, new_id)
    assert {:error, :not_found} = SessionManager.get_session(manager, old_id)
    assert {:error, :not_found} = SessionManager.session_token(manager, old_id)
    assert {:ok, new_token} = SessionManager.session_token(manager, new_id)
    refute new_token == old_token

    assert {:ok, ^new_token} =
             SessionStore.establish_remote_token(new_id, "replacement-token", dir)
  end

  test "retryable startup prompt refusal retries without a failure message", %{manager: manager} do
    session_id = "startup-retry-#{System.unique_integer([:positive])}"

    assert {:ok, ^session_id, pid} =
             SessionManager.start_session(manager,
               session_id: session_id,
               provider: Minga.Test.StubProvider,
               provider_opts: [],
               persist?: false
             )

    assert :ok = Session.subscribe(pid)
    entry = :sys.get_state(manager).sessions[session_id]
    task_ref = make_ref()
    delivery_ref = make_ref()

    :sys.replace_state(manager, fn state ->
      Map.update!(state, :sessions, fn sessions ->
        Map.update!(sessions, session_id, fn entry ->
          delivery = %{
            reference: delivery_ref,
            prompt: "retry this startup prompt",
            attempt: 0,
            phase: {:in_flight, session_id, entry.monitor_ref, task_ref, self()}
          }

          %{entry | startup_delivery: delivery}
        end)
      end)
    end)

    send(
      manager,
      {task_ref,
       {:startup_prompt_result, delivery_ref, session_id, entry.monitor_ref,
        {:error, :provider_not_ready}}}
    )

    assert_receive {:agent_event, ^pid, :messages_changed}, 1_000
    assert Enum.any?(Session.messages(pid), &match?({:user, "retry this startup prompt"}, &1))

    refute Enum.any?(Session.messages(pid), fn
             {:system, text, :error} -> text =~ "Background sub-agent failed to start"
             _ -> false
           end)
  end

  test "terminal startup failure cannot write into a session after it changes identity", %{
    manager: manager
  } do
    old_id = "startup-failure-#{System.unique_integer([:positive])}"

    assert {:ok, ^old_id, pid} =
             SessionManager.start_session(manager,
               session_id: old_id,
               provider: RecordingProvider,
               provider_opts: [],
               persist?: false
             )

    manager_state = :sys.get_state(manager)
    entry = manager_state.sessions[old_id]
    task_ref = make_ref()
    delivery_ref = make_ref()

    :sys.replace_state(manager, fn state ->
      Map.update!(state, :sessions, fn sessions ->
        Map.update!(sessions, old_id, fn entry ->
          delivery = %{
            reference: delivery_ref,
            prompt: "startup prompt",
            attempt: 0,
            phase: {:in_flight, old_id, entry.monitor_ref, task_ref, self()}
          }

          %{entry | startup_delivery: delivery}
        end)
      end)
    end)

    assert :ok = Session.new_session(pid)
    new_id = Session.session_id(pid)
    assert new_id != old_id
    assert {:ok, ^pid} = SessionManager.get_session(manager, new_id)

    send(
      manager,
      {task_ref,
       {:startup_prompt_result, delivery_ref, old_id, entry.monitor_ref,
        {:error, :provider_failed}}}
    )

    :sys.get_state(manager)
    :sys.get_state(pid)

    refute Enum.any?(Session.messages(pid), fn
             {:system, text, :error} -> text =~ "Background sub-agent failed to start"
             _ -> false
           end)
  end

  test "loading a session rejects an ID already owned by another live session", %{
    manager: manager
  } do
    dir =
      Path.join(
        System.tmp_dir!(),
        "session-manager-identity-collision-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)
    target_id = "identity-target-#{System.unique_integer([:positive])}"
    source_id = "identity-source-#{System.unique_integer([:positive])}"

    {:ok, continuation} =
      MingaAgent.Session.Continuation.restore(
        [ReqLLM.Context.user("target transcript")],
        1,
        1,
        [],
        %{},
        :lossless
      )

    assert :ok =
             SessionStore.save(
               %{
                 id: target_id,
                 timestamp: DateTime.to_iso8601(DateTime.utc_now()),
                 model_name: "test-model",
                 messages: [{:user, "target transcript"}],
                 continuation: continuation,
                 usage: MingaAgent.TurnUsage.new()
               },
               dir
             )

    assert {:ok, ^target_id, target_pid} =
             SessionManager.start_session(manager,
               session_id: target_id,
               provider: RecordingProvider,
               provider_opts: [],
               persist?: true,
               session_store_dir: dir
             )

    assert {:ok, source_id, source_pid} =
             SessionManager.start_session(manager,
               session_id: source_id,
               provider: RecordingProvider,
               provider_opts: [],
               persist?: true,
               session_store_dir: dir
             )

    assert {:error, :session_id_in_use} = Session.load_session(source_pid, target_id)
    assert {:ok, ^source_pid} = SessionManager.get_session(manager, source_id)
    assert {:ok, ^target_pid} = SessionManager.get_session(manager, target_id)
    assert :sys.get_state(source_pid).session_id == source_id
    assert :sys.get_state(target_pid).session_id == target_id
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

  @spec write_legacy_session(String.t(), String.t(), String.t()) :: :ok
  defp write_legacy_session(session_id, token, dir) do
    data = %{
      id: session_id,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      model_name: "test",
      messages: [],
      usage: MingaAgent.TurnUsage.new(),
      continuation: MingaAgent.Session.Continuation.new()
    }

    :ok = SessionStore.save(data, dir)
    path = session_path(session_id, dir)
    payload = path |> File.read!() |> JSON.decode!() |> Map.put("remote_token", token)
    File.write!(path, JSON.encode!(payload))
  end

  @spec session_path(String.t(), String.t()) :: String.t()
  defp session_path(session_id, dir) do
    Path.join(SessionStore.sessions_dir(dir), "#{session_id}.json")
  end

  @spec remote_token_path(String.t(), String.t()) :: String.t()
  defp remote_token_path(session_id, dir) do
    Path.join([SessionStore.sessions_dir(dir), ".remote_tokens", "#{session_id}.json"])
  end

  @spec crash_and_wait_for_restart(GenServer.server(), String.t(), pid()) :: pid()
  defp crash_and_wait_for_restart(manager, session_id, pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000
    wait_until_restarted_session(manager, session_id, pid)
  end

  @spec await_metadata_call(pid(), non_neg_integer()) :: :ok
  defp await_metadata_call(pid, attempts \\ 100)

  defp await_metadata_call(pid, 0) do
    flunk("metadata call was not queued for suspended session #{inspect(pid)}")
  end

  defp await_metadata_call(pid, attempts) do
    {:messages, messages} = Process.info(pid, :messages)

    if Enum.any?(messages, &match?({:"$gen_call", _from, :metadata}, &1)) do
      :ok
    else
      receive do
      after
        10 -> await_metadata_call(pid, attempts - 1)
      end
    end
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
