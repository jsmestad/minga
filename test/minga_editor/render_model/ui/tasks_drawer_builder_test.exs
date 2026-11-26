defmodule MingaEditor.RenderModel.UI.TasksDrawerBuilderTest do
  @moduledoc """
  The drawer's text comes from goals, previews and provider errors, so its size is not the drawer's to choose. The builder bounds it in words the user can read, and the encoder never meets a field it cannot carry.
  """

  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.TasksDrawerEncoder
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target
  alias MingaEditor.Agent.Tasks
  alias MingaEditor.RenderModel.UI.TasksDrawerBuilder
  alias MingaEditor.Shell.Traditional.Drawers

  describe "fit/1" do
    test "keeps text a row can show and cuts longer text to the limit, ending in an ellipsis" do
      assert TasksDrawerBuilder.fit("Add tests") == "Add tests"

      cut = TasksDrawerBuilder.fit(String.duplicate("é", 1_000))
      assert String.length(cut) == 400
      assert String.ends_with?(cut, "…")
    end
  end

  describe "bound/1" do
    test "keeps a short view whole and ends a long one with how many lines are left" do
      assert TasksDrawerBuilder.bound(["a", "b"]) == ["a", "b"]
      assert TasksDrawerBuilder.bound([]) == []

      lines = for n <- 1..5_003, do: "+ line #{n}"
      bounded = TasksDrawerBuilder.bound(lines)
      assert Enum.at(bounded, 5_000) == "… 3 more lines, in the conversation"
      assert Enum.at(bounded, 5_001) == nil
    end

    test "cuts a line longer than a view line carries, ending in an ellipsis" do
      [line] = TasksDrawerBuilder.bound([String.duplicate("é", 40_000)])
      assert byte_size(line) <= 16_384 + 3
      assert String.valid?(line)
      assert String.ends_with?(line, "…")
    end
  end

  test "a request far larger than the wire carries still builds and encodes" do
    pid = spawn(fn -> :ok end)
    goal = String.duplicate("x", 70_000)
    lines = for n <- 1..70_000, do: "+ line #{n}"

    approval =
      Public.new(
        Target.new("session-1", "request-1", "call-1"),
        "write_file",
        %{"path" => "big.ex"},
        Preview.new(:diff, String.duplicate("big.ex ", 20_000), lines)
      )

    tasks =
      Tasks.new()
      |> Tasks.follow(pid, 0, title: goal)
      |> Tasks.observe(pid, {:approval_pending, approval}, 1)

    {drawers, _hidden} = Drawers.open(%Drawers{}, :tasks)
    [row_id] = TasksDrawerBuilder.row_ids(tasks)

    list = TasksDrawerBuilder.build(tasks, Drawers.select(drawers, row_id), 1)
    assert [%{title: title, detail: [detail]}] = list.rows
    assert String.length(title) == 400
    assert String.length(detail) <= 400
    assert is_binary(TasksDrawerEncoder.encode_command(list))

    {:ok, entry} = Tasks.fetch(tasks, pid)
    lines = TasksDrawerBuilder.diff_lines(entry)
    assert Enum.at(lines, 5_000) =~ "more lines"
    assert Enum.at(lines, 5_001) == nil

    diff = TasksDrawerBuilder.build(tasks, Drawers.show(drawers, {:diff, row_id}), 1)
    assert diff.view_lines == lines
    assert is_binary(TasksDrawerEncoder.encode_command(diff))
  end

  test "a provider failure far larger than a view line still builds and encodes" do
    pid = spawn(fn -> :ok end)
    body = String.duplicate("<html>error page</html>", 10_000)

    tasks =
      Tasks.new()
      |> Tasks.follow(pid, 0, title: "Run the suite")
      |> Tasks.observe(pid, {:status_changed, :thinking}, 1)
      |> Tasks.observe(pid, {:error, body}, 2)

    {drawers, _hidden} = Drawers.open(%Drawers{}, :tasks)
    [row_id] = TasksDrawerBuilder.row_ids(tasks)
    output = TasksDrawerBuilder.build(tasks, Drawers.show(drawers, {:output, row_id}), 3)

    assert Enum.all?(output.view_lines, &(byte_size(&1) <= 16_384 + 3))
    assert is_binary(TasksDrawerEncoder.encode_command(output))
  end
end
