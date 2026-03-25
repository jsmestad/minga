defmodule Minga.Session.EventRecorder.StoreTest do
  use ExUnit.Case, async: true

  alias Minga.Session.EventRecorder.EventRecord
  alias Minga.Session.EventRecorder.Store

  setup do
    {:ok, db} = Store.open_memory()
    on_exit(fn -> Store.close(db) end)
    %{db: db}
  end

  defp make_record(overrides \\ %{}) do
    defaults = %{
      timestamp: System.monotonic_time(:microsecond),
      wall_clock: DateTime.utc_now(),
      source: "user",
      scope: :global,
      event_type: :buffer_saved,
      payload: %{}
    }

    attrs = Map.merge(defaults, overrides)
    struct!(EventRecord, Map.to_list(attrs))
  end

  describe "insert/2 and count/1" do
    test "inserts an event and increments count", %{db: db} do
      assert {:ok, 0} = Store.count(db)
      assert :ok = Store.insert(db, make_record())
      assert {:ok, 1} = Store.count(db)
    end

    test "inserts multiple events", %{db: db} do
      for _ <- 1..10, do: Store.insert(db, make_record())
      assert {:ok, 10} = Store.count(db)
    end

    test "stores and retrieves payload data", %{db: db} do
      record = make_record(%{payload: %{"path" => "/tmp/test.ex", "line" => 42}})
      :ok = Store.insert(db, record)

      {:ok, [retrieved]} = Store.events_by_type(db, :buffer_saved)
      assert retrieved.payload == %{"path" => "/tmp/test.ex", "line" => 42}
    end

    test "stores and retrieves different scope types", %{db: db} do
      :ok = Store.insert(db, make_record(%{scope: :global, event_type: :mode_changed}))

      :ok =
        Store.insert(db, make_record(%{scope: {:buffer, "/tmp/a.ex"}, event_type: :buffer_saved}))

      :ok =
        Store.insert(
          db,
          make_record(%{scope: {:session, "sess-123"}, event_type: :command_done})
        )

      {:ok, [global]} = Store.events_by_type(db, :mode_changed)
      assert global.scope == :global

      {:ok, [buffer]} = Store.events_by_type(db, :buffer_saved)
      assert buffer.scope == {:buffer, "/tmp/a.ex"}

      {:ok, [session]} = Store.events_by_type(db, :command_done)
      assert session.scope == {:session, "sess-123"}
    end
  end

  describe "events_in_range/4" do
    test "returns events within the time range", %{db: db} do
      t1 = ~U[2025-01-01 10:00:00Z]
      t2 = ~U[2025-01-01 11:00:00Z]
      t3 = ~U[2025-01-01 12:00:00Z]
      t4 = ~U[2025-01-01 13:00:00Z]

      :ok = Store.insert(db, make_record(%{wall_clock: t1}))
      :ok = Store.insert(db, make_record(%{wall_clock: t2}))
      :ok = Store.insert(db, make_record(%{wall_clock: t3}))
      :ok = Store.insert(db, make_record(%{wall_clock: t4}))

      {:ok, events} = Store.events_in_range(db, t2, t3)
      assert length(events) == 2
    end

    test "filters by event_type", %{db: db} do
      t1 = ~U[2025-01-01 10:00:00Z]
      t2 = ~U[2025-01-01 11:00:00Z]

      :ok = Store.insert(db, make_record(%{wall_clock: t1, event_type: :buffer_saved}))
      :ok = Store.insert(db, make_record(%{wall_clock: t1, event_type: :mode_changed}))
      :ok = Store.insert(db, make_record(%{wall_clock: t2, event_type: :buffer_saved}))

      {:ok, events} =
        Store.events_in_range(db, ~U[2025-01-01 00:00:00Z], ~U[2025-01-02 00:00:00Z],
          event_type: :buffer_saved
        )

      assert length(events) == 2
      assert Enum.all?(events, &(&1.event_type == :buffer_saved))
    end

    test "filters by source", %{db: db} do
      t1 = ~U[2025-01-01 10:00:00Z]

      :ok = Store.insert(db, make_record(%{wall_clock: t1, source: "user"}))
      :ok = Store.insert(db, make_record(%{wall_clock: t1, source: "agent:pid:call1"}))

      {:ok, events} =
        Store.events_in_range(db, ~U[2025-01-01 00:00:00Z], ~U[2025-01-02 00:00:00Z],
          source: "agent:pid:call1"
        )

      assert length(events) == 1
      assert hd(events).source == "agent:pid:call1"
    end

    test "respects order option", %{db: db} do
      t1 = ~U[2025-01-01 10:00:00Z]
      t2 = ~U[2025-01-01 11:00:00Z]

      :ok = Store.insert(db, make_record(%{wall_clock: t1, payload: %{"n" => 1}}))
      :ok = Store.insert(db, make_record(%{wall_clock: t2, payload: %{"n" => 2}}))

      {:ok, asc} =
        Store.events_in_range(db, ~U[2025-01-01 00:00:00Z], ~U[2025-01-02 00:00:00Z], order: :asc)

      {:ok, desc} =
        Store.events_in_range(db, ~U[2025-01-01 00:00:00Z], ~U[2025-01-02 00:00:00Z],
          order: :desc
        )

      assert hd(asc).payload["n"] == 1
      assert hd(desc).payload["n"] == 2
    end

    test "respects limit option", %{db: db} do
      for i <- 1..20 do
        t = DateTime.add(~U[2025-01-01 00:00:00Z], i, :hour)
        Store.insert(db, make_record(%{wall_clock: t}))
      end

      {:ok, events} =
        Store.events_in_range(db, ~U[2025-01-01 00:00:00Z], ~U[2025-01-02 00:00:00Z], limit: 5)

      assert length(events) == 5
    end
  end

  describe "events_by_source/3" do
    test "returns events matching the source", %{db: db} do
      :ok = Store.insert(db, make_record(%{source: "user"}))
      :ok = Store.insert(db, make_record(%{source: "user"}))
      :ok = Store.insert(db, make_record(%{source: "lsp:elixir_ls"}))

      {:ok, events} = Store.events_by_source(db, "user")
      assert length(events) == 2
    end
  end

  describe "events_by_scope/3" do
    test "returns events matching the scope", %{db: db} do
      :ok = Store.insert(db, make_record(%{scope: {:buffer, "/tmp/a.ex"}}))
      :ok = Store.insert(db, make_record(%{scope: {:buffer, "/tmp/a.ex"}}))
      :ok = Store.insert(db, make_record(%{scope: {:buffer, "/tmp/b.ex"}}))

      {:ok, events} = Store.events_by_scope(db, "buffer:/tmp/a.ex")
      assert length(events) == 2
    end
  end

  describe "events_by_type/3" do
    test "returns events matching the type", %{db: db} do
      :ok = Store.insert(db, make_record(%{event_type: :buffer_saved}))
      :ok = Store.insert(db, make_record(%{event_type: :buffer_opened}))
      :ok = Store.insert(db, make_record(%{event_type: :buffer_saved}))

      {:ok, events} = Store.events_by_type(db, :buffer_saved)
      assert length(events) == 2
    end
  end

  describe "delete_before/2" do
    test "deletes events older than the cutoff", %{db: db} do
      old = ~U[2024-01-01 00:00:00Z]
      recent = ~U[2025-06-01 00:00:00Z]

      :ok = Store.insert(db, make_record(%{wall_clock: old}))
      :ok = Store.insert(db, make_record(%{wall_clock: old}))
      :ok = Store.insert(db, make_record(%{wall_clock: recent}))

      {:ok, deleted} = Store.delete_before(db, ~U[2025-01-01 00:00:00Z])
      assert deleted == 2
      assert {:ok, 1} = Store.count(db)
    end

    test "returns 0 when nothing to delete", %{db: db} do
      :ok = Store.insert(db, make_record(%{wall_clock: ~U[2025-06-01 00:00:00Z]}))
      {:ok, deleted} = Store.delete_before(db, ~U[2024-01-01 00:00:00Z])
      assert deleted == 0
    end
  end

  describe "integrity_check/1" do
    test "reports healthy for a valid database", %{db: db} do
      assert {:ok, :healthy} = Store.integrity_check(db)
    end
  end

  describe "schema" do
    test "indexes exist", %{db: db} do
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(db, "SELECT name FROM sqlite_master WHERE type='index'")

      indexes = collect_rows(db, stmt)
      Exqlite.Sqlite3.release(db, stmt)

      index_names = Enum.map(indexes, &hd/1)
      assert "idx_events_wall_clock" in index_names
      assert "idx_events_event_type" in index_names
      assert "idx_events_source" in index_names
      assert "idx_events_scope" in index_names
    end

    test "schema version is stored", %{db: db} do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "SELECT version FROM schema_version")
      {:row, [version]} = Exqlite.Sqlite3.step(db, stmt)
      Exqlite.Sqlite3.release(db, stmt)

      assert version == 1
    end
  end

  defp collect_rows(db, stmt) do
    case Exqlite.Sqlite3.step(db, stmt) do
      {:row, row} -> [row | collect_rows(db, stmt)]
      :done -> []
    end
  end
end
