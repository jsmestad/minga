defmodule MingaAgent.SessionManagerTest do
  use ExUnit.Case, async: true

  alias MingaAgent.SessionManager
  alias MingaAgent.SessionManager.SessionStoppedEvent

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
    test "removes session from registry when it dies", %{manager: manager} do
      {:ok, session_id, pid} = SessionManager.start_session(manager, [])

      Process.exit(pid, :kill)

      :timer.sleep(50)

      assert {:error, :not_found} = SessionManager.get_session(manager, session_id)
      assert [] = SessionManager.list_sessions(manager)
    end

    test "broadcasts :agent_session_stopped event when session dies", %{manager: manager} do
      Minga.Events.subscribe(:agent_session_stopped)

      {:ok, session_id, pid} = SessionManager.start_session(manager, [])

      Process.exit(pid, :kill)

      assert_receive {:minga_event, :agent_session_stopped,
                      %SessionStoppedEvent{
                        session_id: ^session_id,
                        pid: ^pid,
                        reason: :killed
                      }},
                     1000
    end
  end
end
