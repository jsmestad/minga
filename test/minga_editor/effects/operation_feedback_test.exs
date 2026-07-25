defmodule MingaEditor.Effects.OperationFeedbackTest do
  @moduledoc "Structured feedback translation tests for git effect handlers."

  use ExUnit.Case, async: true

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effects.ExternalFormat
  alias MingaEditor.Effects.GitMutation
  alias MingaEditor.Effects.GitMutationAdmission
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.OperationFeedback

  test "ExternalFormat translates queued and running lifecycle feedback" do
    {state, operation} = start_operation(:external_format, "Format")
    request = ExternalFormat.request(self(), "cat", operation.id)

    {state, _outcome} = ExternalFormat.apply(state, Outcome.queued(request, 1, 2))
    operation = feedback(state, operation.id)
    assert operation.status == :queued
    assert operation.message == "Format queued"
    assert operation.queue.position == 1
    assert operation.queue.total == 2

    {state, _outcome} = ExternalFormat.apply(state, Outcome.running(request))
    operation = feedback(state, operation.id)
    assert operation.status == :running
    assert operation.message == "Formatting…"
    assert operation.queue == nil
  end

  test "GitMutation translates queued and running lifecycle feedback" do
    {state, operation} = start_operation(:git_stage, "Stage")
    request = git_mutation_request(operation)

    {state, _outcome} = GitMutation.apply(state, Outcome.queued(request, 1, 2))
    operation = feedback(state, operation.id)
    assert operation.status == :queued
    assert operation.message == "Queued: Staging..."
    assert operation.queue.position == 1
    assert operation.queue.total == 2

    {state, _outcome} = GitMutation.apply(state, Outcome.running(request))
    operation = feedback(state, operation.id)
    assert operation.status == :running
    assert operation.message == "Staging..."
    assert operation.queue == nil
  end

  test "GitMutation translates terminal feedback without changing domain messages" do
    terminal_outcomes = [
      {fn request -> Outcome.canceled(request, :requested) end, :canceled, "Git action canceled"},
      {fn request -> Outcome.canceled(request, :superseded) end, :stale, "Git action skipped"},
      {fn request -> Outcome.canceled(request, :coalesced) end, :stale, "Git action skipped"},
      {fn request -> Outcome.stale(Outcome.completed(request, nil), :late) end, :stale,
       "Git action skipped"},
      {fn request -> Outcome.failed(request, :timeout) end, :timeout, "Git action timed out"}
    ]

    for {outcome, status, message} <- terminal_outcomes do
      {state, operation} = start_operation(:git_stage, "Stage")
      request = git_mutation_request(operation)

      {state, _outcome} = GitMutation.apply(state, outcome.(request))
      operation = feedback(state, operation.id)
      assert operation.status == status
      assert operation.message == message
      refute operation.cancelable?
    end
  end

  test "GitMutationAdmission translates queued and running lifecycle feedback" do
    {state, operation} = start_operation(:git_commit, "Commit")
    request = admission_request(operation)

    {state, _outcome} = GitMutationAdmission.apply(state, Outcome.queued(request, 2, 3))
    operation = feedback(state, operation.id)
    assert operation.status == :queued
    assert operation.message == "Queued: Committing..."
    assert operation.queue.position == 2
    assert operation.queue.total == 3

    {state, _outcome} = GitMutationAdmission.apply(state, Outcome.running(request))
    operation = feedback(state, operation.id)
    assert operation.status == :running
    assert operation.message == "Committing..."
    assert operation.queue == nil
  end

  test "GitMutationAdmission translates resolution terminal feedback" do
    terminal_outcomes = [
      {fn request -> Outcome.failed(request, :not_git) end, :error, "Not in a git repository"},
      {fn request -> Outcome.failed(request, :timeout) end, :timeout,
       "Git repository resolution timed out"},
      {fn request -> Outcome.failed(request, {:resolution_failed, :enoent}) end, :error,
       "Git repository resolution failed: {:resolution_failed, :enoent}"},
      {fn request -> Outcome.canceled(request, :requested) end, :canceled, "Git action canceled"},
      {fn request -> Outcome.stale(Outcome.completed(request, nil), :late) end, :stale,
       "Git action skipped"}
    ]

    for {outcome, status, message} <- terminal_outcomes do
      {state, operation} = start_operation(:git_commit, "Commit")
      request = admission_request(operation)

      {state, _outcome} = GitMutationAdmission.apply(state, outcome.(request))
      operation = feedback(state, operation.id)
      assert operation.status == status
      assert operation.message == message
      refute operation.cancelable?
    end
  end

  defp git_mutation_request(operation) do
    GitMutation.request("/tmp/repo", :stage, operation.id,
      pending_message: "Staging...",
      success_message: "Staged",
      path: "file.ex"
    )
  end

  defp admission_request(operation) do
    GitMutationAdmission.request(self(), :commit, operation.id,
      pending_message: "Committing...",
      success_message: "Committed"
    )
  end

  @spec start_operation(MingaEditor.State.Operation.kind(), String.t()) ::
          {MingaEditor.State.t(), MingaEditor.State.Operation.t()}
  defp start_operation(kind, message) do
    state = TestHelpers.base_state()

    {operation_feedback, operation} =
      OperationFeedback.start(
        state.feedback.operation_feedback,
        kind,
        Atom.to_string(kind),
        message
      )

    {%{state | feedback: Feedback.accept_operation_feedback(state.feedback, operation_feedback)},
     operation}
  end

  @spec feedback(MingaEditor.State.t(), pos_integer()) :: MingaEditor.State.Operation.t()
  defp feedback(state, operation_id) do
    {:ok, operation} = OperationFeedback.fetch(state.feedback.operation_feedback, operation_id)
    operation
  end
end
