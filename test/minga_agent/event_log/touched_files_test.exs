defmodule MingaAgent.EventLog.TouchedFilesTest do
  use ExUnit.Case, async: true

  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.TouchedFiles

  @earlier ~U[2026-07-17 12:00:00Z]
  @later ~U[2026-07-17 12:01:00Z]

  test "classifies every admitted file-change shape" do
    cases = [
      {"", "created", :created},
      {"before", "after", :modified},
      {"deleted", "", :deleted},
      {"", "", :modified}
    ]

    for {before_content, after_content, expected_action} <- cases do
      event = file_event("session", "lib/example.ex", before_content, after_content, 10, @earlier)
      assert {:ok, projection} = TouchedFiles.record(TouchedFiles.new(), event, 1)

      assert TouchedFiles.list(projection, "session") == [
               %{path: "lib/example.ex", action: expected_action, timestamp: 10}
             ]
    end
  end

  test "latest durable event controls action and most-recent-first ordering" do
    events = [
      {file_event("session", "lib/a.ex", "", "one", 10, @earlier), 1},
      {file_event("session", "lib/b.ex", "old", "new", 20, @earlier), 2},
      {file_event("session", "lib/a.ex", "one", "", 30, @later), 3}
    ]

    projection =
      Enum.reduce(events, TouchedFiles.new(), fn {event, id}, projection ->
        {:ok, projection} = TouchedFiles.record(projection, event, id)
        projection
      end)

    assert TouchedFiles.list(projection, "session") == [
             %{path: "lib/a.ex", action: :deleted, timestamp: 30},
             %{path: "lib/b.ex", action: :modified, timestamp: 20}
           ]
  end

  test "duplicate and older replay cannot duplicate or regress a path" do
    created = file_event("session", "lib/a.ex", "", "one", 10, @earlier)
    deleted = file_event("session", "lib/a.ex", "one", "", 30, @later)

    assert {:ok, projection} = TouchedFiles.record(TouchedFiles.new(), created, 1)
    assert {:ok, projection} = TouchedFiles.record(projection, deleted, 3)
    assert {:ok, projection} = TouchedFiles.record(projection, deleted, 3)
    assert {:ok, projection} = TouchedFiles.record(projection, created, 1)

    assert TouchedFiles.list(projection, "session") == [
             %{path: "lib/a.ex", action: :deleted, timestamp: 30}
           ]
  end

  test "rebuild uses the same transition as live admission" do
    first = %{file_event("session", "lib/a.ex", "", "one", 10, @earlier) | id: 1}
    second = %{file_event("session", "lib/a.ex", "one", "two", 20, @later) | id: 2}

    assert {:ok, rebuilt} = TouchedFiles.rebuild([first, second, first])

    assert TouchedFiles.list(rebuilt, "session") == [
             %{path: "lib/a.ex", action: :modified, timestamp: 20}
           ]
  end

  test "malformed file-edit events return a typed rejection" do
    event = EventRecord.new("session", :file_edit_proposed, %{"path" => "lib/a.ex"})

    assert TouchedFiles.record(TouchedFiles.new(), event, 1) ==
             {:error, {:invalid_file_edit, :before_content}}
  end

  defp file_event(session_id, path, before_content, after_content, monotonic_ts, wall_clock) do
    EventRecord.new(
      session_id,
      :file_edit_proposed,
      %{
        "path" => path,
        "before_content" => before_content,
        "after_content" => after_content
      },
      monotonic_ts: monotonic_ts,
      wall_clock: wall_clock
    )
  end
end
