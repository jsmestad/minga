defmodule Minga.Extension.AgentAPITest do
  use ExUnit.Case, async: true

  alias Minga.Extension.AgentAPI

  describe "list_sessions/0" do
    test "returns empty list when session manager is not running" do
      assert AgentAPI.list_sessions() == []
    end
  end

  describe "session_info/1" do
    test "returns {:error, :not_found} for a dead PID" do
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      assert {:error, :not_found} = AgentAPI.session_info(dead_pid)
    end

    test "returns {:error, :not_found} for a PID that is not an agent session" do
      pid = spawn(fn -> Process.sleep(:infinity) end)

      try do
        assert {:error, :not_found} = AgentAPI.session_info(pid)
      after
        Process.exit(pid, :kill)
      end
    end
  end

  describe "subscribe/0" do
    test "subscribes to agent lifecycle events without error" do
      assert :ok = AgentAPI.subscribe()
    end
  end

  describe "subscribe_edits/0" do
    test "subscribes to buffer_changed events without error" do
      assert :ok = AgentAPI.subscribe_edits()
    end
  end
end
