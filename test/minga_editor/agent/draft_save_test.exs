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

  describe "presses the draft cannot take yet" do
    @marker {0, {0, 3}}
    @receipt {1, "s", :follow_up, 1}

    defp queue_press(text),
      do: {:queue, {"record", "request", 1}, :follow_up, text, {text, text, {0, {0, 5}}}}

    defp send_press(text), do: {:send, :steering, text, {text, text, {0, {0, 5}}}}

    defp ready do
      target = {self(), "record"}

      target
      |> DraftSave.loading(self(), make_ref(), @marker)
      |> DraftSave.loaded(1, @marker, nil)
    end

    defp queueing(raw) do
      {:ok, 1, queueing} =
        DraftSave.begin_queue(ready(), make_ref(), {0, {0, 4}}, {1, "t", :follow_up}, raw)

      queueing
    end

    # One composer in each request tag a press can meet.
    defp requests do
      ready = ready()
      {:ok, 1, saving} = DraftSave.begin_save(ready, make_ref(), {0, {0, 4}})
      {:ok, 1, recalling} = DraftSave.begin_recall(ready, make_ref(), {0, {0, 4}})
      {:ok, 1, attaching} = DraftSave.begin_attachment(ready, make_ref(), {0, {0, 4}})
      {:saving, save_ref, _, _, _} = saving.request
      {:ok, blocked} = DraftSave.failed(saving, save_ref, :blocked)
      {:attaching, attach_ref, _, _, _} = attaching.request
      {:ok, review_required} = DraftSave.failed(attaching, attach_ref, :blocked)
      loading = DraftSave.loading({self(), "record"}, self(), make_ref(), @marker)

      reloading_recall =
        DraftSave.reload_recall(%{blocked | request: :recall_conflicted}, make_ref(), @marker)

      %{
        ready: ready,
        retiring: DraftSave.retire_queue_receipt(ready, make_ref(), @receipt),
        saving: saving,
        queueing: queueing("earlier"),
        loading: loading,
        recalling: recalling,
        attaching: attaching,
        reloading_recall: reloading_recall,
        blocked: blocked,
        attachment_review_required: review_required
      }
    end

    test "a queue waits while the draft saves, loads, answers a queue or retires its receipt; a send only for a load" do
      holds = %{
        queue: [:saving, :loading, :queueing, :retiring],
        send: [:loading]
      }

      for {tag, save} <- requests(), press <- [queue_press("p"), send_press("p")] do
        expected = if tag in holds[elem(press, 0)], do: :hold, else: :refuse

        case {expected, DraftSave.hold_press(save, press)} do
          {:hold, {:ok, held}} ->
            assert held.held_presses == [press]

          {:refuse, :pending} ->
            :ok

          {expected, got} ->
            flunk("#{tag} #{elem(press, 0)}: expected #{expected}, got #{inspect(got)}")
        end
      end
    end

    test "presses wait in order and run one at a time, first pressed first" do
      {:ok, one} = DraftSave.hold_press(queueing("first"), queue_press("second"))
      {:ok, two} = DraftSave.hold_press(one, queue_press("third"))
      assert two.held_presses == [queue_press("second"), queue_press("third")]

      {:queueing, ref, _, _, _, _} = two.request
      answered = DraftSave.queue_saved(two, ref, 2, nil)

      assert {:run, press, rest} = DraftSave.release_held_press(answered)
      assert press == queue_press("second")
      assert rest.held_presses == [queue_press("third")]
    end

    test "nothing runs while the draft is busy; a ready draft runs the first; an unusable one drops them all" do
      for busy <- [:saving, :loading, :queueing, :retiring] do
        {:ok, held} = DraftSave.hold_press(requests()[busy], queue_press("p"))
        assert DraftSave.release_held_press(held) == :none, "#{busy} must keep holding"
      end

      %{loading: loading} = requests()
      {:ok, held} = DraftSave.hold_press(loading, send_press("p"))
      {:loading, ref, _marker} = held.request

      assert {:run, _, %{held_presses: []}} =
               held |> DraftSave.loaded(1, @marker, nil) |> DraftSave.release_held_press()

      {:ok, failed} = DraftSave.failed(held, ref, :blocked)
      assert {:drop, %{held_presses: []}} = DraftSave.release_held_press(failed)
    end

    test "a press takes only the text no earlier press has taken" do
      {:ok, held} = DraftSave.hold_press(queueing("alpha"), queue_press("bravo"))

      assert DraftSave.submitted(held) == ["alpha", "bravo"]
      assert DraftSave.unsubmitted(held, "alphabravocharlie") == "charlie"
      assert DraftSave.unsubmitted(held, "alphabravo") == ""
      # Text that was already pressed but has since been edited is taken whole.
      assert DraftSave.unsubmitted(held, "alpXhabravo") == "alpXhabravo"
      assert DraftSave.unsubmitted(ready(), "plain") == "plain"
      assert DraftSave.unsubmitted(nil, "plain") == "plain"
    end

    test "a load issued again keeps the held presses" do
      %{loading: loading} = requests()
      {:ok, held} = DraftSave.hold_press(loading, send_press("p"))
      reissued = DraftSave.loading({self(), "record"}, self(), make_ref(), @marker)
      assert DraftSave.keep_held(reissued, held).held_presses == [send_press("p")]
      assert DraftSave.keep_held(reissued, nil).held_presses == []
    end

    test "a save moved to a replacement writer leaves its presses ready to run" do
      %{saving: saving} = requests()
      {:ok, held} = DraftSave.hold_press(saving, queue_press("p"))
      rebound = DraftSave.rebind_writer(held, spawn(fn -> :ok end))
      assert {:run, _, _} = DraftSave.release_held_press(rebound)
    end
  end
end
