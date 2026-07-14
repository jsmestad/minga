defmodule MingaEditor.Effects.OperationFeedbackTest do
  @moduledoc "Structured feedback translation tests for git effect handlers."

  use ExUnit.Case, async: true

  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effects.GitMutation
  alias MingaEditor.Effects.GitMutationAdmission
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.OperationFeedback

  test "GitMutation translates queued, running, canceled, and stale outcomes" do
    {state, operation} = start_operation(:git_stage, "Stage")

    request =
      GitMutation.request("/tmp/repo", :stage, operation.id,
        pending_message: "Staging...",
        success_message: "Staged",
        path: "file.ex"
      )

    {state, _outcome} = GitMutation.apply(state, Outcome.queued(request, 1, 2))
    assert feedback(state, operation.id).status == :queued
    assert feedback(state, operation.id).queue.position == 1

    {state, _outcome} = GitMutation.apply(state, Outcome.running(request))
    assert feedback(state, operation.id).status == :running
    assert feedback(state, operation.id).queue == nil

    {canceled_state, _outcome} = GitMutation.apply(state, Outcome.canceled(request, :requested))
    assert feedback(canceled_state, operation.id).status == :canceled
    refute feedback(canceled_state, operation.id).cancelable?

    {stale_state, stale_operation} = start_operation(:git_stage, "Stage")

    stale_request =
      GitMutation.request("/tmp/repo", :stage, stale_operation.id,
        pending_message: "Staging...",
        success_message: "Staged",
        path: "file.ex"
      )

    {stale_state, _outcome} =
      GitMutation.apply(stale_state, Outcome.stale(Outcome.completed(stale_request, nil), :late))

    assert feedback(stale_state, stale_operation.id).status == :stale
  end

  test "GitMutationAdmission translates lifecycle and resolution failures" do
    {state, operation} = start_operation(:git_commit, "Commit")

    request =
      GitMutationAdmission.request(self(), :commit, operation.id,
        pending_message: "Committing...",
        success_message: "Committed"
      )

    {state, _outcome} = GitMutationAdmission.apply(state, Outcome.queued(request, 2, 3))
    assert feedback(state, operation.id).status == :queued
    assert feedback(state, operation.id).queue.total == 3

    {state, _outcome} = GitMutationAdmission.apply(state, Outcome.running(request))
    assert feedback(state, operation.id).status == :running

    {state, _outcome} = GitMutationAdmission.apply(state, Outcome.failed(request, :not_git))
    assert feedback(state, operation.id).status == :error
    assert feedback(state, operation.id).message == "Not in a git repository"
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
