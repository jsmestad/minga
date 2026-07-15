defmodule MingaAgent.EventLogTest do
  use ExUnit.Case, async: true

  alias MingaAgent.EventLog
  alias MingaAgent.EventLog.ControllableStore
  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.Store

  @moduletag :tmp_dir
  @event_timeout 2_000

  test "record acknowledges queue admission before committed persistence and redacts secrets", %{
    tmp_dir: tmp_dir
  } do
    name = unique_name("event-log")
    start_event_log(name, db_dir: tmp_dir)

    assert {:queued, receipt} =
             EventLog.record(
               "session-1",
               :tool_call_started,
               %{
                 :api_key => "secret",
                 :accessToken => "camel",
                 "client-secret" => "hyphen",
                 :nested => %{refreshToken: "abc"},
                 :pid => self()
               },
               name
             )

    assert_receive {:event_log_commit, ^receipt, :tool_call_started, {:persisted, event_id}},
                   @event_timeout

    assert is_integer(event_id)

    {:ok, db} = EventLog.open_read_connection(db_dir: tmp_dir)
    assert {:ok, [record]} = EventLog.events_after(db, "session-1", 0, 10)
    assert record.id == event_id
    assert record.payload["api_key"] == "[REDACTED]"
    assert record.payload["accessToken"] == "[REDACTED]"
    assert record.payload["client-secret"] == "[REDACTED]"
    assert record.payload["nested"]["refreshToken"] == "[REDACTED]"
    assert record.payload["pid"] == "[PID]"
    :ok = Store.close(db)
  end

  test "stalled writer preserves bounded ordered admission and best-effort semantics" do
    name = unique_name("bounded-log")
    start_controlled_event_log(name, max_queue_size: 2)
    writer = open_controlled_writer()

    assert {:queued, first_receipt} =
             EventLog.record("session", :tool_call_started, %{sequence: 1}, name)

    assert_receive {:event_log_store_insert, ^writer, first_record}
    assert first_record.payload["sequence"] == 1

    assert :queued =
             EventLog.record_best_effort("session", :assistant_delta, %{sequence: 2}, name)

    assert {:error, :overloaded} =
             EventLog.record("session", :tool_call_finished, %{sequence: 3}, name)

    assert EventLog.writer_pid(name) == writer

    send(writer, {:event_log_store_insert_result, {:ok, 11}})

    assert_receive {:event_log_commit, ^first_receipt, :tool_call_started, {:persisted, 11}}
    assert_receive {:event_log_store_insert, ^writer, second_record}
    assert second_record.event_type == :assistant_delta
    assert second_record.payload["sequence"] == 2

    send(writer, {:event_log_store_insert_result, {:ok, 12}})
    assert :ok = EventLog.await_idle(name)
    refute_receive {:event_log_commit, _receipt, :assistant_delta, _result}

    assert {:queued, final_receipt} =
             EventLog.record("session", :tool_call_finished, %{sequence: 4}, name)

    assert_receive {:event_log_store_insert, ^writer, final_record}
    assert final_record.payload["sequence"] == 4
    send(writer, {:event_log_store_insert_result, {:ok, 13}})
    assert {:persisted, 13} = EventLog.await(final_receipt)
  end

  test "oversized and invalid payloads are rejected before reaching the writer" do
    name = unique_name("payload-limits-log")
    start_controlled_event_log(name)
    writer = open_controlled_writer()

    assert {:error, :payload_too_large} =
             EventLog.record(
               "session",
               :system_message,
               %{message: String.duplicate("x", 300_000)},
               name
             )

    assert {:error, :invalid_payload} =
             EventLog.record("session", :system_message, %{message: <<255>>}, name)

    assert {:error, :invalid_payload} =
             EventLog.record("session", :system_message, %{callback: fn -> :ok end}, name)

    refute_receive {:event_log_store_insert, ^writer, _record}
  end

  test "outstanding byte accounting includes best-effort work and releases terminal events" do
    name = unique_name("byte-bounds-log")
    start_controlled_event_log(name, max_queue_bytes: 48)
    writer = open_controlled_writer()

    assert :queued =
             EventLog.record_best_effort(
               "session",
               :assistant_delta,
               %{delta: "1234567890"},
               name
             )

    assert_receive {:event_log_store_insert, ^writer, _record}

    assert {:error, :overloaded} =
             EventLog.record("session", :system_message, %{message: "1234567890"}, name)

    send(writer, {:event_log_store_insert_result, {:ok, 1}})
    assert :ok = EventLog.await_idle(name)

    assert {:queued, failed_receipt} =
             EventLog.record("session", :system_message, %{message: "1234567890"}, name)

    assert_receive {:event_log_store_insert, ^writer, _record}
    send(writer, {:event_log_store_insert_result, {:error, :disk_full}})

    assert {:error, {:persistence_failed, :disk_full}} = EventLog.await(failed_receipt)

    assert {:queued, final_receipt} =
             EventLog.record("session", :system_message, %{message: "1234567890"}, name)

    assert_receive {:event_log_store_insert, ^writer, _record}
    send(writer, {:event_log_store_insert_result, {:ok, 2}})
    assert {:persisted, 2} = EventLog.await(final_receipt)
  end

  test "serialization failure is terminal and later FIFO work still persists", %{tmp_dir: tmp_dir} do
    name = unique_name("poison-log")
    start_event_log(name, db_dir: tmp_dir)

    poison = EventRecord.new("session", :system_message, %{"callback" => fn -> :ok end})

    assert {:queued, poison_receipt} =
             GenServer.call(
               name,
               {:admit, :critical, poison, :erlang.external_size(poison.payload)},
               :infinity
             )

    assert {:queued, valid_receipt} =
             EventLog.record("session", :system_message, %{message: "valid"}, name)

    assert {:error, {:persistence_failed, {:serialization_failed, _exception}}} =
             EventLog.await(poison_receipt)

    assert {:persisted, _id} = EventLog.await(valid_receipt)

    {:ok, db} = EventLog.open_read_connection(db_dir: tmp_dir)

    assert {:ok, [%{payload: %{"message" => "valid"}}]} =
             EventLog.events_after(db, "session", 0, 10)

    :ok = Store.close(db)
  end

  test "insert failure produces an explicit post-store persistence failure" do
    name = unique_name("failure-log")
    start_controlled_event_log(name)
    writer = open_controlled_writer()

    assert {:queued, receipt} =
             EventLog.record("session", :approval_requested, %{approval_id: "a-1"}, name)

    assert_receive {:event_log_store_insert, ^writer, _record}
    send(writer, {:event_log_store_insert_result, {:error, :disk_full}})

    assert_receive {:event_log_commit, ^receipt, :approval_requested,
                    {:error, {:persistence_failed, :disk_full}}}
  end

  test "writer death retries the uncertain event idempotently before later queued work" do
    name = unique_name("writer-death-log")
    start_controlled_event_log(name)
    first_writer = open_controlled_writer()

    assert {:queued, first_receipt} =
             EventLog.record("session", :tool_call_started, %{sequence: 1}, name)

    assert_receive {:event_log_store_insert, ^first_writer, first_record}

    assert {:queued, second_receipt} =
             EventLog.record("session", :tool_call_finished, %{sequence: 2}, name)

    send(first_writer, {:event_log_store_insert_result, {:committed, 21}})
    assert_receive {:event_log_store_committed, ^first_writer, committed_record, 21}
    assert committed_record.event_key == first_record.event_key
    Process.exit(first_writer, :kill)

    second_writer = open_controlled_writer()
    assert second_writer != first_writer
    assert_receive {:event_log_store_insert, ^second_writer, retried_record}
    assert first_record.event_key == retried_record.event_key
    assert retried_record.payload["sequence"] == 1

    send(second_writer, {:event_log_store_insert_result, {:ok, 21}})
    assert {:persisted, 21} = EventLog.await(first_receipt)

    assert_receive {:event_log_store_insert, ^second_writer, second_record}
    assert second_record.payload["sequence"] == 2
    send(second_writer, {:event_log_store_insert_result, {:ok, 22}})
    assert {:persisted, 22} = EventLog.await(second_receipt)
  end

  test "writer death before commit retries the same key without reordering later work" do
    name = unique_name("pre-commit-death-log")
    start_controlled_event_log(name)
    first_writer = open_controlled_writer()

    assert {:queued, first_receipt} =
             EventLog.record("session", :tool_call_started, %{sequence: 1}, name)

    assert_receive {:event_log_store_insert, ^first_writer, first_record}

    assert {:queued, second_receipt} =
             EventLog.record("session", :tool_call_finished, %{sequence: 2}, name)

    Process.exit(first_writer, :kill)
    second_writer = open_controlled_writer()

    assert_receive {:event_log_store_insert, ^second_writer, retried_record}
    assert retried_record.event_key == first_record.event_key
    assert retried_record.payload["sequence"] == 1
    send(second_writer, {:event_log_store_insert_result, {:ok, 31}})
    assert {:persisted, 31} = EventLog.await(first_receipt)

    assert_receive {:event_log_store_insert, ^second_writer, second_record}
    assert second_record.payload["sequence"] == 2
    send(second_writer, {:event_log_store_insert_result, {:ok, 32}})
    assert {:persisted, 32} = EventLog.await(second_receipt)
  end

  test "writer open failure fails queued receipts and stays unavailable until restart" do
    name = unique_name("open-failure-log")
    start_controlled_event_log(name, writer_restart_delay_ms: 60_000)

    assert_receive {:event_log_store_open, first_writer, _path}, @event_timeout

    assert {:queued, receipt} =
             EventLog.record("session", :session_started, %{sequence: 1}, name)

    send(first_writer, {:event_log_store_open_result, {:error, :permission_denied}})

    assert_receive {:event_log_commit, ^receipt, :session_started,
                    {:error, {:persistence_failed, {:writer_start_failed, :permission_denied}}}},
                   @event_timeout

    assert {:error, :unavailable} =
             EventLog.record("session", :session_started, %{sequence: 2}, name)

    assert :ok = EventLog.restart_writer(name)
    second_writer = open_controlled_writer()

    assert {:queued, recovered_receipt} =
             EventLog.record("session", :session_started, %{sequence: 3}, name)

    assert_receive {:event_log_store_insert, ^second_writer, recovered_record}
    assert recovered_record.payload["sequence"] == 3
    send(second_writer, {:event_log_store_insert_result, {:ok, 31}})
    assert {:persisted, 31} = EventLog.await(recovered_receipt)
  end

  test "retention survives writer death followed by replacement open failure" do
    name = unique_name("retention-recovery-log")
    log = start_controlled_event_log(name, writer_restart_delay_ms: 60_000)
    first_writer = open_controlled_writer()

    send(log, :retention_sweep)
    assert_receive {:event_log_store_delete_before, ^first_writer, _cutoff}
    Process.exit(first_writer, :kill)

    assert_receive {:event_log_store_open, second_writer, _path}, @event_timeout
    second_ref = Process.monitor(second_writer)
    send(second_writer, {:event_log_store_open_result, {:error, :permission_denied}})
    assert_receive {:DOWN, ^second_ref, :process, ^second_writer, _reason}
    assert %{status: :unavailable, pending_retention: true} = :sys.get_state(log)

    assert :ok = EventLog.restart_writer(name)
    third_writer = open_controlled_writer()

    assert_receive {:event_log_store_delete_before, ^third_writer, _cutoff}
    send(third_writer, {:event_log_store_delete_before_result, {:ok, 0}})
    assert :ok = EventLog.await_idle(name)
  end

  test "acknowledged critical boundaries remain ordered and unique after a full log restart", %{
    tmp_dir: tmp_dir
  } do
    first_name = unique_name("durable-log")
    first_id = unique_name("durable-child")
    start_event_log(first_name, [db_dir: tmp_dir], first_id)

    first_boundaries = [
      {:tool_call_started, %{tool_call_id: "tool-1", sequence: 1}},
      {:tool_call_finished, %{tool_call_id: "tool-1", sequence: 2}},
      {:approval_requested, %{approval_id: "approval-1", sequence: 3}}
    ]

    first_event_ids =
      Enum.map(first_boundaries, fn {event_type, payload} ->
        record_and_await(first_name, event_type, payload)
      end)

    first_writer = EventLog.writer_pid(first_name)
    first_writer_ref = Process.monitor(first_writer)
    stop_supervised(first_id)
    assert_receive {:DOWN, ^first_writer_ref, :process, ^first_writer, _reason}, @event_timeout

    second_name = unique_name("durable-log")
    start_event_log(second_name, db_dir: tmp_dir)

    second_boundaries = [
      {:approval_resolved, %{approval_id: "approval-1", sequence: 4}},
      {:file_edit_proposed, %{path: "lib/example.ex", sequence: 5}},
      {:waiting_for_input, %{status: :idle, sequence: 6}}
    ]

    second_event_ids =
      Enum.map(second_boundaries, fn {event_type, payload} ->
        record_and_await(second_name, event_type, payload)
      end)

    event_ids = first_event_ids ++ second_event_ids
    assert event_ids == Enum.sort(event_ids)

    {:ok, db} = EventLog.open_read_connection(db_dir: tmp_dir)
    assert {:ok, events} = EventLog.events_after(db, "durable-session", 0, 10)
    assert Enum.map(events, & &1.id) == event_ids

    assert Enum.map(events, & &1.event_type) ==
             Enum.map(first_boundaries ++ second_boundaries, &elem(&1, 0))

    assert Enum.map(events, & &1.payload["sequence"]) == Enum.to_list(1..6)
    assert events |> Enum.map(& &1.id) |> Enum.uniq() == event_ids
    :ok = Store.close(db)
  end

  test "blocked writer dies when its EventLog owner is killed" do
    name = unique_name("killed-owner-log")
    log = start_controlled_event_log(name)
    writer = open_controlled_writer()

    assert {:queued, _receipt} =
             EventLog.record("session", :session_started, %{sequence: 1}, name)

    assert_receive {:event_log_store_insert, ^writer, _record}
    writer_ref = Process.monitor(writer)
    Process.exit(log, :kill)

    assert_receive {:DOWN, ^writer_ref, :process, ^writer, :killed}
  end

  test "writer terminates when its EventLog owner is stopped" do
    name = unique_name("owner-log")
    child_id = unique_name("owner-child")
    log = start_controlled_event_log(name, [], child_id)
    writer = open_controlled_writer()
    writer_ref = Process.monitor(writer)
    log_ref = Process.monitor(log)

    stop_supervised(child_id)

    assert_receive {:DOWN, ^writer_ref, :process, ^writer, _reason}
    assert_receive {:DOWN, ^log_ref, :process, ^log, :shutdown}
  end

  @spec record_and_await(atom(), MingaAgent.EventLog.EventRecord.event_type(), map()) ::
          pos_integer()
  defp record_and_await(server, event_type, payload) do
    assert {:queued, receipt} = EventLog.record("durable-session", event_type, payload, server)
    assert {:persisted, event_id} = EventLog.await(receipt)
    event_id
  end

  @spec start_event_log(atom(), keyword(), atom()) :: pid()
  defp start_event_log(name, opts, child_id \\ unique_name("event-log-child")) do
    spec =
      Supervisor.child_spec(
        {EventLog, [name: name, retention_sweep?: false, health_check: :none] ++ opts},
        id: child_id
      )

    start_supervised!(spec)
  end

  @spec start_controlled_event_log(atom(), keyword(), atom()) :: pid()
  defp start_controlled_event_log(name, opts \\ [], child_id \\ unique_name("controlled-child")) do
    start_event_log(
      name,
      [
        store_backend: ControllableStore,
        store_backend_opts: [controller: self()]
      ] ++ opts,
      child_id
    )
  end

  @spec open_controlled_writer() :: pid()
  defp open_controlled_writer do
    assert_receive {:event_log_store_open, writer, _path}, @event_timeout
    send(writer, {:event_log_store_open_result, :ok})
    writer
  end

  @spec unique_name(String.t()) :: atom()
  defp unique_name(prefix) do
    String.to_atom("#{prefix}-#{System.unique_integer([:positive])}")
  end
end
