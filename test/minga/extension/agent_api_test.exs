defmodule Minga.Extension.AgentAPITest do
  # async: false — uses application-level EventBus registry for subscribe tests
  use ExUnit.Case, async: false

  alias Minga.Extension.AgentAPI

  describe "list_sessions/0" do
    test "returns empty list when session manager is not running" do
      assert AgentAPI.list_sessions() == []
    end

    test "returns maps with the documented summary keys" do
      summaries = AgentAPI.list_sessions()

      expected_keys =
        MapSet.new([:id, :pid, :status, :label, :model, :active_tool, :created_at])

      for summary <- summaries do
        assert MapSet.new(Map.keys(summary)) == expected_keys
      end
    end
  end

  describe "session_info/1" do
    test "returns {:error, :not_found} for a dead PID" do
      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}
      assert {:error, :not_found} = AgentAPI.session_info(dead_pid)
    end

    test "returns {:error, :not_found} for a PID that is not an agent session" do
      pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn -> Process.exit(pid, :kill) end)

      assert {:error, :not_found} = AgentAPI.session_info(pid)
    end
  end

  describe "subscribe/0" do
    test "registers calling process for agent_hook and agent_session_stopped" do
      assert :ok = AgentAPI.subscribe()
      assert self() in Minga.Events.subscribers(:agent_hook)
      assert self() in Minga.Events.subscribers(:agent_session_stopped)
    end
  end

  describe "subscribe_edits/0" do
    test "registers calling process for buffer_changed" do
      assert :ok = AgentAPI.subscribe_edits()
      assert self() in Minga.Events.subscribers(:buffer_changed)
    end
  end
end
