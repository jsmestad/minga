defmodule MingaEditor.Agent.DraftSaveTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Tool.Output.Reference
  alias MingaEditor.Agent.DraftSave

  test "an unconfirmed first snapshot blocks ordinary send until the same draft is read again" do
    marker = {0, {0, 0}}
    ref = make_ref()
    target = {self(), "original-draft"}

    draft =
      target |> DraftSave.loading(self(), make_ref(), marker) |> DraftSave.loaded(1, marker, nil)

    assert {:ok, 1, pending} = DraftSave.begin_attachment(draft, ref, marker)
    assert {:ok, unconfirmed} = DraftSave.failed(pending, ref, :blocked)
    assert {:error, "Reopen" <> _} = DraftSave.submission(unconfirmed)

    reload_ref = make_ref()
    reloading = DraftSave.review_attachments(unconfirmed, reload_ref)
    assert {:error, "Wait" <> _} = DraftSave.submission(reloading)
    assert :stale = DraftSave.failed(reloading, ref, :blocked)
    assert {:ok, unconfirmed} = DraftSave.failed(reloading, reload_ref, :retryable)
    assert {:error, "Reopen" <> _} = DraftSave.submission(unconfirmed)

    recovered = DraftSave.attachments_reviewed(reloading, 2, nil)
    assert :ordinary = DraftSave.submission(recovered)
    assert {:ok, 2, _save} = DraftSave.begin_save(recovered, make_ref(), marker)
  end

  test "a submit from the painted empty set cannot admit a snapshot acknowledged since that frame" do
    marker = {0, {0, 0}}
    target = {self(), "original-draft"}

    empty =
      target |> DraftSave.loading(self(), make_ref(), marker) |> DraftSave.loaded(1, marker, nil)

    old_offer = empty.offer
    ref = make_ref()
    {:ok, token} = Reference.token("original-draft", String.duplicate("a", 32))
    revision = Reference.digest("selected")
    artifact = %Reference{token: token, media_type: "text/plain", bytes: 8, sha256: revision}
    snapshot = {:selection, "note.ex", "note.ex", revision, {:snapshot, artifact}}

    assert :ordinary = DraftSave.submission(empty, old_offer)
    assert {:ok, 1, pending} = DraftSave.begin_attachment(empty, ref, marker)
    assert {:ok, current} = DraftSave.attached(pending, ref, 2, snapshot)

    assert {:error, "Draft attachments changed" <> _} = DraftSave.submission(current, old_offer)
    assert {:error, "Draft attachments changed" <> _} = DraftSave.submission(current, nil)

    assert {:attached, ^target, [{^token, ^revision}]} =
             DraftSave.submission(current, current.offer)

    remove_ref = make_ref()

    assert {:ok, 2, removing, []} =
             DraftSave.begin_removal(current, remove_ref, marker, {token, revision})

    assert {:ok, uncertain} = DraftSave.failed(removing, remove_ref, :blocked)
    assert {:error, "Reopen" <> _} = DraftSave.submission(uncertain, current.offer)

    recovered =
      uncertain
      |> DraftSave.review_attachments(make_ref())
      |> DraftSave.attachments_reviewed(3, nil)

    assert {:error, "Draft attachments changed" <> _} =
             DraftSave.submission(recovered, current.offer)

    assert :ordinary = DraftSave.submission(recovered, recovered.offer)
  end
end
