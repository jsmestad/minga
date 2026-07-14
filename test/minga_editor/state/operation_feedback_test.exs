defmodule MingaEditor.State.OperationFeedbackTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.OperationProgress
  alias MingaEditor.State.OperationQueue

  test "empty store is idle and identities increase monotonically" do
    feedback = OperationFeedback.new(3)
    assert OperationFeedback.selected(feedback) == nil

    {feedback, first} = OperationFeedback.start(feedback, :external_format, "a", "First")
    feedback = OperationFeedback.dismiss(feedback, first.id)
    {_feedback, second} = OperationFeedback.start(feedback, :external_format, "b", "Second")

    assert second.id == first.id + 1
    assert is_integer(second.id)
  end

  test "concurrent resources remain independently correlated" do
    {feedback, left} =
      OperationFeedback.new()
      |> OperationFeedback.start(:git_stage, "repo:left", "Left", replace?: false)

    {feedback, right} =
      OperationFeedback.start(feedback, :git_commit, "repo:right", "Right", replace?: false)

    feedback = OperationFeedback.finish(feedback, left.id, :success, "Left done")
    feedback = OperationFeedback.running(feedback, right.id, "Right running")

    assert {:ok, left_record} = OperationFeedback.fetch(feedback, left.id)
    assert {:ok, right_record} = OperationFeedback.fetch(feedback, right.id)
    assert left_record.status == :success
    assert right_record.status == :running
    assert OperationFeedback.selected(feedback).id == right.id
  end

  test "replacement marks the old identity stale and late updates cannot change it" do
    {feedback, old} =
      OperationFeedback.start(OperationFeedback.new(), :external_format, "buf", "Old")

    {feedback, current} = OperationFeedback.start(feedback, :external_format, "buf", "Current")

    assert {:ok, replaced} = OperationFeedback.fetch(feedback, old.id)
    assert replaced.status == :stale
    refute replaced.cancelable?

    feedback = OperationFeedback.running(feedback, old.id, "Late running")
    feedback = OperationFeedback.finish(feedback, old.id, :success, "Late success")

    assert {:ok, ^replaced} = OperationFeedback.fetch(feedback, old.id)
    assert OperationFeedback.selected(feedback).id == current.id
  end

  test "newest active wins over terminal records and newest terminal wins when idle" do
    {feedback, first} = OperationFeedback.start(OperationFeedback.new(), :git_stage, "one", "One")
    feedback = OperationFeedback.finish(feedback, first.id, :success, "One done")
    {feedback, second} = OperationFeedback.start(feedback, :git_commit, "two", "Two")

    assert OperationFeedback.selected(feedback).id == second.id

    feedback = OperationFeedback.finish(feedback, second.id, :error, "Two failed")
    assert OperationFeedback.selected(feedback).id == second.id
    assert OperationFeedback.selected(feedback).status == :error
  end

  test "full retained collection preserves active precedence and cancellation fallback" do
    {feedback, first} =
      OperationFeedback.start(
        OperationFeedback.new(4),
        :git_stage,
        "one",
        "One",
        replace?: false
      )

    feedback = OperationFeedback.finish(feedback, first.id, :success, "One done")

    {feedback, active} =
      OperationFeedback.start(feedback, :git_commit, "two", "Two", replace?: false)

    {feedback, canceled} =
      OperationFeedback.start(feedback, :lsp_rename, "three", "Three", replace?: false)

    feedback = OperationFeedback.cancel(feedback, canceled.id, "Canceled")

    {feedback, newest_terminal} =
      OperationFeedback.start(feedback, :external_format, "four", "Four", replace?: false)

    feedback = OperationFeedback.finish(feedback, newest_terminal.id, :error, "Four failed")

    assert OperationFeedback.size(feedback) == 4
    assert OperationFeedback.selected(feedback).id == active.id

    feedback = OperationFeedback.finish(feedback, active.id, :success, "Two done")
    assert OperationFeedback.selected(feedback).id == newest_terminal.id
    assert {:ok, %{status: :canceled}} = OperationFeedback.fetch(feedback, canceled.id)
  end

  test "bounded retention evicts the oldest terminal operation first" do
    {feedback, first} =
      OperationFeedback.start(OperationFeedback.new(2), :git_stage, "one", "One")

    feedback = OperationFeedback.finish(feedback, first.id, :success, "One done")
    {feedback, second} = OperationFeedback.start(feedback, :git_commit, "two", "Two")
    feedback = OperationFeedback.finish(feedback, second.id, :success, "Two done")
    {feedback, third} = OperationFeedback.start(feedback, :lsp_rename, "three", "Three")

    assert OperationFeedback.size(feedback) == 2
    assert OperationFeedback.fetch(feedback, first.id) == :error
    assert {:ok, _} = OperationFeedback.fetch(feedback, second.id)
    assert {:ok, _} = OperationFeedback.fetch(feedback, third.id)
  end

  test "retention never evicts active operations when they exceed the history bound" do
    {feedback, first} =
      OperationFeedback.start(
        OperationFeedback.new(2),
        :git_stage,
        "one",
        "One",
        replace?: false
      )

    {feedback, second} =
      OperationFeedback.start(feedback, :git_commit, "two", "Two", replace?: false)

    {feedback, third} =
      OperationFeedback.start(feedback, :lsp_rename, "three", "Three", replace?: false)

    assert OperationFeedback.size(feedback) == 3

    for operation <- [first, second, third] do
      assert {:ok, retained} = OperationFeedback.fetch(feedback, operation.id)
      assert retained.status == :pending
    end

    feedback = OperationFeedback.finish(feedback, first.id, :success, "One done")

    assert OperationFeedback.size(feedback) == 2
    assert OperationFeedback.fetch(feedback, first.id) == :error
    assert {:ok, _second} = OperationFeedback.fetch(feedback, second.id)
    assert {:ok, _third} = OperationFeedback.fetch(feedback, third.id)
  end

  test "dismissal removes exactly one retained identity" do
    {feedback, first} = OperationFeedback.start(OperationFeedback.new(), :git_stage, "one", "One")
    {feedback, second} = OperationFeedback.start(feedback, :git_commit, "two", "Two")
    feedback = OperationFeedback.dismiss(feedback, second.id)

    assert OperationFeedback.fetch(feedback, second.id) == :error
    assert OperationFeedback.selected(feedback).id == first.id
    assert OperationFeedback.dismiss(feedback, 999) == feedback
  end

  test "queue and progress metadata validate ranges and clear on running or terminal" do
    {feedback, operation} =
      OperationFeedback.start(OperationFeedback.new(), :git_commit, "repo", "Commit")

    assert {:error, :invalid_queue_range} =
             OperationFeedback.queued(feedback, operation.id, "Queued", 2, 1)

    assert {:ok, feedback} = OperationFeedback.queued(feedback, operation.id, "Queued", 1, 2)

    assert {:error, :invalid_progress_range} =
             OperationFeedback.report_progress(feedback, operation.id, 3, 2)

    assert {:ok, feedback} = OperationFeedback.report_progress(feedback, operation.id, 1, 2)
    assert OperationFeedback.selected(feedback).queue == %OperationQueue{position: 1, total: 2}

    assert OperationFeedback.selected(feedback).progress == %OperationProgress{
             current: 1,
             total: 2
           }

    feedback = OperationFeedback.running(feedback, operation.id, "Running")
    assert OperationFeedback.selected(feedback).queue == nil

    feedback = OperationFeedback.finish(feedback, operation.id, :success, "Done")
    refute OperationFeedback.selected(feedback).cancelable?
    assert OperationFeedback.selected(feedback).queue == nil
  end

  test "all semantic statuses are representable" do
    for status <- [:success, :error, :timeout, :canceled, :stale] do
      {feedback, operation} =
        OperationFeedback.start(OperationFeedback.new(), :lsp_references, "file", "Pending")

      feedback = OperationFeedback.finish(feedback, operation.id, status, Atom.to_string(status))
      assert OperationFeedback.selected(feedback).status == status
    end

    {feedback, operation} =
      OperationFeedback.start(OperationFeedback.new(), :lsp_references, "file", "Pending")

    assert OperationFeedback.selected(feedback).status == :pending
    assert {:ok, feedback} = OperationFeedback.queued(feedback, operation.id, "Queued", 1, 1)
    assert OperationFeedback.selected(feedback).status == :queued
    feedback = OperationFeedback.running(feedback, operation.id, "Running")
    assert OperationFeedback.selected(feedback).status == :running
  end
end
