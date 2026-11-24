defmodule Minga.Editing.Completion.SessionTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Completion
  alias Minga.Editing.Completion.Item
  alias Minga.Editing.Completion.ProviderBatch
  alias Minga.Editing.Completion.Session
  alias Minga.Test.CallCounter

  defp new_session(generation \\ 1) do
    Session.new(make_ref(), generation, self(), 7, {3, 5})
  end

  defp register(session, provider_id, client \\ self()) do
    ref = make_ref()
    {Session.register_requests(session, [{provider_id, client, ref}]), ref}
  end

  defp batch(session, provider_id, client, ref, items, incomplete \\ false) do
    ProviderBatch.from_response(
      session.id,
      session.generation,
      provider_id,
      client,
      ref,
      %{"isIncomplete" => incomplete, "items" => items}
    )
  end

  test "accepted items carry the origin of the request that produced them" do
    session = new_session()
    old_ref = make_ref()
    origin = {{3, 7}, "   han(1)"}
    session = Session.register_requests(session, [{:lsp, self(), old_ref}], origin)

    {:ok, session} =
      Session.accept_batch(
        session,
        batch(session, :lsp, self(), old_ref, [%{"label" => "a"}], true)
      )

    assert [%Item{request_origin: ^origin}] = Session.items(session)

    # A retrigger records the new origin only for the new request's batch.
    new_ref = make_ref()
    new_origin = {{3, 8}, "   hand(1)"}
    session = Session.retrigger(session, 2, 8, [{:lsp, self(), new_ref}], new_origin)
    assert [%Item{request_origin: ^origin}] = Session.items(session)

    {:ok, session} =
      Session.accept_batch(session, batch(session, :lsp, self(), new_ref, [%{"label" => "b"}]))

    assert [%Item{label: "b", request_origin: ^new_origin}] = Session.items(session)
    assert session.request_origins == %{}
  end

  test "stable item IDs include provider and semantic edit identity without truncation" do
    raw = %{
      "label" => "same",
      "insertText" => "alpha",
      "data" => %{"opaque" => String.duplicate("x", 200)}
    }

    first = Item.from_lsp(:provider_a, raw)
    repeated = Item.from_lsp(:provider_a, raw)
    other_provider = Item.from_lsp(:provider_b, raw)
    other_edit = Item.from_lsp(:provider_a, %{raw | "insertText" => "beta"})

    assert first.id == repeated.id
    refute first.id == other_provider.id
    refute first.id == other_edit.id
    assert inspect(first.id) =~ String.duplicate("x", 200)
  end

  test "late and cancellation-ignoring responses cannot enter the session" do
    provider = :primary
    session = new_session()
    {session, request_ref} = register(session, provider)
    current = batch(session, provider, self(), request_ref, [%{"label" => "current"}])

    stale_ref = batch(session, provider, self(), make_ref(), [%{"label" => "stale-ref"}])

    stale_session = %ProviderBatch{
      current
      | session_id: make_ref(),
        items: [Item.from_lsp(provider, %{"label" => "stale-session"})]
    }

    assert Session.accept_batch(session, stale_ref) == :stale
    assert Session.accept_batch(session, stale_session) == :stale
    assert {:ok, accepted} = Session.accept_batch(session, current)
    assert Enum.map(Session.items(accepted), & &1.label) == ["current"]

    {dismissed, _requests, _timers} = Session.teardown(session)
    assert Session.accept_batch(dismissed, current) == :stale
  end

  test "incomplete retrigger keeps complete batches reusable and rejects the old generation" do
    complete_provider = :complete
    incomplete_provider = :incomplete
    session = new_session()
    {session, complete_ref} = register(session, complete_provider)
    {session, incomplete_ref} = register(session, incomplete_provider)

    assert {:ok, session} =
             Session.accept_batch(
               session,
               batch(
                 session,
                 complete_provider,
                 self(),
                 complete_ref,
                 [%{"label" => "kept"}]
               )
             )

    old_incomplete =
      batch(
        session,
        incomplete_provider,
        self(),
        incomplete_ref,
        [%{"label" => "old"}],
        true
      )

    assert {:ok, session} = Session.accept_batch(session, old_incomplete)
    assert Session.incomplete_providers(session) == [{incomplete_provider, self()}]

    new_ref = make_ref()
    retriggered = Session.retrigger(session, 2, 8, [{incomplete_provider, self(), new_ref}])

    assert Enum.map(Session.items(retriggered), & &1.label) == ["kept", "old"]
    assert Session.accept_batch(retriggered, old_incomplete) == :stale

    refreshed =
      batch(
        retriggered,
        incomplete_provider,
        self(),
        new_ref,
        [%{"label" => "new"}],
        false
      )

    assert {:ok, refreshed_session} = Session.accept_batch(retriggered, refreshed)
    assert Enum.map(Session.items(refreshed_session), & &1.label) == ["kept", "new"]
  end

  test "selection remains attached to the same item across provider merges" do
    session = new_session()
    {session, primary_ref} = register(session, :primary)

    assert {:ok, session} =
             Session.accept_batch(
               session,
               batch(
                 session,
                 :primary,
                 self(),
                 primary_ref,
                 [%{"label" => "b"}, %{"label" => "d"}]
               )
             )

    selected = Enum.find(Session.items(session), &(&1.label == "d"))
    session = Session.select(session, selected.id)
    {session, secondary_ref} = register(session, :secondary)

    assert {:ok, merged} =
             Session.accept_batch(
               session,
               batch(
                 session,
                 :secondary,
                 self(),
                 secondary_ref,
                 [%{"label" => "a"}]
               )
             )

    assert merged.selected_item_id == selected.id
    assert merged.selection_origin == :user
    assert Session.find_item(merged, selected.id).label == "d"
  end

  test "a higher-ranked item from a later provider replaces the automatic default" do
    session = new_session()
    {session, first_ref} = register(session, :first)

    assert {:ok, session} =
             Session.accept_batch(
               session,
               batch(session, :first, self(), first_ref, [%{"label" => "zulu"}])
             )

    assert Session.find_item(session, session.selected_item_id).label == "zulu"
    assert session.selection_origin == :automatic
    {session, second_ref} = register(session, :second)

    assert {:ok, merged} =
             Session.accept_batch(
               session,
               batch(session, :second, self(), second_ref, [%{"label" => "alpha"}])
             )

    assert Session.find_item(merged, merged.selected_item_id).label == "alpha"
    assert merged.selection_origin == :automatic
  end

  test "a preselected item from a later provider replaces the automatic default" do
    session = new_session()
    {session, first_ref} = register(session, :first)

    assert {:ok, session} =
             Session.accept_batch(
               session,
               batch(session, :first, self(), first_ref, [%{"label" => "alpha"}])
             )

    {session, second_ref} = register(session, :second)

    assert {:ok, merged} =
             Session.accept_batch(
               session,
               batch(session, :second, self(), second_ref, [
                 %{"label" => "zulu", "preselect" => true}
               ])
             )

    assert Session.find_item(merged, merged.selected_item_id).label == "zulu"
    assert merged.selection_origin == :automatic
  end

  test "later provider ranking cannot replace an explicit user selection" do
    session = new_session()
    {session, first_ref} = register(session, :first)

    assert {:ok, session} =
             Session.accept_batch(
               session,
               batch(session, :first, self(), first_ref, [
                 %{"label" => "alpha"},
                 %{"label" => "charlie"}
               ])
             )

    selected = Enum.find(Session.items(session), &(&1.label == "charlie"))
    session = Session.select(session, selected.id)
    assert session.selection_origin == :user
    {session, second_ref} = register(session, :second)

    assert {:ok, merged} =
             Session.accept_batch(
               session,
               batch(session, :second, self(), second_ref, [
                 %{"label" => "bravo", "preselect" => true}
               ])
             )

    assert merged.selected_item_id == selected.id
    assert Session.find_item(merged, merged.selected_item_id).label == "charlie"
    assert merged.selection_origin == :user
  end

  test "resolve requires the exact selected session provider item and request identity" do
    session = new_session()
    {session, request_ref} = register(session, :provider)

    assert {:ok, session} =
             Session.accept_batch(
               session,
               batch(session, :provider, self(), request_ref, [%{"label" => "item"}])
             )

    item = hd(Session.items(session))
    identity = {session.id, :provider, item.id}
    assert {:ok, session} = Session.begin_resolve(session, item.id, self(), nil)
    resolve_ref = make_ref()
    assert {:ok, session} = Session.track_resolve(session, identity, resolve_ref)

    assert Session.resolve_item(session, identity, make_ref(), "stale") == :stale
    assert Session.fail_resolve(session, identity, make_ref()) == :stale

    assert {:ok, resolved} = Session.resolve_item(session, identity, resolve_ref, "docs")
    assert Session.find_item(resolved, item.id).documentation == "docs"
    assert resolved.resolve == nil

    assert {:ok, failed} = Session.fail_resolve(session, identity, resolve_ref)
    assert failed.resolve == nil
  end

  test "teardown clears timers, requests, resolve ownership, and previewed selection" do
    resolve_timer = Process.send_after(self(), :resolve, 60_000)
    session = new_session()
    {session, provider_ref} = register(session, :provider)

    assert {:ok, session} =
             Session.accept_batch(
               session,
               batch(session, :provider, self(), provider_ref, [%{"label" => "item"}])
             )

    item = hd(Session.items(session))
    session = session |> Session.select(item.id) |> Session.preview(item.id)
    assert {:ok, session} = Session.begin_resolve(session, item.id, self(), resolve_timer)
    resolve_ref = make_ref()
    identity = {session.id, :provider, item.id}
    assert {:ok, session} = Session.track_resolve(session, identity, resolve_ref)

    {dismissed, requests, timers} = Session.teardown(session)

    assert dismissed.dismissed?
    assert dismissed.provider_requests == %{}
    assert dismissed.batches == %{}
    assert dismissed.selected_item_id == nil
    assert dismissed.previewed_item_id == nil
    assert dismissed.resolve == nil
    assert dismissed.debounce_timer == nil
    assert requests == [{self(), resolve_ref}]
    assert timers == []

    assert {:ok, pending_resolve} = Session.begin_resolve(session, item.id, self(), resolve_timer)
    {_dismissed, _requests, timers} = Session.teardown(pending_resolve)
    assert timers == [resolve_timer]

    Process.cancel_timer(resolve_timer)
  end

  test "parsing hashes each item once; installing, filtering and selecting hash nothing" do
    raw_items =
      for n <- 1..300 do
        %{"label" => "handle_#{n}", "sortText" => String.pad_leading("#{n}", 4, "0")}
      end

    client = self()
    session = new_session()
    {session, ref} = register(session, :lsp, client)

    # Parsing runs in the completion Task in production; CallCounter runs each step in its own process.
    {parse_hashes, batch} =
      CallCounter.count({:crypto, :hash, 2}, fn ->
        batch(session, :lsp, client, ref, raw_items)
      end)

    {editor_hashes, completion} =
      CallCounter.count({:crypto, :hash, 2}, fn ->
        {:ok, session} = Session.accept_batch(session, batch)

        completion =
          session
          |> Session.index()
          |> Completion.new({3, 5}, session.selected_item_id)
          |> Completion.filter("h")
          |> Completion.filter("handle_1")
          |> Completion.move_down()

        third = Enum.at(completion.filtered, 2)
        {:ok, completion} = Completion.select_wire_id(completion, Item.wire_id(third))
        completion
      end)

    assert {parse_hashes, editor_hashes} == {300, 0}

    # The carried wire ids are the identity hashes, so ranking and selection are unchanged.
    assert Enum.map(completion.filtered, &Item.wire_id/1) ==
             Enum.map(completion.filtered, &Item.wire_id(&1.id))

    assert Enum.take(Enum.map(completion.filtered, & &1.label), 3) ==
             ["handle_1", "handle_10", "handle_11"]

    assert Completion.selected_item(completion).label == "handle_11"
  end
end
