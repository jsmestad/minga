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

  describe "apply_status/2" do
    setup do
      %{running: Activity.start_tool(Activity.new(), "call-1", "shell")}
    end

    test "every Session status maps to its turn transition", %{running: running} do
      idle = Activity.finish_turn(running)

      for {status, from, expected} <- [
            {:thinking, Activity.new(), Activity.start_turn(Activity.new())},
            {:tool_executing, Activity.new(), Activity.start_turn(Activity.new())},
            {:thinking, running, running},
            {:idle, running, idle},
            {:error, Activity.finish_tool(running, "call-1"), idle},
            {:plan, Activity.finish_tool(running, "call-1"), idle},
            {:error, running, running},
            {:plan, running, running},
            {:approval_waiting, running, running}
          ] do
        assert strip_time(Activity.apply_status(from, status)) == strip_time(expected),
               "#{status} from #{inspect(from.active_action)}"
      end
    end

    test "a turn after an idle status counts its tools from zero", %{running: running} do
      next = running |> Activity.apply_status(:idle) |> Activity.apply_status(:thinking)

      assert next.active_action == "Thinking"
      assert next.tool_count == 0
    end
  end

  defp strip_time(activity), do: %{activity | started_at: activity.started_at && :set}
end
