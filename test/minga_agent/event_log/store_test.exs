defmodule MingaAgent.EventLog.StoreTest do
  use ExUnit.Case, async: true

  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.Store

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
end
