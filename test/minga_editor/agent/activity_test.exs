defmodule MingaEditor.Agent.ActivityTest do
  use ExUnit.Case, async: true

  alias MingaAgent.TodoItem
  alias MingaEditor.Agent.Activity

  describe "turn projection" do
    test "tracks tool and file progress while preserving todos" do
      todo = %TodoItem{id: "1", description: "Inspect files", status: :in_progress}
      started_at = ~U[2026-06-23 12:00:00Z]

      activity =
        Activity.new()
        |> Activity.set_todos([todo])
        |> Activity.start_turn(started_at)
        |> Activity.start_tool("shell")
        |> Activity.record_file("lib/a.ex")
        |> Activity.record_file("lib/a.ex")
        |> Activity.record_file("lib/b.ex")

      assert activity.todos == [todo]
      assert activity.started_at == started_at
      assert activity.active_action == "Running shell"
      assert activity.tool_count == 1
      assert Activity.file_count(activity) == 2
    end

    test "finish_turn clears live action but keeps the summary counters" do
      activity =
        Activity.new()
        |> Activity.start_tool("read_file")
        |> Activity.record_file("lib/a.ex")
        |> Activity.finish_turn()

      assert activity.started_at == nil
      assert activity.active_action == ""
      assert activity.tool_count == 1
      assert Activity.file_count(activity) == 1
    end
  end
end
