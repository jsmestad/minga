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

  test "streaming replaces the matching tail without changing its identity" do
    transcript =
      Transcript.new([{:system, "started", :info}], @now)
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
      Transcript.new([{:thinking, "reason", false}, {:tool_call, tool_call}], @now)

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

  test "branching freezes identified entries and switching restores them without ID reuse" do
    transcript =
      Transcript.new(
        [
          {:system, "started", :info},
          {:user, "question"},
          {:assistant, "answer"},
          {:user, "follow-up"}
        ],
        @now
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

  test "branch and switch reject invalid indexes without changing the value" do
    transcript = Transcript.new([{:user, "question"}], @now)

    assert {:error, message} = Transcript.branch_at(transcript, 1, @later)
    assert message =~ "beyond"
    assert {:error, "Branch 1 not found" <> _rest} = Transcript.switch_branch(transcript, 1)
    assert {:error, "Turn index -1 is invalid."} = Transcript.branch_at(transcript, -1, @later)
    assert {:error, "Branch -1 not found" <> _rest} = Transcript.switch_branch(transcript, -1)
    assert entry_ids(transcript) == [1]
  end

  test "compaction preserves retained order, branches, and pin relationships" do
    transcript = Transcript.new([{:user, "one"}, {:user, "two"}, {:user, "three"}], @now)
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

  test "restore infers structural identities for legacy active messages" do
    transcript =
      Transcript.restore(
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

  test "reset starts a fresh logical transcript" do
    usage = %TurnUsage{input: 10, output: 5, cache_read: 1, cache_write: 2, cost: 0.25}

    transcript = Transcript.new([{:user, "old"}, {:assistant, "reply"}], @now)
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
      |> Transcript.new(@now)
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
