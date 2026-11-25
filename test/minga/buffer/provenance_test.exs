defmodule Minga.Buffer.ProvenanceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.Buffer.Document
  alias Minga.Buffer.Provenance
  alias Minga.Buffer.Provenance.Locator
  alias Minga.Buffer.Provenance.RunTree
  alias Minga.Test.ProvenanceModel

  @task {:minga, "task-1"}
  @step_one {:minga, "task-1", "call-1"}
  @step_two {:minga, "task-1", "call-2"}

  describe "authorship" do
    test "text loaded before tracking is unattributed" do
      prov = Provenance.new(5)

      assert Provenance.author_at(prov, 0) == :unattributed
      assert Provenance.author_at(prov, 4) == :unattributed
      assert Provenance.author_at(prov, 5) == nil
    end

    test "an edit inside unattributed text credits only the bytes it wrote" do
      {you, prov} = Provenance.open_group(Provenance.new(10), :you, nil)
      prov = Provenance.edit(prov, you, 4, "", "abc")

      assert Provenance.spans(prov, 0, 13) == [
               {0, 4, :unattributed, nil},
               {4, 7, :you, nil},
               {7, 13, :unattributed, nil}
             ]
    end

    test "spans name the Minga step that wrote each stretch and clip to the range" do
      {step, prov} = Provenance.open_group(Provenance.new(6), @task, @step_one)
      prov = Provenance.edit(prov, step, 2, "cd", "WXYZ")

      assert Provenance.spans(prov, 1, 5) == [
               {1, 2, :unattributed, nil},
               {2, 5, @task, @step_one}
             ]
    end

    test "typing grows your run instead of adding runs" do
      {you, prov} = Provenance.open_group(Provenance.new(0), :you, nil)

      prov =
        Enum.reduce(0..99, prov, fn offset, prov ->
          Provenance.edit(prov, you, offset, "", "x")
        end)

      assert [_one_run] = Provenance.runs(prov)

      prov = Provenance.edit(prov, you, 50, "", "middle")
      assert [_still_one_run] = Provenance.runs(prov)
    end

    test "text you type inside a Minga change is yours" do
      {step, prov} = Provenance.open_group(Provenance.new(0), @task, @step_one)
      prov = Provenance.edit(prov, step, 0, "", "minga")
      {you, prov} = Provenance.open_group(prov, :you, nil)
      prov = Provenance.edit(prov, you, 2, "", "me")

      assert Provenance.spans(prov, 0, 7) == [
               {0, 2, @task, @step_one},
               {2, 4, :you, nil},
               {4, 7, @task, @step_one}
             ]
    end
  end

  describe "revert and reapply" do
    test "reverting a group removes its text after another author edited above it" do
      document = Document.new("one\ntwo\n")
      {you, prov} = Provenance.open_group(Provenance.new(8), :you, nil)
      {document, prov} = edit(document, prov, you, 4, "two", "TWO")
      {step, prov} = Provenance.open_group(prov, @task, @step_one)
      {document, prov} = edit(document, prov, step, 0, "", "zero\n")

      assert {:ok, reverted, first, prov} = Provenance.revert(prov, you, document)
      assert Document.content(reverted) == "zero\none\ntwo\n"
      assert first == 9

      assert {:ok, redone, 9, _prov} = Provenance.reapply(prov, you, reverted)
      assert Document.content(redone) == "zero\none\nTWO\n"
    end

    test "a deleted run comes back where it was, between text inserted on both sides" do
      document = Document.new("abc")
      {you, prov} = Provenance.open_group(Provenance.new(3), :you, nil)
      {document, prov} = edit(document, prov, you, 1, "b", "")
      {step, prov} = Provenance.open_group(prov, @task, @step_one)
      {document, prov} = edit(document, prov, step, 1, "", "M")
      {document, prov} = edit(document, prov, step, 0, "", "N")

      assert Document.content(document) == "NaMc"
      assert {:ok, reverted, _first, _prov} = Provenance.revert(prov, you, document)
      assert Document.content(reverted) == "NabMc"
    end

    test "reverting a Minga step keeps the text you typed inside it" do
      document = Document.new("")
      {step, prov} = Provenance.open_group(Provenance.new(0), @task, @step_one)
      {document, prov} = edit(document, prov, step, 0, "", "minga")
      {you, prov} = Provenance.open_group(prov, :you, nil)
      {document, prov} = edit(document, prov, you, 2, "", "me")

      assert {:ok, reverted, 0, _prov} = Provenance.revert(prov, step, document)
      assert Document.content(reverted) == "me"
    end

    test "reverting an unchanged group leaves the document alone" do
      document = Document.new("abc")
      {you, prov} = Provenance.open_group(Provenance.new(3), :you, nil)

      assert {:ok, ^document, nil, _prov} = Provenance.revert(prov, you, document)
    end
  end

  describe "a deletion that consumes a replacement" do
    test "also deletes the text the replacement replaced, so a reject cannot bring it back" do
      document = Document.new("axb")
      {step, prov} = Provenance.open_group(Provenance.new(3), @task, @step_one)
      {document, prov} = edit(document, prov, step, 1, "x", "y")
      {you, prov} = Provenance.open_group(prov, :you, nil)
      {document, prov} = edit(document, prov, you, 1, "y", "z")

      assert {:ok, rejected, _first, prov} = Provenance.revert(prov, step, document)
      assert Document.content(rejected) == "azb"
      assert {:ok, undone, _first, _prov} = Provenance.revert(prov, you, rejected)
      assert Document.content(undone) == "axb"
    end

    test "does not cover the replaced text when part of the replacement survives on the left" do
      document = Document.new("axb")
      {step, prov} = Provenance.open_group(Provenance.new(3), @task, @step_one)
      {document, prov} = edit(document, prov, step, 1, "x", "yy")
      {you, prov} = Provenance.open_group(prov, :you, nil)
      {document, prov} = edit(document, prov, you, 2, "y", "")

      assert {:ok, rejected, _first, _prov} = Provenance.revert(prov, step, document)
      assert Document.content(rejected) == "axb"
    end
  end

  describe "blocker/2" do
    test "names the Minga step that later deleted text you wrote" do
      {you, prov} = Provenance.open_group(Provenance.new(0), :you, nil)
      prov = Provenance.edit(prov, you, 0, "", "hello")
      {step, prov} = Provenance.open_group(prov, @task, @step_two)
      prov = Provenance.edit(prov, step, 1, "ell", "ELL")

      assert Provenance.blocker(prov, you) == @step_two
    end

    test "names the Minga step whose deletion encloses the text you deleted" do
      {you, prov} = Provenance.open_group(Provenance.new(6), :you, nil)
      prov = Provenance.edit(prov, you, 2, "cd", "")
      {step, prov} = Provenance.open_group(prov, @task, @step_one)
      prov = Provenance.edit(prov, step, 1, "be", "")

      assert Provenance.blocker(prov, you) == @step_one
    end

    test "does not block for a Minga insertion inside your text or a reverted Minga step" do
      document = Document.new("")
      {you, prov} = Provenance.open_group(Provenance.new(0), :you, nil)
      {document, prov} = edit(document, prov, you, 0, "", "hello")
      {step, prov} = Provenance.open_group(prov, @task, @step_one)
      {document, prov} = edit(document, prov, step, 2, "", "MINGA")
      assert Provenance.blocker(prov, you) == nil

      {other, prov} = Provenance.open_group(prov, @task, @step_two)
      {document, prov} = edit(document, prov, other, 0, "he", "")
      assert Provenance.blocker(prov, you) == @step_two

      {:ok, _document, _first, prov} = Provenance.revert(prov, other, document)
      assert Provenance.blocker(prov, you) == nil
    end
  end

  describe "blocked_groups/2" do
    test "lists the groups whose text a group deleted after them, the reverse of blocker/2" do
      {you, prov} = Provenance.open_group(Provenance.new(6), :you, nil)
      prov = Provenance.edit(prov, you, 0, "ab", "AB")
      {step, prov} = Provenance.open_group(prov, @task, @step_one)
      prov = Provenance.edit(prov, step, 0, "ABcd", "")

      assert Provenance.blocked_groups(prov, step) == [you]
      assert Provenance.blocker(prov, you) == @step_one
      assert Provenance.blocked_groups(prov, you) == []
    end
  end

  describe "discard/2" do
    test "an applied group's text becomes permanent and merges with its neighbours" do
      {you, prov} = Provenance.open_group(Provenance.new(0), :you, nil)
      prov = Provenance.edit(prov, you, 0, "", "abc")
      {again, prov} = Provenance.open_group(prov, :you, nil)
      prov = Provenance.edit(prov, again, 3, "", "def")
      assert [_first, _second] = Provenance.runs(prov)

      prov = prov |> Provenance.discard(you) |> Provenance.discard(again)

      assert [run] = Provenance.runs(prov)
      assert run.bytes == 6
      assert Provenance.author_at(prov, 5) == :you
    end

    test "an unapplied group's text is forgotten" do
      document = Document.new("")
      {you, prov} = Provenance.open_group(Provenance.new(0), :you, nil)
      {document, prov} = edit(document, prov, you, 0, "", "abc")
      {:ok, _document, _first, prov} = Provenance.revert(prov, you, document)

      assert Provenance.discard(prov, you) |> Provenance.runs() == []
    end
  end

  describe "Locator.between/2" do
    property "sorts strictly between its bounds" do
      check all(
              lower <- StreamData.list_of(StreamData.integer(1..1_000), min_length: 1),
              upper <- StreamData.list_of(StreamData.integer(1..1_000), min_length: 1),
              lower != upper
            ) do
        [low, high] = Enum.sort([lower, upper])
        mid = Locator.between(low, high)

        assert low < mid and mid < high
        assert Locator.between(nil, low) < low
        assert Locator.between(high, nil) > high
      end
    end
  end

  describe "locator length" do
    # A 6000-line file edited at the start of every line, bottom-up or top-down, or at one place over and over.
    # Each insertion is its own group, so no run grows in place and every insertion needs a new locator.
    for place <- [:bottom_up, :top_down, :same_place] do
      test "#{place} insertions keep locators at most five digits and stay fast" do
        {micros, prov} = :timer.tc(fn -> insert_many(unquote(place), 6_000) end)

        assert Provenance.size(prov) == 6_000 * 3
        assert prov |> Provenance.runs() |> Enum.map(&length(&1.id)) |> Enum.max() <= 5
        assert micros < 3_000_000
      end
    end
  end

  describe "against the byte-by-byte model" do
    property "random edits, reverts, reapplies and discards match the model" do
      check all(
              original <- StreamData.string([?a..?e, ?\n], max_length: 20),
              commands <- StreamData.list_of(command(), max_length: 60),
              max_runs: runs(300)
            ) do
        initial = {Provenance.new(byte_size(original)), ProvenanceModel.new(original), original}

        Enum.reduce(commands, initial, fn command, state ->
          state = run(command, state)
          assert_matches(state)
          state
        end)
      end
    end

    property "an edit across a fresh replacement agrees with the model, before and after the reject" do
      check all(
              original <- StreamData.string([?a..?e, ?\n], min_length: 1, max_length: 12),
              replaced <- StreamData.string([?a..?e], max_length: 3),
              {a, b, c, d} <-
                StreamData.tuple({integer(0..20), integer(0..4), integer(0..20), integer(0..6)}),
              mine <- StreamData.string([?x..?z], max_length: 3),
              max_runs: runs(2_000)
            ) do
        state = {Provenance.new(byte_size(original)), ProvenanceModel.new(original), original}
        {prov, model, text} = state
        {step, prov, model} = open(prov, model, @task, @step_one)
        {start, removed} = range(text, a, b, 11)
        state = replace({prov, model, text}, step, start, removed, replaced)

        # Your edit starts near Minga's replacement, so it often covers it exactly, partly, or with a margin.
        {prov, model, text} = state
        {you, prov, model} = open(prov, model, :you, nil)
        your_start = min(max(start + rem(c, 5) - 2, 0), byte_size(text))
        your_removed = min(d, byte_size(text) - your_start)
        state = replace({prov, model, text}, you, your_start, your_removed, mine)
        assert_matches(state)
        state |> revert(step) |> assert_matches()
      end
    end

    property "edit_all in one pass equals edit/5 one change at a time, on multi-byte text" do
      check all(
              original <- StreamData.string([?a, ?\n, 0xE9, 0x1F600], max_length: 12),
              commands <- StreamData.list_of(command(), max_length: 40),
              {a, b, c} <-
                StreamData.tuple({integer(0..1_000), integer(0..1_000), integer(0..12)}),
              inserted <- StreamData.string([?x, 0xE9, 0x1F600], max_length: 3),
              max_runs: runs(300)
            ) do
        initial = {Provenance.new(byte_size(original)), ProvenanceModel.new(original), original}

        {prov, model, text} =
          Enum.reduce(commands, initial, fn {kind, ca, cb, cc, ins}, state ->
            next =
              if rem(kind, 3) == 0,
                do: batch_edit(state, ca, cb, cc, ins),
                else: edit_command(state, ca, cb, cc, ins)

            assert_matches(next)

            next
          end)

        assert_matches({prov, model, text})
        {_prov, _model, _text} = state = batch_edit({prov, model, text}, a, b, c, inserted)
        assert_matches(state)
      end
    end

    # R2: chains of steps of one task over one spot, then your replacement around it, then the task's reject.
    property "your replacement over a chain of a task's steps covers every replaced text, matching the model" do
      check all(
              original <- StreamData.string([?a..?e], min_length: 3, max_length: 10),
              chain <-
                StreamData.list_of(
                  StreamData.tuple(
                    {integer(0..3), integer(0..3),
                     StreamData.string([?x..?z], min_length: 1, max_length: 3)}
                  ),
                  min_length: 2,
                  max_length: 4
                ),
              {a, b} <- StreamData.tuple({integer(0..3), integer(0..3)}),
              mine <- StreamData.string([?Q..?S], max_length: 3),
              max_runs: runs(2_000)
            ) do
        initial = {Provenance.new(byte_size(original)), ProvenanceModel.new(original), original}

        {state, spot} =
          Enum.reduce(Enum.with_index(chain), {initial, {1, 1}}, fn {{shift, width, text}, n},
                                                                    {{prov, model, doc},
                                                                     {at, size}} ->
            {step, prov, model} = open(prov, model, @task, {:minga, "task", "call-#{n}"})
            start = min(max(at + shift - 1, 0), byte_size(doc))
            removed = min(max(size + width - 1, 1), byte_size(doc) - start)
            {replace({prov, model, doc}, step, start, removed, text), {start, byte_size(text)}}
          end)

        {prov, model, doc} = state
        {at, size} = spot
        {you, prov, model} = open(prov, model, :you, nil)
        start = max(at - a, 0)
        removed = min(size + a + b, byte_size(doc) - start)
        state = replace({prov, model, doc}, you, start, removed, mine)
        assert_matches(state)

        {_prov, model, _doc} = state

        state =
          Enum.reduce(for({id, %{author: @task}} <- model.groups, do: id), state, &revert(&2, &1))

        assert_matches(state)
      end
    end

    property "compaction changes no document for any revert where each task's steps move together" do
      check all(
              original <- StreamData.string([?a..?e, ?\n], max_length: 20),
              commands <- StreamData.list_of(command(), max_length: 60),
              picks <- StreamData.list_of(StreamData.boolean(), length: 40),
              max_runs: runs(300)
            ) do
        initial = {Provenance.new(byte_size(original)), ProvenanceModel.new(original), original}
        {prov, model, text} = Enum.reduce(commands, initial, &run(&1, &2, :keep_groups))
        compacted = compact_all(prov)

        # Whole tasks and single groups of yours, chosen at random, reverted on both sides.
        units =
          model.groups
          |> Enum.filter(fn {_id, group} -> group.applied end)
          |> Enum.group_by(
            fn {id, group} -> if group.author == :you, do: {:you, id}, else: group.author end,
            &elem(&1, 0)
          )
          |> Enum.sort()

        chosen =
          units
          |> Enum.zip(picks)
          |> Enum.flat_map(fn {{_unit, ids}, pick} -> if pick, do: ids, else: [] end)

        {:ok, plain, _first, _prov} = Provenance.revert_all(prov, chosen, Document.new(text))
        remaining = Enum.filter(chosen, &Provenance.group?(compacted, &1))

        {:ok, after_compaction, _first, _prov} =
          Provenance.revert_all(compacted, remaining, Document.new(text))

        assert Document.content(after_compaction) == Document.content(plain)
      end

      IO.puts(
        "\n[compaction] steps in the random model property: #{Process.get(:compactions, 0)}"
      )
    end

    property "rejecting every Minga step leaves exactly your edits replayed alone" do
      check all(
              original <- StreamData.string([?a..?e, ?\n], max_length: 20),
              commands <- StreamData.list_of(command(), max_length: 60),
              max_runs: runs(300)
            ) do
        initial = {Provenance.new(byte_size(original)), ProvenanceModel.new(original), original}
        # A discarded Minga step is final, like a kept one, so this property never discards.
        state = Enum.reduce(commands, initial, &run(&1, &2, :keep_groups))

        {prov, model, text} =
          Enum.reduce(group_ids(state), state, fn id, {prov, model, text} = state ->
            if minga?(model, id) and Provenance.applied?(prov, id),
              do: revert(state, id),
              else: {prov, model, text}
          end)

        # Your edits alone: every byte you or the original file wrote that none of your applied groups deleted.
        yours =
          for entry <- model.entries,
              entry.author in [:you, :unattributed],
              entry.group == nil or model.groups[entry.group].applied,
              not Enum.any?(entry.deletions, &your_applied?(model, &1)),
              into: <<>>,
              do: <<entry.byte>>

        assert text == yours

        refute prov
               |> Provenance.spans(0, byte_size(text))
               |> Enum.any?(&match?({:minga, _task}, elem(&1, 2)))
      end
    end
  end

  defp compact_all(prov) do
    case Provenance.compact_oldest(prov) do
      :none -> prov
      {:ok, prov, _merged, _examined} -> compact_all(prov)
    end
  end

  defp insert_many(place, lines) do
    Enum.reduce(1..lines, Provenance.new(lines * 2), fn n, prov ->
      {group, prov} = Provenance.open_group(prov, :you, nil)

      offset =
        case place do
          :bottom_up -> (lines - n) * 2
          :top_down -> (n - 1) * 3
          :same_place -> 0
        end

      Provenance.edit(prov, group, offset, "", "y")
    end)
  end

  # ── Model-based helpers ─────────────────────────────────────────────

  defp command do
    StreamData.tuple({
      StreamData.integer(0..99),
      StreamData.integer(0..1_000),
      StreamData.integer(0..1_000),
      StreamData.integer(0..12),
      StreamData.string([?a..?e, ?\n], max_length: 6)
    })
  end

  defp run(command, state, mode \\ :discard_groups)

  defp run({kind, a, b, c, inserted}, {prov, model, _text} = state, mode) do
    cond do
      kind < 55 ->
        edit_command(state, a, b, c, inserted)

      kind < 70 ->
        pick(applied_ids(prov, model), a, state, &revert(state, &1))

      kind < 85 ->
        pick(unapplied_ids(prov, model), a, state, &reapply(state, &1))

      kind < 89 and mode == :discard_groups ->
        pick(Map.keys(model.groups), a, state, &discard(state, &1))

      # Several groups at once, which often takes the one-pass path.
      kind < 93 and mode == :discard_groups ->
        discard_many(state, model.groups |> Map.keys() |> Enum.take_every(rem(a, 3) + 1))

      kind < 93 ->
        edit_command(state, a, b, c, inserted)

      kind < 97 ->
        compact(state)

      kind < 99 ->
        batch_edit(state, a, b, c, inserted)

      true ->
        untracked_edit(state, a, b, inserted)
    end
  end

  # One compaction step on both sides. It never changes the document, any visible author, or whether a group of yours
  # is blocked, and it never adds runs.
  defp compact({prov, model, text} = state) do
    case Provenance.compact_oldest(prov) do
      :none ->
        assert ProvenanceModel.drafts(model) == []
        state

      {:ok, compacted, _merged, examined} ->
        assert examined > 0
        model = ProvenanceModel.compact_oldest(model)
        assert Provenance.run_count(compacted) <= Provenance.run_count(prov)
        assert spans(compacted, text) == spans(prov, text)

        for {id, %{author: :you}} <- model.groups do
          assert Provenance.blocker(compacted, id) == nil == (Provenance.blocker(prov, id) == nil)
        end

        Process.put(:compactions, Process.get(:compactions, 0) + 1)
        {compacted, model, text}
    end
  end

  # The author of every byte; compaction may rename the step that wrote it, never the author.
  defp spans(prov, text) do
    prov
    |> Provenance.spans(0, byte_size(text))
    |> Enum.flat_map(fn {from, to, author, _key} -> List.duplicate(author, to - from) end)
  end

  defp edit_command({prov, model, text}, a, b, c, inserted) do
    applied = applied_ids(prov, model)
    choice = rem(c, length(applied) + 2)

    {id, prov, model} =
      cond do
        choice == length(applied) ->
          open(prov, model, :you, nil)

        choice == length(applied) + 1 ->
          task = "task-#{rem(a, 2)}"
          open(prov, model, {:minga, task}, {:minga, task, "call-#{map_size(model.groups)}"})

        true ->
          {Enum.at(applied, choice), prov, model}
      end

    {start, removed} = range(text, a, b, c)
    replace({prov, model, text}, id, start, removed, inserted)
  end

  # Several disjoint changes by one group through the one-pass path, against the model applying them one at a time from
  # the last to the first.
  defp batch_edit({prov, model, text}, a, b, c, inserted) do
    applied = applied_ids(prov, model)
    choice = rem(c, length(applied) + 3)

    {id, prov, model} =
      cond do
        choice == length(applied) ->
          open(prov, model, :you, nil)

        choice == length(applied) + 1 ->
          {:untracked, prov, model}

        choice == length(applied) + 2 ->
          open(
            prov,
            model,
            {:minga, "task-#{rem(a, 2)}"},
            {:minga, "task-#{rem(a, 2)}", "call-#{map_size(model.groups)}"}
          )

        true ->
          {Enum.at(applied, choice), prov, model}
      end

    changes = disjoint_changes(text, a, b, inserted)
    batch = Provenance.edit_all(prov, id, changes, :batch)

    assert same_record?(
             batch,
             Provenance.edit_all(prov, id, changes, :each),
             Map.keys(model.groups)
           )

    prov = batch

    model =
      changes
      |> Enum.reverse()
      |> Enum.reduce(model, fn {start, removed, new}, acc ->
        ProvenanceModel.edit(acc, id, start, byte_size(removed), new)
      end)

    {prov, model, apply_changes(text, changes)}
  end

  # The same record as far as any caller can tell: authors, size, blockers, overlap marks, drafts, and tombstones.
  defp same_record?(one, other, ids) do
    spans =
      &(Provenance.spans(&1, 0, Provenance.size(&1))
        |> Enum.flat_map(fn {from, to, author, _key} -> List.duplicate(author, to - from) end))

    Provenance.size(one) == Provenance.size(other) and spans.(one) == spans.(other) and
      Enum.all?(ids, fn id ->
        Provenance.blocker(one, id) == Provenance.blocker(other, id) and
          MapSet.new(Provenance.overlaps_among(one, [id]), &elem(&1, 0)) ==
            MapSet.new(Provenance.overlaps_among(other, [id]), &elem(&1, 0))
      end) and Provenance.draft_count(one) == Provenance.draft_count(other) and
      dead_text(one) == dead_text(other)
  end

  # The deleted text each group set of a tombstone keeps, in document order.
  defp dead_text(prov) do
    for run <- Provenance.runs(prov), not run.live, reduce: [] do
      [{key, text} | rest] when key == {run.group, run.deletions} ->
        [{key, text <> run.text} | rest]

      acc ->
        [{{run.group, run.deletions}, run.text} | acc]
    end
  end

  # Up to five disjoint changes in document order, cut from the seeds.
  defp disjoint_changes(text, a, b, inserted) do
    size = byte_size(text)
    count = rem(b, 5) + 1

    points =
      for n <- 1..(count * 2), into: MapSet.new(), do: rem(a * n + b * n * n, size + 1)

    points
    |> Enum.sort()
    |> Enum.chunk_every(2)
    |> Enum.with_index()
    |> Enum.map(fn
      {[from, to], n} ->
        {from, binary_part(text, from, to - from), String.slice(inserted, 0, rem(n + a, 4))}

      {[from], n} ->
        {from, "", String.slice(inserted, 0, rem(n + b, 4))}
    end)
    |> Enum.reject(fn {_start, removed, new} -> removed == "" and new == "" end)
  end

  defp apply_changes(text, changes) do
    changes
    |> Enum.reverse()
    |> Enum.reduce(text, fn {start, removed, new}, acc ->
      binary_part(acc, 0, start) <>
        new <>
        binary_part(acc, start + byte_size(removed), byte_size(acc) - start - byte_size(removed))
    end)
  end

  defp untracked_edit({prov, model, text}, a, b, inserted) do
    {start, removed} = range(text, a, b, 0)
    replace({prov, model, text}, :untracked, start, removed, inserted)
  end

  defp range(text, a, b, c) do
    size = byte_size(text)
    start = rem(a, size + 1)
    limit = if c > 10, do: size - start, else: min(4, size - start)
    {start, rem(b, limit + 1)}
  end

  defp replace({prov, model, text}, id, start, removed_bytes, inserted) do
    removed = binary_part(text, start, removed_bytes)
    prov = Provenance.edit(prov, id, start, removed, inserted)
    model = ProvenanceModel.edit(model, id, start, removed_bytes, inserted)

    text =
      binary_part(text, 0, start) <>
        inserted <>
        binary_part(text, start + removed_bytes, byte_size(text) - start - removed_bytes)

    {prov, model, text}
  end

  defp open(prov, model, author, key) do
    {id, prov} = Provenance.open_group(prov, author, key)
    {id, prov, ProvenanceModel.open_group(model, id, author, key)}
  end

  defp revert({prov, model, text}, id) do
    {:ok, document, _first, prov} = Provenance.revert(prov, id, Document.new(text))
    {prov, ProvenanceModel.set_applied(model, id, false), Document.content(document)}
  end

  defp reapply({prov, model, text}, id) do
    {:ok, document, _first, prov} = Provenance.reapply(prov, id, Document.new(text))
    {prov, ProvenanceModel.set_applied(model, id, true), Document.content(document)}
  end

  defp discard({prov, model, text}, id),
    do: {Provenance.discard(prov, id), ProvenanceModel.discard(model, id), text}

  defp discard_many({prov, model, text}, ids),
    do:
      {Provenance.discard_all(prov, ids),
       Enum.reduce(ids, model, &ProvenanceModel.discard(&2, &1)), text}

  defp pick([], _a, state, _fun), do: state
  defp pick(ids, a, _state, fun), do: fun.(Enum.at(ids, rem(a, length(ids))))

  defp group_ids({_prov, model, _text}), do: model.groups |> Map.keys() |> Enum.sort()
  defp applied_ids(_prov, model), do: for({id, %{applied: true}} <- model.groups, do: id)
  defp unapplied_ids(_prov, model), do: for({id, %{applied: false}} <- model.groups, do: id)

  defp minga?(model, id), do: match?({:minga, _task}, model.groups[id].author)

  defp your_applied?(model, id),
    do: model.groups[id].author == :you and model.groups[id].applied

  defp assert_matches({prov, model, text}) do
    assert ProvenanceModel.text(model) == text
    assert Provenance.size(prov) == byte_size(text)

    authors =
      prov
      |> Provenance.spans(0, byte_size(text))
      |> Enum.flat_map(fn {from, to, author, _key} -> List.duplicate(author, to - from) end)

    assert authors == ProvenanceModel.authors(model)

    for id <- Map.keys(model.groups) do
      blockers = ProvenanceModel.blockers(model, id)

      case Provenance.blocker(prov, id) do
        nil -> assert blockers == MapSet.new()
        key -> assert key in blockers
      end
    end

    for id <- Map.keys(model.groups) do
      keys = prov |> Provenance.overlaps_among([id]) |> MapSet.new(&elem(&1, 0))

      assert keys == ProvenanceModel.overlaps_among(model, [id])
    end

    runs = Provenance.runs(prov)
    %{groups: groups} = prov

    # The draft index is exactly the drafts recomputed from the runs, and they are the model's draft bytes.
    assert Provenance.drafts(prov) ==
             runs
             |> Enum.filter(&draft?(&1, groups))
             |> Enum.map(&{&1.group, &1.id})
             |> Enum.sort()

    draft_bytes = runs |> Enum.filter(&draft?(&1, groups)) |> Enum.map(& &1.bytes) |> Enum.sum()
    assert draft_bytes == length(ProvenanceModel.drafts(model))
    assert Enum.all?(runs, &(&1.bytes > 0))
    assert Enum.all?(runs, &match?([_ | _], &1.id))
    refute Enum.any?(runs, &match?([_, _, _, _, _ | _], &1.id))
    assert ids_sorted?(Enum.map(runs, & &1.id))
    assert balanced?(prov, length(runs))
  end

  # A draft: a dead run of an applied Minga step that an applied newer step of its task deleted, where merging the two
  # skips no other group in the run's history.
  defp draft?(run, groups) do
    case draft_partners(run, groups) do
      [] -> false
      partners -> adjacent_merge?(run, run.group, Enum.min(partners))
    end
  end

  defp draft_partners(run, groups) do
    owner = run.group && groups[run.group]

    if owner != nil and not run.live and owner.applied and minga_task?(owner.author),
      do:
        for(
          d <- run.deletions,
          d > run.group,
          groups[d].applied,
          groups[d].author == owner.author,
          do: d
        ),
      else: []
  end

  defp minga_task?({:minga, task}), do: task != :untasked
  defp minga_task?(_author), do: false

  defp adjacent_merge?(run, old, new) do
    order = Enum.uniq([run.group | Enum.reverse(run.deletions)])
    named = order ++ for({_owner, overlap} <- run.overlaps, is_integer(overlap), do: overlap)

    not Enum.any?(named, &(is_integer(&1) and &1 > old and &1 < new)) and
      abs(Enum.find_index(order, &(&1 == old)) - Enum.find_index(order, &(&1 == new))) == 1
  end

  defp ids_sorted?(ids), do: ids == Enum.sort(ids) and ids == Enum.uniq(ids)

  # An AVL tree of n nodes is at most about 1.44 log2(n + 2) high.
  defp balanced?(prov, count) do
    %{tree: tree} = prov
    RunTree.height(tree) <= 1.45 * :math.log2(count + 2)
  end

  defp edit(document, prov, id, start, removed, inserted) do
    prov = Provenance.edit(prov, id, start, removed, inserted)

    {:ok, document} =
      Document.splice_byte_range(document, start, byte_size(removed), inserted, {0, 0})

    {document, prov}
  end

  # PROPERTY_RUNS scales every property here, for the high-count runs a review asks for.
  defp runs(count), do: count * String.to_integer(System.get_env("PROPERTY_RUNS", "1"))
end
