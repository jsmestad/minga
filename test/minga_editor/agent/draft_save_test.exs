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
    @deferred {:queue, {"record", "request", 1}, :follow_up, "later", "later", {0, {0, 5}}}
    @send {:send, :steering, "hello", "hello", {0, {0, 5}}}

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

      {:saving, save_ref, _, _, _} = saving.request
      {:ok, blocked} = DraftSave.failed(saving, save_ref, :blocked)
      {:attaching, attach_ref, _, _, _} = attaching.request
      {:ok, review_required} = DraftSave.failed(attaching, attach_ref, :blocked)
      loading = DraftSave.loading({self(), "record"}, self(), make_ref(), @marker)

      reloading_recall =
        DraftSave.reload_recall(%{blocked | request: :recall_conflicted}, make_ref(), @marker)

      retiring = DraftSave.retire_queue_receipt(saving, make_ref(), {1, "s", :follow_up, 1})

      %{
        ready: ready,
        saving: saving,
        recalling: recalling,
        attaching: attaching,
        queueing: queueing,
        loading: loading,
        reloading_recall: reloading_recall,
        blocked: blocked,
        attachment_review_required: review_required,
        saving_while_retiring: retiring
      }
    end

    test "a queue waits for an autosave or a load, a send only for a load; every other request refuses" do
      holds = %{queue: [:saving, :loading], send: [:loading]}

      for {tag, save} <- requests(), press <- [@deferred, @send] do
        expected = if tag in holds[elem(press, 0)], do: :hold, else: :refuse

        case {expected, DraftSave.hold_press(save, press)} do
          {:hold, {:ok, held}} ->
            assert held.held_press == press

          {:refuse, :pending} ->
            :ok

          {expected, got} ->
            flunk("#{tag} #{elem(press, 0)}: expected #{expected}, got #{inspect(got)}")
        end
      end
    end

    test "a press held behind a load runs when the load answers, and is dropped if it fails" do
      %{loading: loading} = requests()

      for press <- [@deferred, @send] do
        {:ok, held} = DraftSave.hold_press(loading, press)
        {:loading, ref, _} = held.request
        assert DraftSave.release_held_press(held) == :none

        loaded = DraftSave.loaded(held, 1, @marker, nil)
        assert {:run, ^press, %{held_press: nil}} = DraftSave.release_held_press(loaded)

        {:ok, failed} = DraftSave.failed(held, ref, :blocked)
        assert {:drop, %{held_press: nil}} = DraftSave.release_held_press(failed)
      end
    end

    test "a load issued again keeps the held press" do
      %{loading: loading} = requests()
      {:ok, held} = DraftSave.hold_press(loading, @send)
      reissued = DraftSave.loading({self(), "record"}, self(), make_ref(), @marker)
      assert DraftSave.keep_held(reissued, held).held_press == @send
      assert DraftSave.keep_held(reissued, nil).held_press == nil
    end

    test "the held queue runs when the save answers, and only then" do
      %{saving: saving} = requests()
      {:ok, held} = DraftSave.hold_press(saving, @deferred)
      {:saving, ref, _, _, _} = held.request

      assert DraftSave.release_held_press(held) == :none
      assert {:ok, saved} = DraftSave.saved(held, ref, 2)
      assert {:run, @deferred, released} = DraftSave.release_held_press(saved)
      assert released.held_press == nil
      assert DraftSave.release_held_press(released) == :none
    end

    test "a save that leaves the composer unable to queue drops the held queue" do
      %{saving: saving} = requests()
      {:ok, held} = DraftSave.hold_press(saving, @deferred)
      {:saving, ref, _, _, _} = held.request

      assert {:ok, blocked} = DraftSave.failed(held, ref, :blocked)
      assert {:drop, dropped} = DraftSave.release_held_press(blocked)
      assert dropped.held_press == nil

      assert {:ok, retried} = DraftSave.failed(held, ref, :retryable)
      assert {:run, @deferred, _} = DraftSave.release_held_press(retried)
    end

    test "a held queue whose save leaves a receipt retiring is dropped" do
      %{saving: saving} = requests()
      {:ok, held} = DraftSave.hold_press(saving, @deferred)
      {:saving, ref, _, _, _} = held.request
      {:ok, saved} = DraftSave.saved(held, ref, 2)
      retiring = DraftSave.retire_queue_receipt(saved, make_ref(), {1, "s", :follow_up, 1})

      assert {:drop, %{held_press: nil}} = DraftSave.release_held_press(retiring)
    end

    test "a later press replaces the held queue" do
      %{saving: saving} = requests()
      {:ok, held} = DraftSave.hold_press(saving, @deferred)
      newer = put_elem(@deferred, 3, "later still")
      assert {:ok, %{held_press: ^newer}} = DraftSave.hold_press(held, newer)
    end

    test "a queue that starts clears the held one" do
      %{saving: saving} = requests()
      {:ok, held} = DraftSave.hold_press(saving, @deferred)
      {:saving, ref, _, _, _} = held.request
      {:ok, saved} = DraftSave.saved(held, ref, 2)

      assert {:ok, 2, queueing} =
               DraftSave.begin_queue(saved, make_ref(), {0, {0, 6}}, {1, "t", :follow_up})

      assert queueing.held_press == nil
    end

    test "a save moved to a replacement writer keeps the hold for release" do
      %{saving: saving} = requests()
      {:ok, held} = DraftSave.hold_press(saving, @deferred)
      replacement = spawn(fn -> :ok end)

      rebound = DraftSave.rebind_writer(held, replacement)
      assert {:run, @deferred, _} = DraftSave.release_held_press(rebound)
    end
  end
end
