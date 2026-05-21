defmodule MingaEditor.State.WorkspaceReviewTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileRef
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.WorkspaceReview

  setup do
    {:ok, file_ref_a} = FileRef.from_path("/tmp/minga", "lib/a.ex")
    {:ok, file_ref_b} = FileRef.from_path("/tmp/minga", "lib/b.ex")
    %{file_ref_a: file_ref_a, file_ref_b: file_ref_b}
  end

  test "starts clean with no changed or conflict files" do
    review = WorkspaceReview.new()

    assert review.state == :clean
    assert review.changed_files == []
    assert review.conflict_files == []
    refute WorkspaceReview.pending?(review)
  end

  test "legal transition path covers draft, review, conflict, and clean", %{
    file_ref_a: file_ref_a
  } do
    review = WorkspaceReview.new()
    assert {:ok, review} = WorkspaceReview.agent_started_editing(review, [file_ref_a])
    assert review.state == :draft
    assert WorkspaceReview.draft_count(review) == 1

    assert {:ok, review} = WorkspaceReview.agent_made_more_edits(review, [file_ref_a])
    assert review.state == :draft

    assert {:ok, review} = WorkspaceReview.agent_completed(review, [file_ref_a])
    assert review.state == :needs_review

    assert {:ok, review} =
             WorkspaceReview.promote_found_overlaps(review, [file_ref_a], %{
               reason: :concurrent_edit
             })

    assert review.state == :conflict
    assert WorkspaceReview.conflict_count(review) == 1

    assert {:ok, review} =
             WorkspaceReview.promote_found_overlaps(review, [file_ref_a], %{
               reason: :still_conflicted
             })

    assert review.state == :conflict
    assert review.last_error == %{reason: :still_conflicted}

    assert {:ok, review} = WorkspaceReview.resolved_and_promoted(review)
    assert review.state == :clean
    assert review.changed_files == []
    assert review.conflict_files == []
  end

  test "discard_file keeps other conflicts and clears transient flags", %{
    file_ref_a: file_ref_a,
    file_ref_b: file_ref_b
  } do
    review = %WorkspaceReview{
      state: :conflict,
      changed_files: [file_ref_a, file_ref_b],
      conflict_files: [file_ref_a, file_ref_b],
      last_error: :boom,
      in_progress?: true
    }

    review = WorkspaceReview.discard_file(review, file_ref_a)

    assert review.state == :conflict
    assert review.changed_files == [file_ref_b]
    assert review.conflict_files == [file_ref_b]
    assert review.last_error == nil
    refute review.in_progress?
  end

  test "discard_file falls back from the last conflict to needs_review when drafts remain", %{
    file_ref_a: file_ref_a,
    file_ref_b: file_ref_b
  } do
    review = %WorkspaceReview{
      state: :conflict,
      changed_files: [file_ref_a, file_ref_b],
      conflict_files: [file_ref_a],
      last_error: :boom,
      in_progress?: true
    }

    review = WorkspaceReview.discard_file(review, file_ref_a)

    assert review.state == :needs_review
    assert review.changed_files == [file_ref_b]
    assert review.conflict_files == []
    assert review.last_error == nil
    refute review.in_progress?
  end

  test "discard_file keeps draft mode while other changed files remain", %{
    file_ref_a: file_ref_a,
    file_ref_b: file_ref_b
  } do
    review = %WorkspaceReview{
      state: :draft,
      changed_files: [file_ref_a, file_ref_b],
      conflict_files: [],
      last_error: :boom,
      in_progress?: true
    }

    review = WorkspaceReview.discard_file(review, file_ref_a)

    assert review.state == :draft
    assert review.changed_files == [file_ref_b]
    assert review.conflict_files == []
    assert review.last_error == nil
    refute review.in_progress?
  end

  test "discard_file returns clean when the last file is removed", %{file_ref_a: file_ref_a} do
    review = %WorkspaceReview{
      state: :draft,
      changed_files: [file_ref_a],
      conflict_files: [],
      last_error: :boom,
      in_progress?: true
    }

    review = WorkspaceReview.discard_file(review, file_ref_a)

    assert review.state == :clean
    assert review.changed_files == []
    assert review.conflict_files == []
    assert review.last_error == nil
    refute review.in_progress?
  end

  test "mark_needs_review records errors and counts as pending", %{file_ref_a: file_ref_a} do
    review = WorkspaceReview.mark_needs_review(WorkspaceReview.new(), [file_ref_a], :diff_failed)

    assert review.state == :needs_review
    assert review.changed_files == [file_ref_a]
    assert review.last_error == :diff_failed
    assert WorkspaceReview.pending?(review)
  end

  test "rejects at least one illegal transition per stable state", %{file_ref_a: file_ref_a} do
    assert {:error, {:invalid_transition, :clean, :conflict}} =
             WorkspaceReview.promote_found_overlaps(WorkspaceReview.new(), [file_ref_a], :boom)

    assert {:ok, draft} =
             WorkspaceReview.agent_started_editing(WorkspaceReview.new(), [file_ref_a])

    assert {:error, {:invalid_transition, :draft, :conflict}} =
             WorkspaceReview.promote_found_overlaps(draft, [file_ref_a], :boom)

    assert {:ok, needs_review} = WorkspaceReview.agent_completed(draft, [file_ref_a])

    assert {:error, {:invalid_transition, :needs_review, :needs_review}} =
             WorkspaceReview.agent_completed(needs_review, [file_ref_a])

    assert {:ok, conflict} =
             WorkspaceReview.promote_found_overlaps(needs_review, [file_ref_a], :boom)

    assert {:error, {:invalid_transition, :conflict, :needs_review}} =
             WorkspaceReview.agent_completed(conflict, [file_ref_a])
  end

  test "workspace owns review transitions", %{file_ref_a: file_ref_a} do
    workspace = Workspace.new_agent(1, "Agent")

    assert {:ok, workspace} =
             Workspace.transition_review(workspace, :agent_started_editing, [file_ref_a])

    assert workspace.review.state == :draft
    assert Workspace.review_pending?(workspace)
  end
end
