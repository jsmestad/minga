defmodule MingaAgent.EventLog.StoreTest do
  use ExUnit.Case, async: true

  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.Store

  import Bitwise, only: [band: 2]

  @moduletag :tmp_dir

  setup do
    {:ok, db} = Store.open_memory()

    on_exit(fn -> Store.close(db) end)

    {:ok, db: db}
  end

  test "events_after returns a session cursor in id order", %{db: db} do
    {:ok, first_id} =
      Store.insert(db, EventRecord.new("session-a", :session_started, %{"n" => 1}))

    {:ok, second_id} =
      Store.insert(db, EventRecord.new("session-a", :assistant_delta, %{"delta" => "hi"}))

    {:ok, _other_id} =
      Store.insert(db, EventRecord.new("session-b", :session_started, %{"n" => 3}))

    assert {:ok, [first, second]} = Store.events_after(db, "session-a", 0, 10)
    assert first.id == first_id
    assert second.id == second_id
    assert Enum.map([first, second], & &1.event_type) == [:session_started, :assistant_delta]
    assert {:ok, [^second]} = Store.events_after(db, "session-a", first_id, 10)
    assert {:ok, []} = Store.events_after(db, "session-a", second_id, 10)
  end

  test "repeated insertion of one event key returns the committed id without duplication", %{
    db: db
  } do
    record = EventRecord.new("session-a", :tool_call_started, %{"tool_call_id" => "tool-1"})
    %EventRecord{event_key: expected_event_key} = record

    assert {:ok, first_id} = Store.insert(db, record)
    assert {:ok, ^first_id} = Store.insert(db, record)
    assert {:ok, 1} = Store.count(db)

    assert {:ok, [%{id: ^first_id, event_key: event_key}]} =
             Store.events_after(db, "session-a", 0, 10)

    assert event_key == expected_event_key
  end

  test "open migrates version one events to stable idempotency keys", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "legacy-agent-events.db")
    {:ok, legacy} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(
        legacy,
        "CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, event_type TEXT NOT NULL, payload TEXT NOT NULL DEFAULT '{}', wall_clock TEXT NOT NULL, monotonic_ts INTEGER NOT NULL)"
      )

    :ok =
      Exqlite.Sqlite3.execute(legacy, "CREATE TABLE schema_version (version INTEGER NOT NULL)")

    :ok = Exqlite.Sqlite3.execute(legacy, "INSERT INTO schema_version (version) VALUES (1)")

    :ok =
      Exqlite.Sqlite3.execute(
        legacy,
        "INSERT INTO events (session_id, event_type, payload, wall_clock, monotonic_ts) VALUES ('legacy-session', 'session_started', '{}', '2026-01-01T00:00:00Z', 1)"
      )

    :ok = Exqlite.Sqlite3.close(legacy)
    {:ok, migrated} = Store.open(path)

    assert {:ok, [%{id: 1, event_key: "legacy-1"}]} =
             Store.events_after(migrated, "legacy-session", 0, 10)

    :ok = Store.close(migrated)
  end

  test "open creates a missing database directory as private", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "agent-log")
    path = Path.join(dir, "agent_events.db")

    {:ok, db} = Store.open(path)
    :ok = Store.close(db)

    assert file_mode(dir) == 0o700
    assert file_mode(path) == 0o600
  end

  test "open does not chmod an existing database parent directory", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "shared-parent")
    path = Path.join(dir, "agent_events.db")

    File.mkdir_p!(dir)
    File.write!(path, "")
    File.chmod!(dir, 0o755)
    File.chmod!(path, 0o666)

    {:ok, db} = Store.open(path)
    :ok = Store.close(db)

    assert file_mode(dir) == 0o755
    assert file_mode(path) == 0o600
  end

  test "writes keep SQLite WAL and SHM files private", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "agent_events.db")
    {:ok, db} = Store.open(path)

    {:ok, _id} =
      Store.insert(
        db,
        EventRecord.new("stable-session", :system_message, %{"message" => "hello"})
      )

    for file_path <- [path, path <> "-wal", path <> "-shm"] do
      assert File.exists?(file_path)
      assert file_mode(file_path) == 0o600
    end

    :ok = Store.close(db)
  end

  test "records survive reopening the database", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "agent_events.db")
    {:ok, db} = Store.open(path)

    {:ok, id} =
      Store.insert(
        db,
        EventRecord.new("stable-session", :system_message, %{"message" => "hello"})
      )

    :ok = Store.close(db)

    {:ok, reopened} = Store.open(path)

    assert {:ok, [%{id: ^id, payload: %{"message" => "hello"}}]} =
             Store.events_after(reopened, "stable-session", 0, 10)

    :ok = Store.close(reopened)
  end

  @spec file_mode(String.t()) :: non_neg_integer()
  defp file_mode(path) do
    {:ok, stat} = File.stat(path)
    band(stat.mode, 0o777)
  end
end
