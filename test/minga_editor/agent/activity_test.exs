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
        |> Activity.start_tool("call-1", "shell")
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
        |> Activity.start_tool("call-1", "read_file")
        |> Activity.record_file("lib/a.ex")
        |> Activity.finish_turn()

      assert activity.started_at == nil
      assert activity.active_action == ""
      assert activity.tool_count == 1
      assert Activity.file_count(activity) == 1
    end

    test "restored concurrent calls with the same name retire separately" do
      activity = Activity.restore_running_tools(Activity.new(), [{"a", "shell"}, {"b", "shell"}])
      activity = Activity.start_tool(activity, "b", "shell")
      activity = Activity.finish_tool(activity, "b")
      assert Activity.active_tool_name(activity) == "shell"
      assert activity.active_action == "Running shell"
      assert activity.tool_count == 2

      activity = Activity.finish_tool(activity, "a")
      assert Activity.active_tool_name(activity) == nil
      assert activity.active_action == "Thinking"
    end
  end
end
