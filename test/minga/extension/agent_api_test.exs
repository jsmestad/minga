defmodule Minga.Extension.AgentAPITest do
  # SessionManager starts sessions under the process-global MingaAgent.Supervisor.
  use ExUnit.Case, async: false

  alias Minga.Extension.AgentAPI
  alias MingaAgent.EventLog
  alias MingaAgent.SessionManager

  @moduletag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    manager = :"agent_api_mgr_#{System.unique_integer([:positive])}"
    event_log = :"agent_api_log_#{System.unique_integer([:positive])}"
    _manager = start_supervised!({SessionManager, name: manager}, id: manager)

    start_supervised!(
      {EventLog, name: event_log, db_dir: tmp_dir, retention_sweep?: false, health_check: :none},
      id: event_log
    )

    assert {:queued, receipt} =
             EventLog.record("agent-api-setup", :status_changed, %{status: :idle}, event_log)

    assert {:persisted, _event_id} = EventLog.await(receipt)

    %{opts: [session_manager: manager, event_log: event_log], manager: manager}
  end

  describe "list_sessions/1" do
    test "returns [] when no sessions exist", %{opts: opts} do
      assert AgentAPI.list_sessions(opts) == []
    end

    test "returns [] when the manager is not registered" do
      assert AgentAPI.list_sessions(session_manager: :nonexistent_manager) == []
    end

    test "returns summaries with the documented keys", %{opts: opts, manager: manager} do
      {:ok, _id, _pid} =
        SessionManager.start_session(manager, provider: Minga.Test.StubProvider)

      summaries = AgentAPI.list_sessions(opts)
      assert Enum.count(summaries) == 1

      expected_keys = MapSet.new([:id, :pid, :status, :label, :model, :active_tool, :created_at])

      for summary <- summaries do
        assert MapSet.new(Map.keys(summary)) == expected_keys
      end
    end

    test "summary fields have correct types", %{opts: opts, manager: manager} do
      {:ok, _id, session_pid} =
        SessionManager.start_session(manager, provider: Minga.Test.StubProvider)

      [summary] = AgentAPI.list_sessions(opts)

      assert summary.pid == session_pid
      assert is_binary(summary.id)
      assert summary.status in [:idle, :plan, :thinking, :tool_executing, :error]
      assert is_binary(summary.label)
      assert is_binary(summary.model)
      assert is_nil(summary.active_tool) or is_binary(summary.active_tool)
      assert %DateTime{} = summary.created_at
    end
  end

  describe "session_info/2" do
    test "returns {:error, :not_found} for a dead PID", %{opts: opts} do
      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}
      assert {:error, :not_found} = AgentAPI.session_info(dead_pid, opts)
    end

    test "returns {:error, :not_found} for a PID that is not an agent session", %{opts: opts} do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      assert {:error, :not_found} = AgentAPI.session_info(pid, opts)
    end

    test "returns {:ok, info} with all detailed keys for a live session", %{
      opts: opts,
      manager: manager
    } do
      {:ok, _id, session_pid} =
        SessionManager.start_session(manager, provider: Minga.Test.StubProvider)

      assert {:ok, info} = AgentAPI.session_info(session_pid, opts)

      expected_keys =
        MapSet.new([
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
          :turn_count,
          :files_touched
        ])

      assert MapSet.new(Map.keys(info)) == expected_keys
      assert info.pid == session_pid
      assert is_binary(info.id)
      assert is_float(info.cost)
      assert is_integer(info.input_tokens) and info.input_tokens >= 0
      assert is_integer(info.output_tokens) and info.output_tokens >= 0
      assert is_integer(info.turn_count) and info.turn_count >= 0
      assert is_list(info.files_touched)
    end

    test "reads touched files from the EventLog projection in durable order", %{
      manager: manager,
      opts: opts,
      tmp_dir: tmp_dir
    } do
      event_log = Keyword.fetch!(opts, :event_log)
      session_id = "agent-api-touched-files-#{System.unique_integer([:positive])}"

      {:ok, ^session_id, session} =
        SessionManager.start_session(manager,
          session_id: session_id,
          provider: Minga.Test.StubProvider,
          session_store_dir: tmp_dir
        )

      assert {:queued, first_receipt} =
               EventLog.record(
                 session_id,
                 :file_edit_proposed,
                 %{
                   path: "lib/first.ex",
                   before_content: "",
                   after_content: "created"
                 },
                 event_log
               )

      assert {:persisted, _first_id} = EventLog.await(first_receipt)

      assert {:queued, second_receipt} =
               EventLog.record(
                 session_id,
                 :file_edit_proposed,
                 %{
                   path: "lib/second.ex",
                   before_content: "before",
                   after_content: "after"
                 },
                 event_log
               )

      assert {:persisted, _second_id} = EventLog.await(second_receipt)
      assert {:ok, info} = AgentAPI.session_info(session, opts)
      assert info.files_touched == ["lib/second.ex", "lib/first.ex"]
    end

    test "reports unavailable when the EventLog projection cannot be queried", %{
      manager: manager
    } do
      {:ok, _id, session} =
        SessionManager.start_session(manager, provider: Minga.Test.StubProvider)

      assert {:error, :unavailable} =
               AgentAPI.session_info(session,
                 event_log: :missing_event_log,
                 session_manager: manager
               )
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
