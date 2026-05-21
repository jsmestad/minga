defmodule MingaEditor.State.WorkspaceReviewTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileRef
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.WorkspaceReview

  setup do
    {:ok, file_ref} = FileRef.from_path("/tmp/minga", "lib/a.ex")
    %{file_ref: file_ref}
  end

  test "starts clean with no changed or conflict files" do
    review = WorkspaceReview.new()

    assert review.state == :clean
    assert review.changed_files == []
    assert review.conflict_files == []
    refute WorkspaceReview.pending?(review)
  end

  test "legal transition path covers draft, review, conflict, and clean", %{file_ref: file_ref} do
    review = WorkspaceReview.new()
    assert {:ok, review} = WorkspaceReview.agent_started_editing(review, [file_ref])
    assert review.state == :draft
    assert WorkspaceReview.draft_count(review) == 1

    assert {:ok, review} = WorkspaceReview.agent_made_more_edits(review, [file_ref])
    assert review.state == :draft

    assert {:ok, review} = WorkspaceReview.agent_completed(review, [file_ref])
    assert review.state == :needs_review

    assert {:ok, review} =
             WorkspaceReview.promote_found_overlaps(review, [file_ref], %{
               reason: :concurrent_edit
             })

    assert review.state == :conflict
    assert WorkspaceReview.conflict_count(review) == 1

    assert {:ok, review} =
             WorkspaceReview.promote_found_overlaps(review, [file_ref], %{
               reason: :still_conflicted
             })

    assert review.state == :conflict
    assert review.last_error == %{reason: :still_conflicted}

    assert {:ok, review} = WorkspaceReview.resolved_and_promoted(review)
    assert review.state == :clean
    assert review.changed_files == []
    assert review.conflict_files == []
  end

  test "discard transitions draft, needs_review, and conflict to clean", %{file_ref: file_ref} do
    assert {:ok, draft} = WorkspaceReview.agent_started_editing(WorkspaceReview.new(), [file_ref])
    assert {:ok, clean} = WorkspaceReview.discard(draft)
    assert clean.state == :clean

    assert {:ok, needs_review} = WorkspaceReview.agent_completed(draft, [file_ref])
    assert {:ok, clean} = WorkspaceReview.discard(needs_review)
    assert clean.state == :clean

    assert {:ok, conflict} =
             WorkspaceReview.promote_found_overlaps(needs_review, [file_ref], :boom)

    assert {:ok, clean} = WorkspaceReview.discard(conflict)
    assert clean.state == :clean
  end

  test "rejects at least one illegal transition per stable state", %{file_ref: file_ref} do
    assert {:error, {:invalid_transition, :clean, :conflict}} =
             WorkspaceReview.promote_found_overlaps(WorkspaceReview.new(), [file_ref], :boom)

    assert {:ok, draft} = WorkspaceReview.agent_started_editing(WorkspaceReview.new(), [file_ref])

    assert {:error, {:invalid_transition, :draft, :conflict}} =
             WorkspaceReview.promote_found_overlaps(draft, [file_ref], :boom)

    assert {:ok, needs_review} = WorkspaceReview.agent_completed(draft, [file_ref])

    assert {:error, {:invalid_transition, :needs_review, :needs_review}} =
             WorkspaceReview.agent_completed(needs_review, [file_ref])

    assert {:ok, conflict} =
             WorkspaceReview.promote_found_overlaps(needs_review, [file_ref], :boom)

    assert {:error, {:invalid_transition, :conflict, :needs_review}} =
             WorkspaceReview.agent_completed(conflict, [file_ref])
  end

  test "workspace owns review transitions", %{file_ref: file_ref} do
    workspace = Workspace.new_agent(1, "Agent")

    assert {:ok, workspace} =
             Workspace.transition_review(workspace, :agent_started_editing, [file_ref])

    assert workspace.review.state == :draft
    assert Workspace.review_pending?(workspace)
  end
end
