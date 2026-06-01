defmodule MingaAgent.EventLog.StoreTest do
  # Changes the process working directory in one regression test.
  use ExUnit.Case, async: false

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

  test "open with a bare relative database path does not chmod cwd", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "agent_events.db")

    File.chmod!(tmp_dir, 0o755)

    File.cd!(tmp_dir, fn ->
      {:ok, db} = Store.open("agent_events.db")
      :ok = Store.close(db)
    end)

    assert file_mode(tmp_dir) == 0o755
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
