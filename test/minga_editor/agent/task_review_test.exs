defmodule MingaEditor.Agent.TaskReviewTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.EditSource
  alias MingaEditor.Agent.TaskReview

  test "the tree and locations list agree across files and confirmed decisions" do
    first = changed_buffer("first")
    last = changed_buffer("last")
    files = fn -> [offer(last, "z.ex"), offer(first, "a.ex")] end
    review = TaskReview.refresh(TaskReview.new("task", "Fix retries"), files.(), [])

    assert [
             {"a.ex", {0, 0}, {:review_unit, ^first, _}},
             {"z.ex", {0, 0}, {:review_unit, ^last, _}}
           ] =
             TaskReview.locations(review)

    review = TaskReview.navigate(review, :previous)
    assert {{^last, _}, "z.ex", _, target} = TaskReview.selected(review)
    assert {:ok, [_]} = Buffer.decide_review(last, target, :reject)

    review = TaskReview.refresh(review, files.(), [])
    assert [{"a.ex", {0, 0}, {:review_unit, ^first, _}}] = TaskReview.locations(review)
    assert {{^first, _}, "a.ex", _, target} = TaskReview.selected(review)
    refute elem(TaskReview.text(review), 0) =~ "Passt."
    assert :ok = Buffer.decide_review(first, target, :keep)

    review = TaskReview.refresh(TaskReview.new("task", "Fix retries"), files.(), [])
    assert [] = TaskReview.locations(review)
    {text, _row} = TaskReview.text(review)
    assert text =~ "Kept\n  a.ex · 1 change"
    assert text =~ "Rejected\n  z.ex · 1 change"
    assert [_] = :binary.matches(text, "Passt.")
    assert Buffer.content(first) == "first"
    assert Buffer.content(last) == "original"
  end

  test "an unavailable history never reads as finished or empty" do
    review = TaskReview.refresh(TaskReview.new("task", "Fix retries"), [], ["closed.ex"])
    {text, _row} = TaskReview.text(review)
    assert text =~ "History unavailable: closed.ex"
    refute text =~ "Passt."
    refute text =~ "No changes to review."
  end

  defp changed_buffer(text) do
    buffer = start_supervised!({Buffer, content: "original"}, id: make_ref())
    assert :ok = Buffer.apply_edit(buffer, 0, 0, 0, 7, text, EditSource.minga("task", text))
    buffer
  end

  defp offer(buffer, path), do: {buffer, path, Buffer.task_review_entries(buffer, "task")}
end
