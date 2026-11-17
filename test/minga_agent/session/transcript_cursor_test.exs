defmodule MingaAgent.Session.TranscriptCursorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaAgent.Branch
  alias MingaAgent.Session.Transcript
  alias MingaAgent.Session.Transcript.Active
  alias MingaAgent.Session.Transcript.Changes
  alias MingaAgent.Session.Transcript.Cursor
  alias MingaAgent.Session.Transcript.Entry
  alias MingaAgent.Session.Transcript.Snapshot
  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.ToolCall
  alias MingaAgent.TurnUsage

  @now ~U[2026-11-15 12:00:00Z]
  @later ~U[2026-11-15 12:01:00Z]

  test "snapshot and coalesced changes reconstruct current order without unchanged history" do
    source = new([{:user, "old"}, {:assistant, "unchanged"}])
    assert {:snapshot, %Snapshot{} = snapshot} = Transcript.since(source, :snapshot)
    assert pairs(snapshot.entries) == Transcript.messages_with_ids(source)
    assert snapshot.count == 2
    assert snapshot.next_id == 3
    assert {:unchanged, cursor} = Transcript.since(source, snapshot.cursor)
    assert cursor == snapshot.cursor

    next =
      source
      |> Transcript.update_at(0, fn _ -> {:user, "revised"} end)
      |> Transcript.append_many([{:thinking, "reason", false}, {:assistant, "a"}])
      |> Transcript.append_stream_tail(:assistant, ["b", "c"])
      |> Transcript.append_stream_tail(:assistant, ["d"])

    assert {:changes, %Changes{} = changes} = Transcript.since(next, cursor)

    assert pairs(changes.entries) == [
             {1, {:user, "revised"}},
             {3, {:thinking, "reason", false}},
             {4, {:assistant, "abcd"}}
           ]

    assert Enum.map(changes.entries, & &1.ordinal) == [0, 2, 3]
    assert [revised, appended, streamed] = changes.entries
    assert revised.created_revision == 0
    assert appended.created_revision > source.revision
    assert streamed.created_revision == appended.created_revision
    assert streamed.content_revision == next.revision
    assert changes.count == 4
    assert changes.next_id == 5
    refute changes.pins_changed?
    refute changes.usage_changed?
    refute changes.timestamp_changed?
    assert {:unchanged, _} = Transcript.since(next, changes.cursor)
    assert Active.change_count(next.active) == 4
  end

  test "tool occurrences update in source order, coalesce, and maintain changed lookup keys" do
    tool = %ToolCall{id: "duplicate", name: "shell"}

    source =
      new([{:tool_call, tool}, {:user, "untouched"}, {:tool_call, tool}, {:assistant, "tail"}])

    cursor = Transcript.cursor(source)

    next =
      source
      |> Transcript.update_tool_call("duplicate", &ToolCall.update_partial(&1, "first"))
      |> Transcript.update_tool_call("duplicate", &ToolCall.update_partial(&1, "second"))
      |> Transcript.update_tool_call("duplicate", &ToolCall.complete(&1, "complete"))

    assert {:changes, changes} = Transcript.since(next, cursor)
    assert Enum.map(changes.entries, & &1.ordinal) == [0, 2]

    assert Enum.all?(changes.entries, fn %Entry{message: {:tool_call, tc}} ->
             tc.result == "complete" and tc.status == :complete
           end)

    assert Enum.map(changes.entries, & &1.change_revision) == [3, 3]
    assert Active.change_count(next.active) == 4

    # Changing a tool ID and changing a non-tool into a tool both reform lookups.
    next = Transcript.update_at(next, 0, fn _ -> {:user, "no longer a tool"} end)
    renamed = %ToolCall{id: "renamed", name: "shell"}
    next = Transcript.update_at(next, 1, fn _ -> {:tool_call, renamed} end)

    next =
      Transcript.update_tool_call(next, "duplicate", &ToolCall.update_partial(&1, "only last"))

    next =
      Transcript.update_tool_call(next, "renamed", &ToolCall.update_partial(&1, "new lookup"))

    assert [
             {:user, "no longer a tool"},
             {:tool_call, %{result: "new lookup"}},
             {:tool_call, %{result: "only last"}},
             {:assistant, "tail"}
           ] = Transcript.messages(next)
  end

  test "preview and collapse facts remain distinct from content revisions" do
    tool = %ToolCall{id: "tool", name: "shell"}
    source = new([{:tool_call, tool}, {:thinking, "reason", false}, {:assistant, "tail"}])
    next = Transcript.update_tool_call(source, "tool", &ToolCall.update_partial(&1, "text"))
    text_revision = next.revision
    cursor = Transcript.cursor(next)
    preview = Preview.new(:command, "command", ["$ echo text"])

    next =
      next
      |> Transcript.update_tool_call("tool", &ToolCall.set_preview(&1, preview))
      |> Transcript.toggle_message_collapse(1)
      |> Transcript.collapse_thinking()

    assert {:changes, changes} = Transcript.since(next, cursor)
    assert [tool_entry, thinking_entry] = changes.entries
    assert tool_entry.content_revision == text_revision
    assert tool_entry.change_revision > text_revision
    assert thinking_entry.content_revision == 0
    assert thinking_entry.change_revision == next.revision
  end

  test "no-ops leave cursors and content facts unchanged, including missing and negative indexes" do
    source = new([{:assistant, "text"}])

    for transition <- [
          &Transcript.append_many(&1, []),
          &Transcript.append_stream_tail(&1, :assistant, []),
          &Transcript.update_at(&1, 0, fn message -> message end),
          &Transcript.update_at(&1, 99, fn _ -> flunk("missing index transformed") end),
          &Transcript.update_at(&1, -2, fn _ -> flunk("missing negative index transformed") end),
          &Transcript.update_tool_call(&1, "missing", fn _ ->
            flunk("missing tool transformed")
          end),
          &Transcript.transform_messages(&1, fn message -> message end),
          &Transcript.compact(&1, [1]),
          &Transcript.collapse_thinking/1,
          &Transcript.add_usage(&1, TurnUsage.new()),
          &Transcript.touch(&1, @now)
        ] do
      next = transition.(source)
      assert next == source
      assert {:unchanged, _} = Transcript.since(next, Transcript.cursor(source))
    end

    next = Transcript.update_at(source, -1, fn _ -> {:assistant, "changed"} end)

    assert {:changes, %{entries: [%Entry{id: 1, ordinal: 0}]}} =
             Transcript.since(next, Transcript.cursor(source))

    assert Transcript.last_message(new([])) == nil
  end

  test "pins, unpins, usage and publication time have exact independent change facts" do
    source = new([{:user, "one"}])
    cursor = Transcript.cursor(source)
    pinned = Transcript.toggle_pin(source, 1)
    assert {:changes, pins} = Transcript.since(pinned, cursor)
    assert pins.entries == []
    assert pins.pinned_ids == MapSet.new([1])
    assert pins.pins_changed?
    refute pins.usage_changed?
    refute pins.timestamp_changed?

    unpinned = Transcript.toggle_pin(pinned, 1)
    assert {:changes, pins} = Transcript.since(unpinned, Transcript.cursor(pinned))
    assert pins.pins_changed?
    assert pins.pinned_ids == MapSet.new()

    next =
      unpinned |> Transcript.add_usage(TurnUsage.new(1, 2, 0, 0, 0.5)) |> Transcript.touch(@later)

    assert {:changes, metadata} = Transcript.since(next, Transcript.cursor(unpinned))
    assert metadata.entries == []
    refute metadata.pins_changed?
    assert metadata.usage_changed?
    assert metadata.timestamp_changed?
    assert metadata.usage.input == 1
    assert metadata.last_changed_at == @later
  end

  test "malformed, foreign and future cursors never guess continuity" do
    source = new([{:user, "one"}])
    cursor = Transcript.cursor(source)
    foreign = Transcript.cursor(new([]))
    assert {:reset, :foreign_incarnation, snapshot} = Transcript.since(source, foreign)
    assert pairs(snapshot.entries) == Transcript.messages_with_ids(source)

    for future <- [Cursor.new(source.incarnation, 0, 1), Cursor.new(source.incarnation, 1, 0)] do
      assert {:reset, :future_cursor, %Snapshot{}} = Transcript.since(source, future)
    end

    for invalid <- [
          nil,
          %{},
          :invalid,
          0,
          %{cursor | revision: -1},
          %{cursor | incarnation: nil},
          %{cursor | generation: :bad}
        ] do
      assert {:error, :invalid_cursor} = Transcript.since(source, invalid)
    end
  end

  test "every structural replacement advances the exact reset generation and revision" do
    source = new([{:user, "one"}, {:assistant, "two"}, {:user, "three"}])
    cursor = Transcript.cursor(source)
    assert {:ok, branched, branch} = Transcript.branch_at(source, 0, @later)
    assert Branch.entry_ids(branch) == [1, 2, 3]
    assert_reset(source, branched)
    assert {:ok, switched} = Transcript.switch_branch(branched, 1)
    assert_reset(branched, switched)
    compacted = Transcript.compact(switched, [3, 1])
    assert_reset(switched, compacted)
    assert Transcript.messages_with_ids(compacted) == [{1, {:user, "one"}}, {3, {:user, "three"}}]
    assert Transcript.append(compacted, {:user, "four"}).next_id == 5

    restored =
      Transcript.restore(
        compacted,
        [{:user, "loaded"}],
        [40],
        [],
        TurnUsage.new(),
        MapSet.new([40]),
        @later
      )

    assert_reset(compacted, restored)
    assert Transcript.append(restored, {:assistant, "new"}).next_id == 42
    assert {:reset, :reset_generation, %{pinned_ids: pins}} = Transcript.since(restored, cursor)
    assert pins == MapSet.new([40])

    reset = Transcript.reset(restored, [])
    assert_reset(restored, reset)
    assert reset.next_id == 1
    assert Transcript.messages(reset) == []
    # A second revision-zero-like logical transcript is never the old incarnation/generation.
    assert {:reset, :reset_generation, %Snapshot{entries: []}} = Transcript.since(reset, cursor)
  end

  property "indexed updates preserve list semantics and cursor reconstruction after every operation" do
    check all(
            operations <-
              list_of(
                tuple({integer(0..3), integer(-15..15), string(:alphanumeric, max_length: 12)}),
                max_length: 80
              )
          ) do
      source = new([])

      Enum.reduce(operations, {source, []}, fn {kind, index, text}, {current, model} ->
        {next, expected} = model_transition(current, model, kind, index, text)
        assert Transcript.messages(next) == expected
        assert Enum.map(Transcript.messages_with_ids(next), &elem(&1, 1)) == expected
        assert Active.change_count(next.active) == length(expected)
        assert {:snapshot, snapshot} = Transcript.since(current, :snapshot)

        case Transcript.since(next, snapshot.cursor) do
          {:unchanged, _} ->
            assert next == current

          {:changes, changes} ->
            reconstructed =
              Enum.reduce(
                changes.entries,
                Map.new(snapshot.entries, &{&1.ordinal, &1}),
                &Map.put(&2, &1.ordinal, &1)
              )

            assert reconstructed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1).message) ==
                     expected
        end

        {next, expected}
      end)
    end
  end

  property "restoring durable list boundaries preserves source order, branch identities and pins" do
    check all(
            texts <- list_of(string(:alphanumeric, max_length: 20), min_length: 1, max_length: 30),
            high_id <- integer(100..10_000)
          ) do
      messages = Enum.map(texts, &{:user, &1})
      ids = Enum.to_list(high_id..(high_id + length(texts) - 1))
      archived = {"saved", messages, ids, @now}

      source =
        Transcript.restore(
          new([]),
          messages,
          ids,
          [archived],
          TurnUsage.new(),
          MapSet.new(ids),
          @later
        )

      {roundtrip_ids, roundtrip_messages} =
        source |> Transcript.messages_with_ids() |> Enum.unzip()

      restored =
        Transcript.restore(
          source,
          roundtrip_messages,
          roundtrip_ids,
          Transcript.branches(source),
          Transcript.usage(source),
          Transcript.pinned_ids(source),
          @later
        )

      assert_reset(source, restored)
      assert Transcript.messages_with_ids(restored) == Transcript.messages_with_ids(source)
      assert Transcript.branches(restored) == Transcript.branches(source)
      assert Transcript.pinned_ids(restored) == MapSet.new(ids)
      appended = Transcript.append(restored, {:assistant, "after restore"})
      assert appended.next_id > Enum.max(ids) + 1
      assert Active.change_count(restored.active) == length(messages)
    end
  end

  test "100 and 10,000 entry work and retention stay indexed, with no intermediate payload journal" do
    small = measure_source(100)
    large = measure_source(10_000)
    assert large.unchanged_work <= small.unchanged_work * 2 + 2_000
    assert large.changed_work <= small.changed_work * 4 + 5_000
    assert large.mutation_work <= small.mutation_work * 5 + 10_000
    assert large.append_work <= small.append_work * 5 + 10_000
    assert large.batch_work <= small.batch_work * 5 + 10_000
    IO.puts("transcript indexed work/retention: #{inspect([small, large])}")
  end

  defp measure_source(count) do
    tool = %ToolCall{id: "measured", name: "shell"}

    messages =
      [{:tool_call, tool} | List.duplicate({:user, "retained"}, count - 2)] ++ [{:assistant, ""}]

    source = new(messages)
    cursor = Transcript.cursor(source)
    {unchanged_work, _} = work(fn -> for _ <- 1..100, do: Transcript.since(source, cursor) end)

    {append_work, appended} =
      work(fn ->
        Enum.reduce(1..100, source, fn _, current ->
          Transcript.append(current, {:user, "new"})
        end)
      end)

    {batch_work, batched} =
      work(fn -> Transcript.append_many(source, List.duplicate({:user, "new"}, 100)) end)

    assert Transcript.messages_with_ids(appended) == Transcript.messages_with_ids(batched)
    assert Active.change_count(appended.active) == count + 100
    assert Active.change_count(batched.active) == count + 100

    {mutation_work, next} =
      work(fn ->
        Enum.reduce(1..100, source, fn index, current ->
          current
          |> Transcript.update_tool_call(
            "measured",
            &ToolCall.update_partial(&1, "payload-#{index}")
          )
          |> Transcript.append_stream_tail(:assistant, ["x"])
        end)
      end)

    {changed_work, _} = work(fn -> for _ <- 1..100, do: Transcript.since(next, cursor) end)
    assert {:changes, changes} = Transcript.since(next, cursor)
    assert Enum.map(changes.entries, & &1.ordinal) == [0, count - 1]
    assert Active.change_count(next.active) == count
    assert :erts_debug.flat_size(next.active) < :erts_debug.flat_size(source.active) * 2

    %{
      entries: count,
      unchanged_work: unchanged_work,
      changed_work: changed_work,
      mutation_work: mutation_work,
      append_work: append_work,
      batch_work: batch_work,
      change_records: Active.change_count(next.active),
      retained_words: :erts_debug.flat_size(next.active),
      returned_entries: length(changes.entries)
    }
  end

  defp work(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, after_work} = Process.info(self(), :reductions)
    {after_work - before, result}
  end

  defp model_transition(source, model, 0, _index, text),
    do: {Transcript.append(source, {:user, text}), model ++ [{:user, text}]}

  defp model_transition(source, model, 1, _index, text) do
    expected =
      case List.last(model) do
        {:assistant, previous} ->
          List.update_at(model, -1, fn _ -> {:assistant, previous <> text} end)

        _ ->
          model ++ [{:assistant, text}]
      end

    {Transcript.append_stream_tail(source, :assistant, [text]), expected}
  end

  defp model_transition(source, model, 2, index, text),
    do:
      {Transcript.update_at(source, index, fn _ -> {:user, text} end),
       List.update_at(model, index, fn _ -> {:user, text} end)}

  defp model_transition(source, model, 3, _index, text),
    do:
      {Transcript.append_many(source, [{:user, text}, {:assistant, text}]),
       model ++ [{:user, text}, {:assistant, text}]}

  defp new(messages), do: Transcript.new(messages, @now, make_ref())
  defp pairs(entries), do: Enum.map(entries, &{&1.id, &1.message})

  defp assert_reset(previous, next) do
    assert next.incarnation == previous.incarnation
    assert next.generation == previous.generation + 1
    assert next.revision == previous.revision + 1

    assert {:reset, :reset_generation, snapshot} =
             Transcript.since(next, Transcript.cursor(previous))

    assert pairs(snapshot.entries) == Transcript.messages_with_ids(next)
  end
end
