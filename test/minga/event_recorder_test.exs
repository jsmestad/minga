defmodule Minga.EventRecorderTest do
  use ExUnit.Case, async: true

  alias Minga.EventRecorder
  alias Minga.EventRecorder.Store
  alias Minga.Events

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "minga_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    recorder =
      start_supervised!(
        {EventRecorder,
         name: :"recorder_#{:erlang.unique_integer([:positive])}",
         db_dir: tmp_dir,
         subscribe: false}
      )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{recorder: recorder, db_dir: tmp_dir}
  end

  defp wait_for_processing(recorder) do
    :sys.get_state(recorder)
    :ok
  end

  defp open_db(db_dir) do
    {:ok, db} = Store.open(EventRecorder.db_path(db_dir: db_dir))
    db
  end

  describe "event recording" do
    test "records buffer_saved events with path in payload", %{
      recorder: recorder,
      db_dir: db_dir
    } do
      send(
        recorder,
        {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: self(), path: "/tmp/test.ex"}}
      )

      wait_for_processing(recorder)

      db = open_db(db_dir)
      {:ok, [event]} = Store.events_by_type(db, :buffer_saved)
      Store.close(db)

      assert event.event_type == :buffer_saved
      assert event.source == "user"
      assert event.payload["path"] == "/tmp/test.ex"
    end

    test "records buffer_opened events", %{recorder: recorder, db_dir: db_dir} do
      send(
        recorder,
        {:minga_event, :buffer_opened,
         %Events.BufferEvent{buffer: self(), path: "/tmp/opened.ex"}}
      )

      wait_for_processing(recorder)

      db = open_db(db_dir)
      {:ok, [event]} = Store.events_by_type(db, :buffer_opened)
      Store.close(db)

      assert event.payload["path"] == "/tmp/opened.ex"
    end

    test "records mode_changed events with old/new in payload", %{
      recorder: recorder,
      db_dir: db_dir
    } do
      send(
        recorder,
        {:minga_event, :mode_changed, %Events.ModeEvent{old: :normal, new: :insert}}
      )

      wait_for_processing(recorder)

      db = open_db(db_dir)
      {:ok, [event]} = Store.events_by_type(db, :mode_changed)
      Store.close(db)

      assert event.payload["old"] == "normal"
      assert event.payload["new"] == "insert"
    end

    test "records buffer_changed events with source identity", %{
      recorder: recorder,
      db_dir: db_dir
    } do
      send(
        recorder,
        {:minga_event, :buffer_changed,
         %Events.BufferChangedEvent{buffer: self(), source: Minga.Buffer.EditSource.user()}}
      )

      wait_for_processing(recorder)

      db = open_db(db_dir)
      {:ok, [event]} = Store.events_by_type(db, :buffer_changed)
      Store.close(db)

      assert event.source == "user"
    end

    test "records command_done events with command and exit code", %{
      recorder: recorder,
      db_dir: db_dir
    } do
      send(
        recorder,
        {:minga_event, :command_done, %Events.CommandDoneEvent{name: "mix test", exit_code: 1}}
      )

      wait_for_processing(recorder)

      db = open_db(db_dir)
      {:ok, [event]} = Store.events_by_type(db, :command_done)
      Store.close(db)

      assert event.payload["command"] == "mix test"
      assert event.payload["exit_code"] == 1
    end

    test "records git_status_changed events with branch and root", %{
      recorder: recorder,
      db_dir: db_dir
    } do
      send(
        recorder,
        {:minga_event, :git_status_changed,
         %Events.GitStatusEvent{
           git_root: "/home/user/project",
           entries: [],
           branch: "main",
           ahead: 0,
           behind: 0
         }}
      )

      wait_for_processing(recorder)

      db = open_db(db_dir)
      {:ok, [event]} = Store.events_by_type(db, :git_status_changed)
      Store.close(db)

      assert event.payload["git_root"] == "/home/user/project"
      assert event.payload["branch"] == "main"
    end

    test "records multiple events in chronological order", %{
      recorder: recorder,
      db_dir: db_dir
    } do
      send(
        recorder,
        {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: self(), path: "/tmp/a.ex"}}
      )

      send(
        recorder,
        {:minga_event, :mode_changed, %Events.ModeEvent{old: :normal, new: :insert}}
      )

      send(
        recorder,
        {:minga_event, :command_done, %Events.CommandDoneEvent{name: "test", exit_code: 0}}
      )

      wait_for_processing(recorder)

      db = open_db(db_dir)
      {:ok, count} = Store.count(db)
      Store.close(db)

      assert count == 3
    end

    test "records buffer_closed events with scratch path", %{
      recorder: recorder,
      db_dir: db_dir
    } do
      send(
        recorder,
        {:minga_event, :buffer_closed, %Events.BufferClosedEvent{buffer: self(), path: :scratch}}
      )

      wait_for_processing(recorder)

      db = open_db(db_dir)
      {:ok, [event]} = Store.events_by_type(db, :buffer_closed)
      Store.close(db)

      assert event.payload["path"] == ":scratch"
    end

    test "handles rapid event burst without dropping events", %{
      recorder: recorder,
      db_dir: db_dir
    } do
      for i <- 1..100 do
        send(
          recorder,
          {:minga_event, :buffer_saved,
           %Events.BufferEvent{buffer: self(), path: "/tmp/file_#{i}.ex"}}
        )
      end

      wait_for_processing(recorder)

      db = open_db(db_dir)
      {:ok, count} = Store.count(db)
      Store.close(db)

      assert count == 100
    end
  end

  describe "retention sweep" do
    test "deletes old events and keeps recent ones", %{recorder: recorder, db_dir: db_dir} do
      # Insert an old event directly via Store
      db = open_db(db_dir)

      old_record = %Minga.EventRecorder.EventRecord{
        timestamp: 0,
        wall_clock: ~U[2020-01-01 00:00:00Z],
        source: "user",
        scope: :global,
        event_type: :mode_changed,
        payload: %{"marker" => "old"}
      }

      :ok = Store.insert(db, old_record)
      Store.close(db)

      # Send a recent event through the recorder
      send(
        recorder,
        {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: self(), path: "/tmp/recent.ex"}}
      )

      wait_for_processing(recorder)

      # Trigger sweep
      send(recorder, :retention_sweep)
      wait_for_processing(recorder)

      # Old event should be gone, recent should remain
      db2 = open_db(db_dir)
      {:ok, old_events} = Store.events_by_type(db2, :mode_changed)
      {:ok, recent_events} = Store.events_by_type(db2, :buffer_saved)
      Store.close(db2)

      assert old_events == []
      assert [_ | _] = recent_events
    end
  end

  describe "resilience" do
    test "ignores unknown messages without crashing", %{recorder: recorder} do
      send(recorder, :garbage)
      send(recorder, {:unexpected, "data"})

      # If the recorder crashed, this would raise
      :sys.get_state(recorder)
    end

    test "handles corrupt database by recreating", %{db_dir: db_dir} do
      db_path = EventRecorder.db_path(db_dir: db_dir)

      # Stop the current recorder
      stop_supervised!(EventRecorder)

      # Corrupt the database file
      File.write!(db_path, "this is not a valid sqlite database")

      # Start a new recorder with the same db_dir
      recorder2 =
        start_supervised!(
          {EventRecorder,
           name: :"recorder_corrupt_#{:erlang.unique_integer([:positive])}",
           db_dir: db_dir,
           subscribe: false}
        )

      # It should work after recreation
      send(
        recorder2,
        {:minga_event, :buffer_saved, %Events.BufferEvent{buffer: self(), path: "/tmp/ok.ex"}}
      )

      wait_for_processing(recorder2)

      db = open_db(db_dir)
      {:ok, [event]} = Store.events_by_type(db, :buffer_saved)
      Store.close(db)

      assert event.payload["path"] == "/tmp/ok.ex"
    end
  end
end
