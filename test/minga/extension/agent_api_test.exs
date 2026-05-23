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
      registry =
        start_supervised!(
          {Registry,
           keys: :duplicate, name: :"agent_api_test_#{System.unique_integer([:positive])}"}
        )

      assert :ok = Minga.Events.subscribe(:agent_session_stopped, registry: registry)
      assert :ok = Minga.Events.subscribe(:agent_hook, registry: registry)
    end
  end

  describe "subscribe_edits/0" do
    test "subscribes to buffer_changed events without error" do
      registry =
        start_supervised!(
          {Registry,
           keys: :duplicate, name: :"agent_api_edit_test_#{System.unique_integer([:positive])}"}
        )

      assert :ok = Minga.Events.subscribe(:buffer_changed, registry: registry)
    end
  end

  describe "type contracts" do
    test "session_summary type has expected keys" do
      keys = [:id, :pid, :status, :label, :model, :active_tool, :created_at]

      summary = %{
        id: "1",
        pid: self(),
        status: :idle,
        label: "test",
        model: "claude-4",
        active_tool: nil,
        created_at: DateTime.utc_now()
      }

      for key <- keys do
        assert Map.has_key?(summary, key), "session_summary missing key: #{key}"
      end
    end

    test "session_info type has expected keys" do
      keys = [
        :id,
        :pid,
        :status,
        :label,
        :model,
        :active_tool,
        :created_at,
        :cost,
        :input_tokens,
        :output_tokens,
        :turn_count
      ]

      info = %{
        id: "1",
        pid: self(),
        status: :thinking,
        label: "test session",
        model: "claude-4",
        active_tool: "edit_file",
        created_at: DateTime.utc_now(),
        cost: 0.042,
        input_tokens: 1200,
        output_tokens: 450,
        turn_count: 3
      }

      for key <- keys do
        assert Map.has_key?(info, key), "session_info missing key: #{key}"
      end
    end
  end
end
