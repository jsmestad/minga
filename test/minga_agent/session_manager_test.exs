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

  describe "start_session/1" do
    test "starts a session and returns a human-readable ID", %{manager: manager} do
      assert {:ok, session_id, pid} = GenServer.call(manager, {:start_session, []})
      assert session_id == "session-1"
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "increments session IDs", %{manager: manager} do
      {:ok, "session-1", _pid1} = GenServer.call(manager, {:start_session, []})
      {:ok, "session-2", _pid2} = GenServer.call(manager, {:start_session, []})
      {:ok, "session-3", _pid3} = GenServer.call(manager, {:start_session, []})
    end
  end

  describe "stop_session/1" do
    test "stops an existing session", %{manager: manager} do
      {:ok, session_id, pid} = GenServer.call(manager, {:start_session, []})
      assert Process.alive?(pid)

      assert :ok = GenServer.call(manager, {:stop_session, session_id})
      refute Process.alive?(pid)
    end

    test "returns error for unknown session ID", %{manager: manager} do
      assert {:error, :not_found} = GenServer.call(manager, {:stop_session, "nonexistent"})
    end
  end

  describe "get_session/1" do
    test "returns pid for known session", %{manager: manager} do
      {:ok, session_id, pid} = GenServer.call(manager, {:start_session, []})
      assert {:ok, ^pid} = GenServer.call(manager, {:get_session, session_id})
    end

    test "returns error for unknown session", %{manager: manager} do
      assert {:error, :not_found} = GenServer.call(manager, {:get_session, "nope"})
    end
  end

  describe "session_id_for_pid/1" do
    test "returns session ID for known pid", %{manager: manager} do
      {:ok, session_id, pid} = GenServer.call(manager, {:start_session, []})
      assert {:ok, ^session_id} = GenServer.call(manager, {:session_id_for_pid, pid})
    end

    test "returns error for unknown pid", %{manager: manager} do
      assert {:error, :not_found} = GenServer.call(manager, {:session_id_for_pid, self()})
    end
  end

  describe "list_sessions/0" do
    test "returns empty list when no sessions", %{manager: manager} do
      assert [] = GenServer.call(manager, :list_sessions)
    end

    test "returns all active sessions", %{manager: manager} do
      {:ok, id1, pid1} = GenServer.call(manager, {:start_session, []})
      {:ok, id2, pid2} = GenServer.call(manager, {:start_session, []})

      sessions = GenServer.call(manager, :list_sessions)
      assert length(sessions) == 2

      ids = Enum.map(sessions, &elem(&1, 0))
      pids = Enum.map(sessions, &elem(&1, 1))

      assert id1 in ids
      assert id2 in ids
      assert pid1 in pids
      assert pid2 in pids
    end
  end

  describe "abort/1" do
    test "returns error for unknown session", %{manager: manager} do
      assert {:error, :not_found} = GenServer.call(manager, {:abort, "unknown"})
    end
  end

  describe "session DOWN monitoring" do
    test "removes session from registry when it dies", %{manager: manager} do
      {:ok, session_id, pid} = GenServer.call(manager, {:start_session, []})

      # Kill the session process
      Process.exit(pid, :kill)

      # Give the manager time to process the DOWN message
      :timer.sleep(50)

      assert {:error, :not_found} = GenServer.call(manager, {:get_session, session_id})
      assert [] = GenServer.call(manager, :list_sessions)
    end

    test "broadcasts :agent_session_stopped event when session dies", %{manager: manager} do
      Minga.Events.subscribe(:agent_session_stopped)

      {:ok, session_id, pid} = GenServer.call(manager, {:start_session, []})

      # Kill the session
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
