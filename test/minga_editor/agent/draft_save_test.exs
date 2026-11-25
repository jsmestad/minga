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

  test "a remote acknowledgement retires sent attachments without saving a newer draft at the old revision" do
    initial = {4, {0, 5}}
    newer = {5, {0, 8}}
    target = {self(), "original-draft"}

    original =
      target
      |> DraftSave.loading(self(), make_ref(), initial)
      |> DraftSave.loaded(1, initial, nil)

    attach_ref = make_ref()
    {:ok, token} = Reference.token("original-draft", String.duplicate("b", 32))
    revision = Reference.digest("context")
    artifact = %Reference{token: token, media_type: "text/plain", bytes: 7, sha256: revision}
    attachment = {:selection, "one.txt", "one.txt", revision, {:snapshot, artifact}}
    assert {:ok, 1, attaching} = DraftSave.begin_attachment(original, attach_ref, initial)
    assert {:ok, ready} = DraftSave.attached(attaching, attach_ref, 2, attachment)

    send_ref = make_ref()
    assert {:ok, pending} = DraftSave.begin_submission(ready, send_ref, initial, "submission-id")
    assert :pending = DraftSave.begin_save(pending, make_ref(), newer)
    assert {:error, "Wait" <> _} = DraftSave.submission(pending)
    assert :stale = DraftSave.submitted(pending, make_ref(), 3, nil)
    assert {:ok, uncertain} = DraftSave.failed(pending, send_ref, :unconfirmed)
    assert {:error, "Open Draft attachments" <> _} = DraftSave.submission(uncertain)
    assert :pending = DraftSave.begin_save(uncertain, make_ref(), newer)
    check_ref = make_ref()
    checking = DraftSave.check_submission(uncertain, target, check_ref)
    assert :stale = DraftSave.submitted(checking, send_ref, 3, nil)

    assert {:ok, accepted} = DraftSave.submitted(checking, check_ref, 3, nil)
    assert :ordinary = DraftSave.submission(accepted)
    assert {:ok, 3, _pending_save} = DraftSave.begin_save(accepted, make_ref(), newer)
  end

  describe "a queue pressed while the composer's own autosave is in flight" do
    @marker {0, {0, 3}}
    @deferred {{"record", "request", 1}, :follow_up, "later", {0, {0, 5}}}

    defp ready do
      target = {self(), "record"}

      target
      |> DraftSave.loading(self(), make_ref(), @marker)
      |> DraftSave.loaded(1, @marker, nil)
    end

    # One composer in each request tag a queue can meet.
    defp requests do
      ready = ready()
      {:ok, 1, saving} = DraftSave.begin_save(ready, make_ref(), {0, {0, 4}})
      {:ok, 1, recalling} = DraftSave.begin_recall(ready, make_ref(), {0, {0, 4}})
      {:ok, 1, attaching} = DraftSave.begin_attachment(ready, make_ref(), {0, {0, 4}})

      {:ok, 1, queueing} =
        DraftSave.begin_queue(ready, make_ref(), {0, {0, 4}}, {1, "t", :follow_up})

      %{
        ready: ready,
        saving: saving,
        recalling: recalling,
        attaching: attaching,
        queueing: queueing
      }
    end

    test "only an autosave holds the queue; every other request still refuses it" do
      for {tag, save} <- requests() do
        case {tag, DraftSave.defer_queue(save, @deferred)} do
          {:saving, {:ok, held}} ->
            assert held.deferred_queue == @deferred

          {:saving, other} ->
            flunk("an autosave must hold the queue, got #{inspect(other)}")

          {_tag, result} ->
            assert result == :pending, "#{tag} must refuse, got #{inspect(result)}"
        end
      end
    end

    test "the held queue runs when the save answers, and only then" do
      %{saving: saving} = requests()
      {:ok, held} = DraftSave.defer_queue(saving, @deferred)
      {:saving, ref, _, _, _} = held.request

      assert DraftSave.release_deferred_queue(held) == :none
      assert {:ok, saved} = DraftSave.saved(held, ref, 2)
      assert {:run, @deferred, released} = DraftSave.release_deferred_queue(saved)
      assert released.deferred_queue == nil
      assert DraftSave.release_deferred_queue(released) == :none
    end

    test "a save that leaves the composer unable to queue drops the held queue" do
      %{saving: saving} = requests()
      {:ok, held} = DraftSave.defer_queue(saving, @deferred)
      {:saving, ref, _, _, _} = held.request

      assert {:ok, blocked} = DraftSave.failed(held, ref, :blocked)
      assert {:drop, dropped} = DraftSave.release_deferred_queue(blocked)
      assert dropped.deferred_queue == nil

      assert {:ok, retried} = DraftSave.failed(held, ref, :retryable)
      assert {:run, @deferred, _} = DraftSave.release_deferred_queue(retried)
    end

    test "a later press replaces the held queue" do
      %{saving: saving} = requests()
      {:ok, held} = DraftSave.defer_queue(saving, @deferred)
      newer = put_elem(@deferred, 2, "later still")
      assert {:ok, %{deferred_queue: ^newer}} = DraftSave.defer_queue(held, newer)
    end
  end
end
