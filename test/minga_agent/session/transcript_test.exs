defmodule MingaAgent.Session.TranscriptTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaAgent.Branch
  alias MingaAgent.Session.Transcript
  alias MingaAgent.TranscriptEntry
  alias MingaAgent.ToolCall
  alias MingaAgent.TurnUsage

  @now ~U[2026-07-17 12:00:00Z]
  @later ~U[2026-07-17 12:01:00Z]

  test "history returns an ordered bounded page before a stable anchor after a streaming append" do
    transcript = Transcript.new(Enum.map(1..100, &{:user, "message #{&1}"}), @now, make_ref())
    previous = Transcript.cursor(transcript)
    current = Transcript.append_stream_tail(transcript, :assistant, ["partial"])
    cursor = Transcript.cursor(current)

    assert {:ok, ^cursor, entries, true} = Transcript.history_before(current, previous, 96, 3)

    assert Enum.map(entries, &{&1.id, &1.message}) ==
             [
               {93, {:user, "message 93"}},
               {94, {:user, "message 94"}},
               {95, {:user, "message 95"}}
             ]

    assert {:ok, ^cursor, [], false} = Transcript.history_before(current, previous, 1, 64)
    assert {:error, :anchor_unavailable} = Transcript.history_before(current, previous, 999, 4)
    assert {:error, :invalid_range} = Transcript.history_before(current, previous, 96, 65)
  end

  test "history rejects another transcript even when its message uses the same ID" do
    first = Transcript.new([{:user, "first"}], @now, make_ref())
    other = Transcript.new([{:user, "other"}], @now, make_ref())

    assert {:reset, :foreign_incarnation} =
             Transcript.history_before(other, Transcript.cursor(first), 1, 64)
  end

  test "reused tool IDs update only the latest indexed occurrence and keep stable IDs" do
    first = ToolCall.new("reused", "shell") |> ToolCall.complete("old result")
    current = ToolCall.new("reused", "shell")

    transcript =
      Transcript.new(
        [{:tool_call, first}, {:user, "again"}, {:tool_call, current}],
        @now,
        make_ref()
      )

    assert Transcript.current_tool_call(transcript, "reused") == current
    assert Transcript.current_tool_call(transcript, "missing") == nil
    changed = Transcript.update_tool_call(transcript, "reused", &ToolCall.deny(&1, "denied"))

    assert [
             {1, {:tool_call, ^first}},
             {2, {:user, "again"}},
             {3, {:tool_call, %{status: :denied, result: "denied"}}}
           ] =
             Transcript.messages_with_ids(changed)

    assert Transcript.update_tool_call(changed, "reused", &ToolCall.update_partial(&1, "late")) ===
             changed

    assert Transcript.update_tool_call(changed, "reused", &ToolCall.deny(&1, "denied")) ===
             changed
  end

  test "streaming replaces the matching tail without changing its identity" do
    transcript =
      Transcript.new([{:system, "started", :info}], @now, make_ref())
      |> Transcript.append_stream_tail(:thinking, ["plan"])
      |> Transcript.append_stream_tail(:thinking, [" more"])
      |> Transcript.append_stream_tail(:assistant, ["answer"])
      |> Transcript.append_stream_tail(:assistant, [" continued"])

    assert Transcript.messages_with_ids(transcript) == [
             {1, {:system, "started", :info}},
             {2, {:thinking, "plan more", false}},
             {3, {:assistant, "answer continued"}}
           ]

    assert Transcript.revision(transcript) == 4
  end

  test "message transforms preserve identity and advance revisions only when content changes" do
    tool_call = %ToolCall{id: "tool-1", name: "shell", status: :running, collapsed: true}

    transcript =
      Transcript.new([{:thinking, "reason", false}, {:tool_call, tool_call}], @now, make_ref())

    original_ids = entry_ids(transcript)
    original_revision = Transcript.revision(transcript)

    unchanged = Transcript.update_tool_call(transcript, "missing", & &1)
    assert unchanged == transcript

    changed =
      transcript
      |> Transcript.collapse_thinking()
      |> Transcript.update_tool_call("tool-1", &ToolCall.set_collapsed(&1, false))

    assert entry_ids(changed) == original_ids
    assert Transcript.revision(changed) == original_revision + 2

    assert [{:thinking, "reason", true}, {:tool_call, %{collapsed: false}}] =
             Transcript.messages(changed)
  end

  test "toggle_message_collapse targets collapsible stable IDs only" do
    tool = %ToolCall{id: "tool-1", name: "shell", status: :complete, collapsed: true}

    transcript =
      Transcript.new(
        [{:user, "u"}, {:tool_call, tool}, {:thinking, "t", false}, {:assistant, "a"}],
        @now,
        make_ref()
      )

    tool_toggled = Transcript.toggle_message_collapse(transcript, 2)
    assert entry_ids(tool_toggled) == [1, 2, 3, 4]
    assert Transcript.revision(tool_toggled) == Transcript.revision(transcript) + 1

    assert {:tool_call, %{collapsed: false}} = Enum.at(Transcript.messages(tool_toggled), 1)

    thinking_toggled = Transcript.toggle_message_collapse(tool_toggled, 3)

    assert {:thinking, "t", true} = Enum.at(Transcript.messages(thinking_toggled), 2)

    for id <- [999, 0, 1] do
      unchanged = Transcript.toggle_message_collapse(transcript, id)
      assert unchanged == transcript
      assert Transcript.revision(unchanged) == Transcript.revision(transcript)
    end
  end

  test "branching freezes identified entries and switching restores them without ID reuse" do
    transcript =
      Transcript.new(
        [
          {:system, "started", :info},
          {:user, "question"},
          {:assistant, "answer"},
          {:user, "follow-up"}
        ],
        @now,
        make_ref()
      )
      |> Transcript.toggle_pin(4)

    assert {:ok, branched, %Branch{} = branch} = Transcript.branch_at(transcript, 1, @later)
    assert entry_ids(branched) == [1, 2]
    assert Branch.entry_ids(branch) == [1, 2, 3, 4]
    assert Transcript.pinned_ids(branched) == MapSet.new([4])

    compacted = Transcript.compact(branched, [1])
    assert Branch.entry_ids(hd(Transcript.branches(compacted))) == [1, 2, 3, 4]

    assert {:ok, zero_switched} = Transcript.switch_branch(compacted, 0)
    assert entry_ids(zero_switched) == [1, 2, 3, 4]
    assert Transcript.pinned_ids(zero_switched) == MapSet.new([4])

    assert {:ok, switched} = Transcript.switch_branch(compacted, 1)
    assert entry_ids(switched) == [1, 2, 3, 4]
    assert Transcript.pinned_ids(switched) == MapSet.new([4])

    appended = Transcript.append(switched, {:assistant, "new path"})
    assert entry_ids(appended) == [1, 2, 3, 4, 5]
  end

  test "a branch switch retains pins from all frozen branches but not the outgoing path" do
    shared = TranscriptEntry.new(1, {:user, "shared"})
    first = Branch.new("first", [shared, TranscriptEntry.new(2, {:assistant, "one"})], @later)
    second = Branch.new("second", [shared, TranscriptEntry.new(3, {:assistant, "two"})], @later)

    transcript =
      Transcript.restore(
        Transcript.new([], @now, make_ref()),
        [{:user, "shared"}, {:assistant, "outgoing"}],
        [1, 4],
        [first, second],
        TurnUsage.new(),
        MapSet.new([2, 3, 4, 999]),
        @now
      )

    for {branch_index, expected_ids} <- [{0, [1, 3]}, {1, [1, 2]}] do
      assert {:ok, switched} = Transcript.switch_branch(transcript, branch_index)
      assert entry_ids(switched) == expected_ids
      assert Transcript.pinned_ids(switched) == MapSet.new([2, 3])
    end
  end

  test "branch and switch reject invalid indexes without changing the value" do
    transcript = Transcript.new([{:user, "question"}], @now, make_ref())

    assert {:error, message} = Transcript.branch_at(transcript, 1, @later)
    assert message =~ "beyond"
    assert {:error, "Branch 1 not found" <> _rest} = Transcript.switch_branch(transcript, 1)
    assert {:error, "Turn index -1 is invalid."} = Transcript.branch_at(transcript, -1, @later)
    assert {:error, "Branch -1 not found" <> _rest} = Transcript.switch_branch(transcript, -1)
    assert entry_ids(transcript) == [1]
  end

  test "compaction preserves retained order, branches, and pin relationships" do
    transcript =
      Transcript.new([{:user, "one"}, {:user, "two"}, {:user, "three"}], @now, make_ref())

    assert {:ok, transcript, _branch} = Transcript.branch_at(transcript, 2, @later)

    transcript =
      transcript
      |> Transcript.toggle_pin(1)
      |> Transcript.toggle_pin(2)
      |> Transcript.compact([3, 1])

    assert entry_ids(transcript) == [1, 3]
    assert Transcript.pinned_ids(transcript) == MapSet.new([1, 2])
    assert Branch.entry_ids(hd(Transcript.branches(transcript))) == [1, 2, 3]
  end

  test "restore keeps valid identities and normalizes invalid or duplicate identities once" do
    transcript =
      Transcript.restore(
        Transcript.new([], @now, make_ref()),
        [{:user, "one"}, {:assistant, "two"}, {:user, "three"}],
        [9, 9, -1],
        [],
        TurnUsage.new(),
        MapSet.new([9, 999]),
        @now
      )

    assert entry_ids(transcript) == [9, 10, 11]
    assert Transcript.pinned_ids(transcript) == MapSet.new([9, 999])

    appended = Transcript.append(transcript, {:assistant, "four"})
    assert entry_ids(appended) == [9, 10, 11, 12]
  end

  test "restore allocates missing message identities in transcript order" do
    transcript =
      Transcript.restore(
        Transcript.new([], @now, make_ref()),
        [{:user, "one"}, {:assistant, "two"}, {:user, "three"}],
        [8],
        [],
        TurnUsage.new(),
        MapSet.new(),
        @now
      )

    assert entry_ids(transcript) == [8, 9, 10]
    assert Transcript.append(transcript, {:assistant, "four"}) |> entry_ids() == [8, 9, 10, 11]
  end

  test "restore infers structural identities for legacy active messages" do
    transcript =
      Transcript.restore(
        Transcript.new([], @now, make_ref()),
        [{:user, "one"}, {:assistant, "two"}],
        nil,
        [],
        TurnUsage.new(),
        MapSet.new([2]),
        @now
      )

    assert entry_ids(transcript) == [1, 2]
    assert Transcript.pinned_ids(transcript) == MapSet.new([2])
  end

  test "restore keeps branch identities in the allocation high-water mark" do
    branch =
      Branch.new(
        "saved",
        [TranscriptEntry.new(40, {:assistant, "archived"})],
        @later
      )

    transcript =
      Transcript.restore(
        Transcript.new([], @now, make_ref()),
        [{:user, "active"}],
        [3],
        [branch],
        TurnUsage.new(),
        MapSet.new(),
        @now
      )

    appended = Transcript.append(transcript, {:assistant, "new"})
    assert entry_ids(appended) == [3, 41]
    assert Branch.entry_ids(hd(Transcript.branches(appended))) == [40]
  end

  test "unused active and branch ID tails both reserve positions before duplicate repair" do
    for {active_tail, branch_tail} <- [{80, 90}, {90, 80}] do
      transcript =
        Transcript.restore(
          Transcript.new([], @now, make_ref()),
          [{:user, "one"}, {:assistant, "two"}, {:user, "three"}],
          [7, 7, nil, active_tail],
          [{"archived", [{:user, "one"}, {:assistant, "old"}], [7, 7, branch_tail], @later}],
          TurnUsage.new(),
          MapSet.new(),
          @now
        )

      assert entry_ids(transcript) == [7, 91, 92]
      assert [branch] = Transcript.branches(transcript)
      assert Branch.entry_ids(branch) == [7, 93]

      appended = Transcript.append(transcript, {:assistant, "new"})
      assert entry_ids(appended) == [7, 91, 92, 94]
    end
  end

  test "an empty active transcript ignores stray IDs but an archived snapshot still reserves them" do
    for {branches, next_id} <- [{[], 1}, {[{"empty", [], [90], @later}], 91}] do
      transcript =
        Transcript.restore(
          Transcript.new([], @now, make_ref()),
          [],
          [80],
          branches,
          TurnUsage.new(),
          MapSet.new(),
          @now
        )

      appended = Transcript.append(transcript, {:user, "new"})
      assert entry_ids(appended) == [next_id]
    end
  end

  test "legacy branch IDs restart at one without rewinding the active allocator" do
    messages = [{:user, "one"}, {:assistant, "two"}]

    transcript =
      Transcript.restore(
        Transcript.new(List.duplicate({:user, "older"}, 19), @now, make_ref()),
        messages,
        nil,
        [{"legacy", messages, [], @later}, {"empty", [], [], @later}],
        TurnUsage.new(),
        MapSet.new(),
        @now
      )

    assert entry_ids(transcript) == [1, 2]
    assert [legacy, empty] = Transcript.branches(transcript)
    assert Branch.entry_ids(legacy) == [1, 2]
    assert Branch.entry_ids(empty) == []
    assert transcript |> Transcript.append({:assistant, "new"}) |> entry_ids() == [1, 2, 20]
  end

  test "reset starts a fresh logical transcript" do
    usage = %TurnUsage{input: 10, output: 5, cache_read: 1, cache_write: 2, cost: 0.25}

    transcript = Transcript.new([{:user, "old"}, {:assistant, "reply"}], @now, make_ref())
    assert {:ok, transcript, _branch} = Transcript.branch_at(transcript, 0, @later)

    reset =
      transcript
      |> Transcript.add_usage(usage)
      |> Transcript.toggle_pin(1)
      |> Transcript.reset([{:system, "new", :info}])

    assert Transcript.messages_with_ids(reset) == [{1, {:system, "new", :info}}]
    assert Transcript.branches(reset) == []
    assert Transcript.pinned_ids(reset) == MapSet.new()
    assert Transcript.usage(reset) == TurnUsage.new()
  end

  property "arbitrary transition sequences keep active IDs unique and allocation monotonic" do
    check all(
            initial <- list_of(message_generator(), min_length: 1, max_length: 12),
            operations <- list_of(operation_generator(), max_length: 60)
          ) do
      initial
      |> Transcript.new(@now, make_ref())
      |> apply_operations(operations)
    end
  end

  defp apply_operations(transcript, operations) do
    Enum.reduce(operations, transcript, fn operation, current ->
      next = apply_operation(current, operation)
      assert_invariants(current, next)
      next
    end)
  end

  defp apply_operation(transcript, {:append, text}) do
    Transcript.append(transcript, {:user, text})
  end

  defp apply_operation(transcript, {:stream, text}) do
    Transcript.append_stream_tail(transcript, :assistant, [text])
  end

  defp apply_operation(transcript, {:branch, raw_index}) do
    count = Enum.count(Transcript.messages(transcript))

    case Transcript.branch_at(transcript, rem(raw_index, count + 1), @later) do
      {:ok, next, _branch} -> next
      {:error, _reason} -> transcript
    end
  end

  defp apply_operation(transcript, {:switch, raw_index}) do
    count = Enum.count(Transcript.branches(transcript))

    case Transcript.switch_branch(transcript, rem(raw_index, count + 1) + 1) do
      {:ok, next} -> next
      {:error, _reason} -> transcript
    end
  end

  defp apply_operation(transcript, {:compact, divisor}) do
    retained_ids =
      transcript
      |> entry_ids()
      |> Enum.filter(&(rem(&1, divisor) != 0))

    Transcript.compact(transcript, retained_ids)
  end

  defp assert_invariants(previous, transcript) do
    active_ids = entry_ids(transcript)
    branch_ids = Enum.flat_map(Transcript.branches(transcript), &Branch.entry_ids/1)

    assert active_ids == Enum.uniq(active_ids)
    assert Enum.all?(active_ids, &(&1 > 0))

    assert Enum.all?(Transcript.branches(transcript), fn branch ->
             ids = Branch.entry_ids(branch)
             ids == Enum.uniq(ids) and Enum.all?(ids, &(&1 > 0))
           end)

    assert transcript.next_id >= previous.next_id
    assert transcript.next_id > Enum.max(active_ids ++ branch_ids, fn -> 0 end)

    assert Enum.take(Transcript.branches(transcript), Enum.count(Transcript.branches(previous))) ==
             Transcript.branches(previous)
  end

  defp entry_ids(transcript) do
    Enum.map(Transcript.messages_with_ids(transcript), &elem(&1, 0))
  end

  defp message_generator do
    map(string(:alphanumeric, min_length: 1, max_length: 30), &{:user, &1})
  end

  defp operation_generator do
    one_of([
      map(string(:alphanumeric, min_length: 1, max_length: 20), &{:append, &1}),
      map(string(:alphanumeric, min_length: 1, max_length: 20), &{:stream, &1}),
      map(non_negative_integer(), &{:branch, &1}),
      map(non_negative_integer(), &{:switch, &1}),
      map(integer(2..7), &{:compact, &1})
    ])
  end
end
