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

    test "a later replacement does not hide a standalone deletion it sweeps over" do
      {deletion, prov} = Provenance.open_group(Provenance.new(5), @task, @step_one)
      prov = Provenance.edit(prov, deletion, 2, "c", "")
      {replacement, prov} = Provenance.open_group(prov, @task, @step_two)
      prov = Provenance.edit(prov, replacement, 1, "bd", "XY")

      assert Provenance.review_sites(prov, 2, 3) == [{replacement, 1, 3}]
      assert Provenance.review_sites(prov, 3, 4) == [{deletion, 3, 3}]

      assert {:ok, document, _, parked} =
               Provenance.revert(prov, replacement, Document.new("aXYe"))

      assert Document.content(document) == "abde"
      assert Provenance.review_sites(parked, 0, 4) == [{deletion, 2, 2}]

      assert {:ok, _, _, reapplied} = Provenance.reapply(parked, replacement, document)
      assert Provenance.review_sites(reapplied, 0, 4) == [{replacement, 1, 3}, {deletion, 3, 3}]
    end

    test "a same-step sweep preserves a direct gap through a bulk edit and restart" do
      {step, prov} = Provenance.open_group(Provenance.new(5), @task, @step_one)
      prov = Provenance.edit(prov, step, 2, "c", "")
      prov = Provenance.edit_all(prov, step, [{1, "bd", "XY"}], :batch)

      assert Provenance.review_sites(prov, 0, 4) == [{step, 1, 3}, {step, 3, 3}]
      assert {:ok, restored} = Provenance.restore_snapshot(Provenance.snapshot(prov), 4)
      assert Provenance.review_sites(restored, 3, 4) == [{step, 3, 3}]
      assert Provenance.review_group_at(restored, 3) == step
    end

    test "partially compacting a replacement does not make the following byte actionable" do
      {older, prov} = Provenance.open_group(Provenance.new(3), @task, @step_one)
      prov = Provenance.edit(prov, older, 1, "x", "AB")
      {other, prov} = Provenance.open_group(prov, {:minga, "other"}, {:minga, "other", "step"})
      prov = Provenance.edit(prov, other, 2, "", "S")
      {newer, prov} = Provenance.open_group(prov, @task, @step_two)
      prov = Provenance.edit(prov, newer, 1, "A", "")

      assert Provenance.review_group_at(prov, 3) == nil
      assert {:ok, compacted, {^older, ^newer}, _} = Provenance.compact_oldest(prov)
      assert Provenance.review_group_at(compacted, 3) == nil
      assert {newer, 1, 1} in Provenance.review_sites(compacted, 1, 2)
    end

    test "compaction retains an exact net deletion but not a cancelled insertion" do
      for removed <- ["X", ""] do
        {older, prov} =
          Provenance.open_group(Provenance.new(2 + byte_size(removed)), @task, @step_one)

        prov = Provenance.edit(prov, older, 1, removed, "Y")
        {newer, prov} = Provenance.open_group(prov, @task, @step_two)
        prov = Provenance.edit(prov, newer, 1, "Y", "")

        assert {:ok, compacted, {^older, ^newer}, _} = Provenance.compact_oldest(prov)
        assert {:ok, recovered} = Provenance.restore_snapshot(Provenance.snapshot(compacted), 2)
        expected = if removed == "", do: [], else: [{newer, 1, 1}]
        assert Provenance.review_sites(compacted, 1, 2) == expected
        assert Provenance.review_sites(recovered, 1, 2) == expected
      end
    end

    test "a gap swept in a second compaction can still be reopened" do
      {first, prov} = Provenance.open_group(Provenance.new(3), @task, @step_one)
      prov = Provenance.edit(prov, first, 1, "b", "Y")
      {second, prov} = Provenance.open_group(prov, @task, @step_two)
      prov = Provenance.edit(prov, second, 1, "Y", "")
      prov = Provenance.edit(prov, second, 0, "", "X")
      assert {:ok, prov, {^first, ^second}, _} = Provenance.compact_oldest(prov)
      assert {second, 2, 2} in Provenance.review_sites(prov, 2, 3)

      {third, prov} = Provenance.open_group(prov, @task, {:minga, "task-1", "call-3"})
      prov = Provenance.edit(prov, third, 0, "Xac", "")
      assert {:ok, compacted, {^second, ^third}, _} = Provenance.compact_oldest(prov)

      assert {:ok, recovered} = Provenance.restore_snapshot(Provenance.snapshot(compacted), 0)
      assert Provenance.review_group_at(recovered, 0) == third
    end

    test "a v1 checkpoint recovers an unambiguous gap without turning replacement ends into gaps" do
      {step, prov} = Provenance.open_group(Provenance.new(4), @task, @step_one)
      prov = Provenance.edit(prov, step, 0, "a", "A")
      prov = Provenance.edit(prov, step, 3, "d", "")

      {:provenance_v5, next_group, next_change, groups, runs, changes, drafts, marks, faulted} =
        Provenance.snapshot(prov)

      v4_runs = Enum.map(runs, &Tuple.delete_at(&1, 14))
      v3_runs = Enum.map(v4_runs, &(&1 |> Tuple.delete_at(13) |> Tuple.delete_at(12)))
      v2_runs = Enum.map(v3_runs, &Tuple.delete_at(&1, 11))

      assert {:ok, restored_v4} =
               Provenance.restore_snapshot(
                 {:provenance_v4, next_group, next_change, groups, v4_runs, changes, drafts,
                  marks, faulted},
                 3
               )

      assert Provenance.attribution_at(restored_v4, 0) == {@task, nil, nil, :unreviewed}

      assert {:ok, restored_v3} =
               Provenance.restore_snapshot(
                 {:provenance_v3, next_group, next_change, groups, v3_runs, changes, drafts,
                  marks, faulted},
                 3
               )

      assert Provenance.review_sites(restored_v3, 0, 3) == [{step, 0, 1}, {step, 3, 3}]

      v2 =
        {:provenance_v2, next_group, next_change, groups, v2_runs, changes, drafts, marks,
         faulted}

      assert {:ok, restored_v2} = Provenance.restore_snapshot(v2, 3)
      assert Provenance.review_sites(restored_v2, 0, 3) == [{step, 0, 1}, {step, 3, 3}]
      assert Provenance.strand_spans(restored_v2, 0, 3) == []

      old =
        {:provenance_v1, next_group, next_change, groups,
         Enum.map(v2_runs, &Tuple.delete_at(&1, 10)), changes, drafts, marks, faulted}

      assert {:ok, recovered} = Provenance.restore_snapshot(old, 3)
      assert Provenance.review_sites(recovered, 0, 3) == [{step, 0, 1}, {step, 3, 3}]
    end

    test "adjacent writes keep their own times through Keep and checkpoint recovery" do
      for mode <- [:each, :batch] do
        {group, prov} = Provenance.open_group(Provenance.new(2), @task, @step_one)
        prov = Provenance.edit_all(prov, group, [{0, "a", "A"}], mode, {@step_one, 1_000})
        prov = Provenance.edit_all(prov, group, [{1, "b", "B"}], mode, {@step_one, 2_000})
        assert Provenance.attribution_at(prov, 0) == {@task, @step_one, 1_000, :unreviewed}
        assert Provenance.attribution_at(prov, 1) == {@task, @step_one, 2_000, :unreviewed}

        kept = Provenance.keep_groups(prov, [group], [group])
        assert {:ok, restored} = Provenance.restore_snapshot(Provenance.snapshot(kept), 2)
        assert Provenance.attribution_at(restored, 0) == {@task, @step_one, 1_000, :kept}
        assert Provenance.attribution_at(restored, 1) == {@task, @step_one, 2_000, :kept}
        assert Provenance.attribution_at(restored, 2) == nil
      end
    end

    test "only explicit Keep survives as a mark across checkpoint restore and a later rejected edit" do
      {first, prov} = Provenance.open_group(Provenance.new(4), @task, @step_one)
      prov = Provenance.edit(prov, first, 0, "a", "A")
      prov = Provenance.keep_groups(prov, [first], [first])
      {second, prov} = Provenance.open_group(prov, @task, @step_two)
      prov = Provenance.edit(prov, second, 1, "b", "B")
      prov = Provenance.discard(prov, second)

      assert {:ok, prov} = Provenance.restore_snapshot(Provenance.snapshot(prov), 4)
      assert Provenance.strand_spans(prov, 0, 4) == [{:kept, 0, 1}]
      assert Provenance.review_sites(prov, 0, 4) == []

      {other, prov} = Provenance.open_group(prov, @task, @step_two)
      prov = Provenance.edit(prov, other, 0, "A", "Z")
      assert Provenance.strand_spans(prov, 0, 4) == []
      assert {:ok, restored, _, prov} = Provenance.revert(prov, other, Document.new("ZBcd"))
      assert Document.content(restored) == "ABcd"
      assert Provenance.strand_spans(prov, 0, 4) == [{:kept, 0, 1}]
    end

    test "kept insertion origins survive both edit paths, including bytes held by undo" do
      {step, original} = Provenance.open_group(Provenance.new(2), @task, @step_one)
      original = Provenance.edit(original, step, 1, "", "ABCDE")
      kept = Provenance.keep_groups(original, [step], [step])

      assert [%{origin: {:insert, source, 0, 5}, bytes: 5}] =
               Enum.filter(Provenance.runs(kept), & &1.kept?)

      for mode <- [:each, :batch] do
        {user, prov} = Provenance.open_group(kept, :you, nil)
        changed = Provenance.edit_all(prov, user, [{2, "B", "!"}, {4, "D", "?"}], mode)
        assert {:ok, recovered} = Provenance.restore_snapshot(Provenance.snapshot(changed), 7)

        assert [
                 %{origin: {:insert, ^source, 0, 5}, live: true, bytes: 1},
                 %{origin: {:insert, ^source, 1, 5}, live: false, text: "B"},
                 %{origin: {:insert, ^source, 2, 5}, live: true, bytes: 1},
                 %{origin: {:insert, ^source, 3, 5}, live: false, text: "D"},
                 %{origin: {:insert, ^source, 4, 5}, live: true, bytes: 1}
               ] = Enum.filter(Provenance.runs(recovered), & &1.kept?)

        assert {:ok, restored, _, restored_prov} =
                 Provenance.revert(recovered, user, Document.new("xA!C?Ey"))

        assert Document.content(restored) == "xABCDEy"
        expected = for start <- 1..5, do: {:kept, start, start + 1}
        assert Provenance.strand_spans(restored_prov, 0, 7) == expected
      end
    end

    test "adjacent edits kept together still have distinct source identities" do
      for mode <- [:each, :batch] do
        {step, prov} = Provenance.open_group(Provenance.new(2), @task, @step_one)
        edited = Provenance.edit_all(prov, step, [{0, "x", "A"}, {1, "y", "B"}], mode)
        assert {:ok, recovered} = Provenance.restore_snapshot(Provenance.snapshot(edited), 2)
        sources = Provenance.keep_sources(recovered, [step])

        assert [{{:replace, first, 0, 1}, 0, 1}, {{:replace, second, 0, 1}, 1, 1}] =
                 for({:written, origin, point, bytes} <- sources, do: {origin, point, bytes})

        assert [
                 {:removed, {:replace, ^first, 0, 1}, 1, "x"},
                 {:removed, {:replace, ^second, 0, 1}, 2, "y"}
               ] =
                 for({:removed, _, _, _} = removed <- sources, do: removed)

        kept = Provenance.keep_groups(edited, [step], [step])

        assert [{:replace, ^first, 0, 1}, {:replace, ^second, 0, 1}] =
                 for(run <- Provenance.runs(kept), run.kept?, do: run.origin)

        assert first != second
        assert Provenance.strand_spans(kept, 0, 2) == [{:kept, 0, 1}, {:kept, 1, 2}]
      end
    end

    test "direct deletion sources distinguish identical preimages at different sites after restore" do
      for mode <- [:each, :batch] do
        {step, prov} = Provenance.open_group(Provenance.new(4), @task, @step_one)
        edited = Provenance.edit_all(prov, step, [{1, "X", ""}, {3, "X", ""}], mode)
        assert {:ok, recovered} = Provenance.restore_snapshot(Provenance.snapshot(edited), 2)

        assert [
                 {:removed, {:delete, first, 0, 1}, 1, "X"},
                 {:removed, {:delete, second, 0, 1}, 2, "X"}
               ] = Provenance.keep_sources(recovered, [step])

        assert first != second
      end
    end

    test "one direct deletion keeps ordered offsets for all its preimage pieces" do
      for mode <- [:each, :batch] do
        {inserted, prov} = Provenance.open_group(Provenance.new(6), @task, @step_one)
        prov = Provenance.edit(prov, inserted, 2, "", "XY")
        {deleted, prov} = Provenance.open_group(prov, @task, @step_two)
        edited = Provenance.edit_all(prov, deleted, [{1, "bXYc", ""}], mode)
        assert {:ok, recovered} = Provenance.restore_snapshot(Provenance.snapshot(edited), 4)

        assert [
                 {:removed, {:delete, id, 0, 4}, 1, "b"},
                 {:removed, {:delete, id, 1, 4}, 1, "XY"},
                 {:removed, {:delete, id, 3, 4}, 1, "c"}
               ] = Provenance.keep_sources(recovered, [deleted])
      end
    end

    test "proof retires held origin intervals without changing undo or authorship" do
      {step, prov} = Provenance.open_group(Provenance.new(2), @task, @step_one)
      prov = Provenance.edit(prov, step, 1, "", "XYZ")
      assert [{:written, {:insert, id, 0, 3}, 1, 3}] = Provenance.keep_sources(prov, [step])
      prov = Provenance.keep_groups(prov, [step], [step])
      {user, prov} = Provenance.open_group(prov, :you, nil)
      prov = Provenance.edit(prov, user, 1, "XYZ", "!")
      assert {retired, []} = Provenance.retire_kept(prov, [{:insert, id, 1, 2}])

      assert {:ok, restored, _, history} = Provenance.revert(retired, user, Document.new("a!b"))
      assert Document.content(restored) == "aXYZb"
      assert Provenance.strand_spans(history, 0, 5) == [{:kept, 1, 2}, {:kept, 3, 4}]
      assert [{2, 3, @task, nil}] = Provenance.spans(history, 2, 3)

      assert {history, [{1, 2}]} = Provenance.retire_kept(history, [{:insert, id, 0, 1}])
      assert Provenance.strand_spans(history, 0, 5) == [{:kept, 3, 4}]
      assert {:ok, reapplied, _, _} = Provenance.reapply(history, user, restored)
      assert Document.content(reapplied) == "a!b"
    end

    test "a proof cannot retire a splice from an independently restored history" do
      for mode <- [:each, :batch] do
        {first, a} = Provenance.open_group(Provenance.new(2, 123), @task, @step_one)
        a = Provenance.edit_all(a, first, [{1, "", "X"}], mode)
        assert [{:written, {:insert, origin, 0, 1}, 1, 1}] = Provenance.keep_sources(a, [first])
        a = Provenance.keep_groups(a, [first], [first])

        {second, b} = Provenance.open_group(Provenance.new(2, 456), @task, @step_one)
        b = Provenance.edit_all(b, second, [{1, "", "Y"}], mode)
        b = Provenance.keep_groups(b, [second], [second])
        assert {:ok, recovered} = Provenance.restore_snapshot(Provenance.snapshot(b), 3)

        proof = [{:insert, origin, 0, 1}]
        assert {retired, [{1, 2}]} = Provenance.retire_kept(a, proof)
        assert Provenance.strand_spans(retired, 0, 3) == []
        assert {^recovered, []} = Provenance.retire_kept(recovered, proof)
        assert Provenance.strand_spans(recovered, 0, 3) == [{:kept, 1, 2}]
      end
    end

    test "an inert deletion mark stays until proof covers its full ordered preimage" do
      {step, prov} = Provenance.open_group(Provenance.new(4), @task, @step_one)
      prov = Provenance.edit(prov, step, 2, "XY", "")
      assert [{:removed, {:delete, id, 0, 2}, 2, "XY"}] = Provenance.keep_sources(prov, [step])
      prov = Provenance.keep_groups(prov, [step], [step])
      assert {^prov, []} = Provenance.retire_kept(prov, [{:delete, id, 1, 2}])

      assert {retired, [{2, 2}]} =
               Provenance.retire_kept(prov, [{:delete, id, 1, 2}, {:delete, id, 0, 1}])

      assert Provenance.strand_spans(retired, 0, 2) == []
      assert Provenance.dead_bytes(retired) == 0
    end

    test "a kept deletion carries no deleted text and adds no dependency to a later rewrite" do
      {deleted, prov} = Provenance.open_group(Provenance.new(4), @task, @step_one)
      prov = Provenance.edit(prov, deleted, 1, "b", "")
      assert [{:removed, {:delete, id, 0, 1}, 1, "b"}] = Provenance.keep_sources(prov, [deleted])
      prov = Provenance.keep_groups(prov, [deleted], [deleted])
      assert Provenance.dead_bytes(prov) == 0
      assert {:ok, saved} = Provenance.restore_snapshot(Provenance.snapshot(prov), 3)

      assert [%{origin: {:delete, ^id, 0, 1}, bytes: 0, text: nil}] =
               Enum.filter(Provenance.runs(saved), & &1.kept?)

      assert Provenance.strand_spans(saved, 0, 3) == [{:kept, 1, 1}]
      assert Provenance.review_sites(saved, 0, 3) == []

      for mode <- [:each, :batch] do
        {later, history} = Provenance.open_group(saved, @task, @step_two)
        changed = Provenance.edit_all(history, later, [{0, "acd", "XYZ"}], mode)

        assert {:ok, restored, _, history} =
                 Provenance.revert(changed, later, Document.new("XYZ"))

        assert Document.content(restored) == "acd"
        assert Provenance.strand_spans(history, 0, 3) == [{:kept, 1, 1}]
        assert Provenance.strand_spans(history, 1, 2) == [{:kept, 1, 1}]
      end
    end

    test "human strands follow the live text and survive eviction and checkpoint restore" do
      for mode <- [:each, :batch] do
        {you, prov} = Provenance.open_group(Provenance.new(4), :you, nil)
        prov = Provenance.edit_all(prov, you, [{0, "a", "A"}, {3, "d", "D"}], mode)
        assert Provenance.strand_spans(prov, 1, 3) == []
        assert Provenance.strand_spans(prov, 0, 4) == [{:you, 0, 1}, {:you, 3, 4}]
        assert {:ok, document, _, reverted} = Provenance.revert(prov, you, Document.new("AbcD"))
        assert Document.content(document) == "abcd"
        assert Provenance.strand_spans(reverted, 0, 4) == []
        retired = Provenance.discard(prov, you)
        assert {:ok, restored} = Provenance.restore_snapshot(Provenance.snapshot(retired), 4)
        assert Provenance.strand_spans(restored, 2, 4) == [{:you, 3, 4}]
      end
    end

    test "an EOF deletion query skips parked insertions at the same gap" do
      initial = Provenance.new(1)
      inserted = Document.new("ax")

      park = fn range, prov ->
        Enum.reduce(range, prov, fn n, prov ->
          {id, prov} = Provenance.open_group(prov, @task, {:minga, "task-1", "parked-#{n}"})
          prov = Provenance.edit(prov, id, 1, "", "x")
          assert {:ok, _, _, prov} = Provenance.revert(prov, id, inserted)
          prov
        end)
      end

      short = park.(1..16, initial)
      long = park.(17..512, short)

      query = fn prov ->
        {deletion, prov} = Provenance.open_group(prov, @task, @step_one)
        prov = Provenance.edit(prov, deletion, 0, "a", "")
        {:reductions, before} = Process.info(self(), :reductions)
        assert Provenance.review_sites(prov, 0, 0) == [{deletion, 0, 0}]
        {:reductions, after_query} = Process.info(self(), :reductions)
        after_query - before
      end

      assert query.(long) <= 3 * query.(short) + 200
    end

    test "paired rewrites do not crowd a gap, and point lookup stops before the next byte" do
      source = fn n ->
        Enum.reduce(1..n, Provenance.new(n + 1), fn offset, prov ->
          {group, prov} = Provenance.open_group(prov, @task, {:minga, "task-1", "step-#{offset}"})
          Provenance.edit(prov, group, offset, "a", "x")
        end)
      end

      measure = fn n ->
        prov = source.(n)
        {you, prov} = Provenance.open_group(prov, :you, nil)
        removed = String.duplicate("x", n)
        hidden = Provenance.edit(prov, you, 1, removed, "")

        {agent, prov} = Provenance.open_group(prov, {:minga, "other"}, {:minga, "other", "step"})
        many_gaps = Provenance.edit(prov, agent, 1, removed, "")

        {:reductions, before} = Process.info(self(), :reductions)
        assert Provenance.review_sites(hidden, 1, 1) == []
        assert Provenance.review_group_at(many_gaps, 0) == nil
        assert Provenance.review_group_at(many_gaps, 1) == agent
        {:reductions, after_queries} = Process.info(self(), :reductions)
        after_queries - before
      end

      assert measure.(512) <= 3 * measure.(16) + 250
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
      # Work, not time: the reductions for 6000 insertions against 600 in the same run; linear is ten times, and the
      # bound of 30 catches anything quadratic.
      test "#{place} insertions keep locators at most five digits and stay linear" do
        {small, _prov} = work(fn -> insert_many(unquote(place), 600) end)
        {large, prov} = work(fn -> insert_many(unquote(place), 6_000) end)

        assert Provenance.size(prov) == 6_000 * 3
        assert prov |> Provenance.runs() |> Enum.map(&length(&1.id)) |> Enum.max() <= 5
        assert large < 30 * small, "#{large} reductions for 6000 against #{small} for 600"
      end
    end
  end

  describe "replacements by change identity" do
    # Addendum 2's counterexample to every rule read from where tombstones sit: two edits of one step look alike.
    test "deleting one edit's replacement covers only what that edit replaced" do
      document = Document.new("ab\n")
      {step, prov} = Provenance.open_group(Provenance.new(3), @task, @step_one)
      {document, prov} = edit(document, prov, step, 0, "a", "X")
      {document, prov} = edit(document, prov, step, 1, "b", "")
      {you, prov} = Provenance.open_group(prov, :you, nil)
      {document, prov} = edit(document, prov, you, 0, "X", "")
      assert Document.content(document) == "\n"

      assert {:ok, rejected, _first, _prov} = Provenance.revert(prov, step, document)
      assert Document.content(rejected) == "b\n"
    end

    # The shrunk case for fix A: compaction drops the tombstone that linked two replacements, and the link survives.
    test "after compaction drops a rewritten step's text, deleting the rewrite still covers what the first step replaced" do
      document = Document.new("abc")
      {one, prov} = Provenance.open_group(Provenance.new(3), @task, @step_one)
      {document, prov} = edit(document, prov, one, 1, "b", "X")
      {two, prov} = Provenance.open_group(prov, @task, @step_two)
      {document, prov} = edit(document, prov, two, 1, "X", "Y")
      assert {:ok, compacted, {^one, ^two}, _examined} = Provenance.compact_oldest(prov)
      refute Provenance.group?(compacted, one)

      {you, compacted} = Provenance.open_group(compacted, :you, nil)
      {document, compacted} = edit(document, compacted, you, 1, "Y", "")
      assert {:ok, rejected, _first, _prov} = Provenance.revert(compacted, two, document)
      assert Document.content(rejected) == "ac"
    end

    test "a replacement pulls compacted drafts only strictly inside its range" do
      document = Document.new("LxR")
      {first, prov} = Provenance.open_group(Provenance.new(3), @task, @step_one)
      {document, prov} = edit(document, prov, first, 1, "x", "AB")
      {second, prov} = Provenance.open_group(prov, @task, @step_two)
      {document, prov} = edit(document, prov, second, 2, "", "S")
      {document, prov} = edit(document, prov, second, 1, "A", "")
      {document, prov} = edit(document, prov, second, 2, "B", "")
      assert Document.content(document) == "LSR"
      assert {:ok, prov, {^first, ^second}, _examined} = Provenance.compact_oldest(prov)
      assert :none = Provenance.compact_oldest(prov)

      for mode <- [:each, :batch],
          {start, removed, expected} <- [{0, "LS", "R"}, {1, "S", "LxR"}] do
        {you, branch} = Provenance.open_group(prov, :you, nil)
        branch = Provenance.edit_all(branch, you, [{start, removed, "U"}], mode)

        {:ok, changed} =
          Document.splice_byte_range(document, start, byte_size(removed), "U", {0, 0})

        {other, branch} =
          Provenance.open_group(branch, {:minga, "other"}, {:minga, "other", "step"})

        {changed, branch} = edit(changed, branch, other, start, "U", "")
        branch = Provenance.discard(branch, other)
        assert {:ok, rejected, _first, _prov} = Provenance.revert(branch, second, changed)
        assert Document.content(rejected) == expected
      end
    end

    test "rewriting one position repeatedly keeps bounded coverage metadata after compaction" do
      for steps <- [20, 200], shape <- [:single, :split] do
        initial = {Document.new("x"), Provenance.new(1), nil, 0}

        {document, prov, latest, examined} =
          Enum.reduce(1..steps, initial, fn n, {doc, prov, old, examined} ->
            {next, prov} = Provenance.open_group(prov, @task, {:minga, "t1", "rewrite-#{n}"})
            {doc, prov} = edit(doc, prov, next, 0, Document.content(doc), "ab")

            {doc, prov} =
              if shape == :split do
                {doc, prov} = edit(doc, prov, next, 1, "", "!")
                edit(doc, prov, next, 1, "!", "")
              else
                {doc, prov}
              end

            if old == nil do
              {doc, prov, next, examined}
            else
              assert {:ok, prov, {^old, ^next}, visited} = Provenance.compact_oldest(prov)
              {doc, prov, next, examined + visited}
            end
          end)

        assert Provenance.run_count(prov) <= 5
        assert map_size(Provenance.change_records(prov)) <= 3
        assert examined <= 10 * steps
        assert {:ok, original, _first, _prov} = Provenance.revert(prov, latest, document)
        assert Document.content(original) == "x"

        finalized = Provenance.discard(prov, latest)
        assert Provenance.dead_bytes(finalized) == 0
        assert Provenance.change_records(finalized) == %{}
      end
    end

    test "a foreign replacement cannot erase an adjacent anchor it never covered" do
      document = Document.new("KLpqx")
      {first, prov} = Provenance.open_group(Provenance.new(5), @task, @step_one)
      {document, prov} = edit(document, prov, first, 4, "x", "t")
      {second, prov} = Provenance.open_group(prov, @task, @step_two)
      {document, prov} = edit(document, prov, second, 2, "pqt", "s")
      assert {:ok, prov, {^first, ^second}, _} = Provenance.compact_oldest(prov)

      {third, prov} = Provenance.open_group(prov, @task, {:minga, "task-1", "call-3"})
      {document, prov} = edit(document, prov, third, 2, "s", "")
      {document, prov} = edit(document, prov, third, 2, "", "z")
      assert {:ok, prov, {^second, ^third}, _} = Provenance.compact_oldest(prov)

      {fourth, prov} = Provenance.open_group(prov, @task, {:minga, "task-1", "call-4"})
      assert {:ok, document, _, prov} = Provenance.revert(prov, third, document)
      {foreign, prov} = Provenance.open_group(prov, {:minga, "other"}, {:minga, "other", "1"})
      {document, prov} = edit(document, prov, foreign, 4, "", "v")
      {document, prov} = edit(document, prov, foreign, 1, "Lp", "U")
      {document, prov} = edit(document, prov, foreign, 2, "qv", "")
      assert {:ok, document, _, prov} = Provenance.revert(prov, foreign, document)
      {document, prov} = edit(document, prov, :untracked, 2, "pq", "")
      assert {:ok, document, _, prov} = Provenance.reapply(prov, foreign, document)
      assert {:ok, document, _, prov} = Provenance.reapply(prov, third, document)
      assert Document.content(document) == "KUz"
      {document, prov} = edit(document, prov, fourth, 2, "z", "")
      assert {:ok, compacted, {^third, ^fourth}, _} = Provenance.compact_oldest(prov)

      for {branch, class} <- [{prov, [third, fourth]}, {compacted, [fourth]}] do
        assert {:ok, document, _, branch} = Provenance.revert_all(branch, class, document)
        {document, branch} = edit(document, branch, :untracked, 1, "U", "")
        {document, branch} = edit(document, branch, :untracked, 1, "", "w")

        {document, branch} =
          Enum.reduce(class, {document, branch}, fn id, {doc, prov} ->
            assert {:ok, doc, _, prov} = Provenance.reapply(prov, id, doc)
            {doc, prov}
          end)

        assert Document.content(document) == "Kw"
        {final, branch} = Provenance.open_group(branch, {:minga, "final"}, {:minga, "final", "1"})
        {document, branch} = edit(document, branch, final, 0, "Kw", "Z")
        {document, branch} = edit(document, branch, :untracked, 0, "Z", "")
        assert {:ok, rejected, _, _} = Provenance.revert_all(branch, class, document)
        assert Document.content(rejected) == ""
      end
    end

    test "a replacement that sweeps only an anchor does not block its writer" do
      {first, prov} = Provenance.open_group(Provenance.new(3), @task, @step_one)
      prov = Provenance.edit(prov, first, 1, "x", "AB")
      {other, prov} = Provenance.open_group(prov, {:minga, "other"}, {:minga, "other", "1"})
      prov = Provenance.edit(prov, other, 2, "", "S")
      {second, prov} = Provenance.open_group(prov, @task, @step_two)
      prov = Provenance.edit(prov, second, 1, "A", "")
      prov = Provenance.edit(prov, second, 2, "B", "")
      assert {:ok, prov, {^first, ^second}, _} = Provenance.compact_oldest(prov)
      assert {:ok, prov, {^first, ^second}, _} = Provenance.compact_oldest(prov)

      {sweeper, prov} = Provenance.open_group(prov, {:minga, "new"}, {:minga, "new", "1"})
      prov = Provenance.edit(prov, sweeper, 0, "LS", "U")
      assert Provenance.blocker(prov, second, fn _, _ -> true end) == nil
      refute second in Provenance.blocked_groups(prov, sweeper)
    end

    test "one-sided covers and pulls cannot erase the other piece of a compacted replacement" do
      for link <- [:position, :pull] do
        document = Document.new("KLxR")
        {you, prov} = Provenance.open_group(Provenance.new(4), :you, nil)
        {document, prov} = edit(document, prov, you, 2, "x", "XY")
        {first, prov} = Provenance.open_group(prov, @task, @step_one)
        {document, prov} = edit(document, prov, first, 2, "X", "AB")

        {document, prov, removed} =
          case link do
            :position ->
              {document, prov, "LA"}

            :pull ->
              {document, prov} = edit(document, prov, first, 2, "A", "s")
              {document, prov, "Ls"}
          end

        {second, prov} = Provenance.open_group(prov, @task, @step_two)
        {document, prov} = edit(document, prov, second, 1, removed, "U")
        {document, prov} = edit(document, prov, second, 2, "B", "")
        assert Document.content(document) == "KUYR"
        assert {:ok, compacted, {^first, ^second}, _} = Provenance.compact_oldest(prov)

        results =
          for branch <- [prov, compacted] do
            assert {:ok, document, _, branch} = Provenance.revert(branch, you, document)
            {document, branch} = edit(document, branch, :untracked, 1, "U", "")
            {document, branch} = edit(document, branch, :untracked, 1, "", "w")
            assert {:ok, document, _, branch} = Provenance.reapply(branch, you, document)
            {document, branch} = edit(document, branch, you, 1, "Y", "")
            assert Document.content(document) == "KwR"

            {final, branch} =
              Provenance.open_group(branch, {:minga, "final"}, {:minga, "final", "1"})

            {document, branch} = edit(document, branch, final, 0, "Kw", "Z")
            {document, branch} = edit(document, branch, :untracked, 0, "Z", "")
            assert {:ok, rejected, _, _} = Provenance.revert(branch, you, document)
            Document.content(rejected)
          end

        assert results == ["R", "R"],
               "different restoration for #{link} link: #{inspect(results)}"
      end
    end

    test "losing a draft retains every member of its compactible chain" do
      {first, prov} = Provenance.open_group(Provenance.new(4), @task, @step_one)
      prov = Provenance.edit(prov, first, 2, "", "x")
      {second, prov} = Provenance.open_group(prov, @task, @step_two)
      prov = Provenance.edit(prov, second, 2, "x", "")
      {third, prov} = Provenance.open_group(prov, @task, {:minga, "task-1", "call-3"})
      prov = Provenance.edit(prov, third, 1, "LR", "")

      assert {:ok, compacted, {^first, ^second}, _} = Provenance.compact_oldest(prov)
      assert {:ok, _, {^second, ^third}, _} = Provenance.compact_oldest(compacted)

      assert draft_component(prov, [third], MapSet.new()) == MapSet.new([first, second, third])
      detached = Provenance.edit(prov, :untracked, 0, "AB", "")
      assert Provenance.run_count(detached) == 0

      assert draft_component(detached, [first], MapSet.new()) ==
               MapSet.new([first, second, third])

      assert {:ok, empty, _, parked} = Provenance.revert(detached, first, Document.new(""))
      assert draft_component(parked, [second], MapSet.new()) == MapSet.new([second, third])
      assert draft_neighbours(parked, first) == MapSet.new()
      assert {:ok, _, _, reapplied} = Provenance.reapply(parked, first, empty)

      assert draft_component(reapplied, [first], MapSet.new()) ==
               MapSet.new([first, second, third])

      detached = Provenance.discard(detached, second)
      assert draft_neighbours(detached, first) == MapSet.new([third])
    end

    test "detaching a draft cannot join steps across an intervening rewrite" do
      {first, prov} = Provenance.open_group(Provenance.new(4), @task, @step_one)
      prov = Provenance.edit(prov, first, 2, "", "x")
      {second, prov} = Provenance.open_group(prov, @task, @step_two)
      prov = Provenance.edit(prov, second, 2, "x", "")
      {foreign, prov} = Provenance.open_group(prov, {:minga, "other"}, {:minga, "other", "1"})
      prov = Provenance.edit(prov, foreign, 1, "LR", "")
      assert {:ok, document, _, prov} = Provenance.revert(prov, foreign, Document.new("AB"))
      assert Document.content(document) == "ALRB"
      {third, prov} = Provenance.open_group(prov, @task, {:minga, "task-1", "call-3"})
      prov = Provenance.edit(prov, third, 1, "LR", "")
      assert {:ok, compacted, {^first, ^second}, _} = Provenance.compact_oldest(prov)
      assert :none = Provenance.compact_oldest(compacted)

      expected = MapSet.new([first, second])
      assert draft_component(prov, [first], MapSet.new()) == expected
      detached = Provenance.edit(prov, :untracked, 0, "AB", "")
      detached = Provenance.discard(detached, foreign)
      assert draft_component(detached, [first], MapSet.new()) == expected
      assert draft_neighbours(detached, third) == MapSet.new()

      for pads <- [0, 40], ids <- [[foreign, second], [second, foreign]] do
        padded =
          Enum.reduce(1..pads//1, prov, fn n, acc ->
            task = "pad-#{n}"
            {step, acc} = Provenance.open_group(acc, {:minga, task}, {:minga, task, "step"})
            Provenance.edit(acc, step, Provenance.size(acc), "", "z")
          end)

        discarded = Provenance.discard_all(padded, ids)
        assert draft_neighbours(discarded, first) == MapSet.new()
        assert draft_neighbours(discarded, third) == MapSet.new()
      end
    end

    test "detached drafts keep dense histories connected with linear traversal work" do
      for size <- [8, 32] do
        bars = String.duplicate("|", size + 1)
        inserted = String.duplicate("x", size)

        {prov, ids} =
          Enum.reduce(1..size, {Provenance.new(byte_size(bars)), []}, fn step, {prov, ids} ->
            {id, prov} = Provenance.open_group(prov, @task, {:minga, "task-1", "insert-#{step}"})
            changes = for gap <- 0..(size - 1), do: {gap * step + 1, "", "x"}
            {Provenance.edit_all(prov, id, changes, :batch), [id | ids]}
          end)

        {prov, ids} =
          Enum.reduce(1..size, {prov, ids}, fn gap, {prov, ids} ->
            {id, prov} = Provenance.open_group(prov, @task, {:minga, "task-1", "delete-#{gap}"})
            {Provenance.edit(prov, id, gap, inserted, ""), [id | ids]}
          end)

        detached = Provenance.edit_all(prov, :untracked, [{0, bars, ""}], :batch)
        assert Provenance.run_count(detached) == 0
        assert draft_component(detached, [hd(ids)], MapSet.new()) == MapSet.new(ids)

        visits =
          Enum.sum_by(ids, fn id -> MapSet.size(draft_neighbours(detached, id)) end)

        assert visits <= 2 * (length(ids) - 1)
      end
    end

    test "a step that rewrites its own replacement still covers the original when you delete the rewrite" do
      document = Document.new("ab")
      {step, prov} = Provenance.open_group(Provenance.new(2), @task, @step_one)
      {document, prov} = edit(document, prov, step, 0, "a", "X")
      {document, prov} = edit(document, prov, step, 0, "X", "Y")
      {you, prov} = Provenance.open_group(prov, :you, nil)
      {document, prov} = edit(document, prov, you, 0, "Y", "")

      assert {:ok, rejected, _first, _prov} = Provenance.revert(prov, step, document)
      assert Document.content(rejected) == "b"
    end

    test "your edit inside a replacement marks it, and the edit that removes its last text covers the rest" do
      document = Document.new("abc\n")
      {step, prov} = Provenance.open_group(Provenance.new(4), @task, @step_one)
      {document, prov} = edit(document, prov, step, 0, "abc", "XYZ")
      {you, prov} = Provenance.open_group(prov, :you, nil)
      {document, prov} = edit(document, prov, you, 1, "Y", "")
      assert Provenance.overlaps_among(prov, [step]) |> Enum.map(&elem(&1, 0)) == [:you]

      {later, prov} = Provenance.open_group(prov, :you, nil)
      {document, prov} = edit(document, prov, later, 0, "XZ", "")
      assert Document.content(document) == "\n"
      assert {:ok, undone, _first, prov} = Provenance.revert(prov, you, document)
      assert Document.content(undone) == "\n"
      assert Provenance.overlaps_among(prov, [step]) == []
      assert {:ok, rejected, _first, _prov} = Provenance.revert(prov, step, undone)
      assert Document.content(rejected) == "\n"
    end
  end

  # Cases whose documents and refusals were reasoned by hand, not produced by either side. Each row runs against both
  # production and the never-drop model. Groups are named; a Minga group's task is its first element.
  describe "hand-computed cases" do
    @hand_cases [
      # CH2: two steps of one task rewrite one word (recorded as precise changes), you retype it.
      # The reject keeps yours.
      {"CH2", "call(foo)\n",
       [
         {:open, :s1, "t1"},
         {:edit, :s1, 5, 3, "bar"},
         {:open, :s2, "t1"},
         {:edit, :s2, 7, 1, "z"},
         {:open, :you, :you},
         {:edit, :you, 5, 3, "qux"},
         {:reject, [:s1, :s2], "call(qux)\n"}
       ]},
      # Partial CH2: you retype only the second step's letter; "ba" stays the first step's, so the reject is refused
      # until your edit is undone, then exact.
      {"partial CH2", "call(foo)\n",
       [
         {:open, :s1, "t1"},
         {:edit, :s1, 5, 3, "bar"},
         {:open, :s2, "t1"},
         {:edit, :s2, 7, 1, "z"},
         {:open, :you, :you},
         {:edit, :you, 7, 1, "q"},
         {:reject, [:s1, :s2], :refused},
         {:revert, [:you]},
         {:reject, [:s1, :s2], "call(foo)\n"}
       ]},
      # CV1: one step replaces both letters in two edits; another task deletes the second, you delete the first.
      {"CV1", "ab\n",
       [
         {:open, :c1, "t1"},
         {:edit, :c1, 0, 1, "X"},
         {:edit, :c1, 1, 1, "Y"},
         {:open, :t2, "t2"},
         {:edit, :t2, 1, 1, ""},
         {:open, :you, :you},
         {:edit, :you, 0, 1, ""},
         {:reject, [:t2], "Y\n"}
       ]},
      # Addendum 2's two-edit case: deleting the first edit's replacement covers only what that edit replaced.
      {"two edits of one step", "ab\n",
       [
         {:open, :s, "t1"},
         {:edit, :s, 0, 1, "X"},
         {:edit, :s, 1, 1, ""},
         {:open, :you, :you},
         {:edit, :you, 0, 1, ""},
         {:reject, [:s], "b\n"}
       ]},
      # The compaction chain: the merge drops the rewritten step's text, and deleting the rewrite still covers "b".
      {"compaction chain", "abc",
       [
         {:open, :s1, "t"},
         {:edit, :s1, 1, 1, "X"},
         {:open, :s2, "t"},
         {:edit, :s2, 1, 1, "Y"},
         :compact,
         {:open, :you, :you},
         {:edit, :you, 1, 1, ""},
         {:reject, [:s1, :s2], "ac"}
       ]},
      # One step writes X over "a", then Y over its own X; you delete Y.
      {"same step X then Y", "ab",
       [
         {:open, :s, "t"},
         {:edit, :s, 0, 1, "X"},
         {:edit, :s, 0, 1, "Y"},
         {:open, :you, :you},
         {:edit, :you, 0, 1, ""},
         {:reject, [:s], "b"}
       ]},
      # The void case: your replacement of "a" never happened (undone, then discarded), so "Q" never stood for "a".
      {"void", "pab",
       [
         {:open, :g1, :you},
         {:edit, :g1, 1, 1, "X"},
         {:revert, [:g1]},
         {:discard, [:g1]},
         {:open, :g3, :you},
         {:edit, :g3, 1, 0, "m"},
         {:open, :t1, "t1"},
         {:edit, :t1, 2, 1, ""},
         {:open, :g2, :you},
         {:edit, :g2, 0, 2, "Q"},
         {:open, :t2, "t2"},
         {:edit, :t2, 0, 1, ""},
         {:reject, [:t1], "ab"}
       ]},
      # Forgotten text: an untracked change took "Q" out of the step's "QP"; your later replacement around that spot
      # does
      # not stand for it, so deleting your replacement leaves the step's reject exact.
      {"forgotten text", "xyz",
       [
         {:open, :s, "t"},
         {:edit, :s, 1, 1, "QP"},
         {:edit, :untracked, 1, 1, ""},
         {:open, :g1, :you},
         {:edit, :g1, 1, 0, "m"},
         {:open, :g2, :you},
         {:edit, :g2, 0, 2, "W"},
         {:open, :g3, :you},
         {:edit, :g3, 0, 1, ""},
         {:reject, [:s], "yz"}
       ]},
      # Minga rewrote part of your replacement: your undo would leave Minga's "Z" beside "ab", a document that never
      # existed, so it is refused naming the step; once Minga's step is rejected, your undo restores "ab".
      {"XY then Z", "ab",
       [
         {:open, :you, :you},
         {:edit, :you, 0, 2, "XY"},
         {:open, :t, "t"},
         {:edit, :t, 0, 1, "Z"},
         {:undo, :you, {:refused, "t"}},
         {:reject, [:t], "XY"},
         {:undo, :you, "ab"}
       ]},
      # The compaction case found by the oracle: t2 rewrote t1's "c", not the "\nc" you deleted.
      # Your undo is allowed.
      {"undo after compaction", "",
       [
         {:open, :s1, "t1"},
         {:edit, :s1, 0, 0, "a\nc"},
         {:open, :s2, "t1"},
         {:edit, :s2, 0, 2, "c\nb"},
         {:open, :s3, "t1"},
         {:edit, :s3, 2, 2, "c"},
         :compact,
         :compact,
         {:open, :g4, :you},
         {:edit, :g4, 1, 2, ""},
         {:open, :t2, "t2"},
         {:edit, :t2, 0, 1, "bbb"},
         {:undo, :g4, "bbb\nc"}
       ]},
      # The only link from t2 to the "T" you deleted is a cover: t2 deleted your own replacement of "pq", and "T" went
      # with it. A cover never rewrote anything, so your undo is allowed (it changes nothing: "T" stays deleted).
      {"link by cover only", "pTq\n",
       [
         {:open, :g1, :you},
         {:edit, :g1, 1, 1, ""},
         {:open, :g2, :you},
         {:edit, :g2, 0, 2, "Z"},
         {:open, :t2, "t2"},
         {:edit, :t2, 0, 1, ""},
         {:undo, :g1, "\n"}
       ]},
      # Next to it, a direct deletion: t2 deleted the "W" you typed, so your undo is refused naming t2.
      {"link by direct deletion", "pq\n",
       [
         {:open, :g1, :you},
         {:edit, :g1, 1, 0, "W"},
         {:open, :t2, "t2"},
         {:edit, :t2, 1, 1, ""},
         {:undo, :g1, {:refused, "t2"}}
       ]},
      # Interleaved tasks at one spot: t1 writes X over "a", t2 writes Z over X, you delete Z; the chain covers both.
      {"interleaved tasks", "a\n",
       [
         {:open, :t1, "t1"},
         {:edit, :t1, 0, 1, "X"},
         {:open, :t2, "t2"},
         {:edit, :t2, 0, 1, "Z"},
         {:open, :you, :you},
         {:edit, :you, 0, 1, ""},
         {:reject, [:t2], "\n"},
         {:reject, [:t1], "\n"}
       ]},
      # A later sweep over text the reverted task both wrote and deleted protects nothing: the reject is allowed, with
      # or without compaction (which drops that text). Task t1 writes "aa" and deletes the second "a"; an untracked
      # edit replaces the first; task t2 writes "c" after the tombstone; task t3 deletes "uc", sweeping it.
      {"sweep over text the task wrote and deleted", "",
       [
         {:open, :g1, "t1"},
         {:edit, :g1, 0, 0, "aa"},
         {:open, :g2, "t1"},
         {:edit, :g2, 1, 1, ""},
         {:edit, :untracked, 0, 1, "u"},
         {:open, :g4, "t2"},
         {:edit, :g4, 1, 0, "c"},
         {:open, :g5, "t3"},
         {:edit, :g5, 0, 2, ""},
         {:reject_task, [:g1, :g2], "t1", ""}
       ]},
      {"sweep over text the task wrote and deleted, compacted", "",
       [
         {:open, :g1, "t1"},
         {:edit, :g1, 0, 0, "aa"},
         {:open, :g2, "t1"},
         {:edit, :g2, 1, 1, ""},
         :compact,
         {:edit, :untracked, 0, 1, "u"},
         {:open, :g4, "t2"},
         {:edit, :g4, 1, 0, "c"},
         {:open, :g5, "t3"},
         {:edit, :g5, 0, 2, ""},
         {:reject_task, [:g1, :g2], "t1", ""}
       ]},
      # A later task that deleted live text the task wrote still refuses it.
      {"later deletion of the task's live text", "",
       [
         {:open, :g1, "t1"},
         {:edit, :g1, 0, 0, "aa"},
         {:open, :g2, "t1"},
         {:edit, :g2, 1, 1, ""},
         {:open, :g5, "t3"},
         {:edit, :g5, 0, 1, ""},
         {:reject_task, [:g1, :g2], "t1", {:refused, "t3"}}
       ]}
    ]

    for {name, original, steps} <- @hand_cases do
      test "#{name}" do
        run_hand_case(unquote(original), unquote(Macro.escape(steps)))
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

    # A cover adds a deleter only to text that is already dead, so the document an edit leaves is exactly the splice,
    # whatever groups are undone when it runs.
    property "a cover never changes the visible document" do
      check all(
              original <- StreamData.string([?a..?c], min_length: 1, max_length: 8),
              commands <- StreamData.list_of(command(), max_length: 50),
              max_runs: runs(300)
            ) do
        initial = {Provenance.new(byte_size(original)), ProvenanceModel.new(original), original}

        Enum.reduce(commands, initial, fn command, {prov, _model, _text} = state ->
          {next_prov, _model, text} = next = run(command, state)
          assert Provenance.size(next_prov) == byte_size(text)

          if Provenance.size(prov) != Provenance.size(next_prov) or prov != next_prov do
            assert spans(next_prov, text) == ProvenanceModel.authors(elem(next, 1))
          end

          next
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

    property "edit_all in one pass equals edit/5 one change at a time, records and links included" do
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

    # Chains of steps of one task over one spot, then your replacement around it, then the task's reject.
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

    test "a replacement after compaction still covers the older text behind a discarded draft" do
      assert %{text: "b"} =
               oracle_check(
                 "aaaa",
                 [
                   {31, 481, 0, 6, "\n\n\n"},
                   {13, 106, 0, 3, "c"},
                   {23, 809, 5, 7, "\n"},
                   {47, 665, 5, 12, "ab\n"},
                   {31, 438, 2, 8, "cba"},
                   {19, 234, 0, 6, "\n"},
                   {40, 445, 5, 11, "cc"},
                   {11, 307, 0, 3, "a"},
                   {26, 441, 5, 8, ""},
                   {11, 896, 0, 8, "ac"},
                   {95, 832, 0, 5, "\n\n"},
                   {2, 387, 5, 7, "\n"},
                   {44, 620, 2, 4, "\n"},
                   {47, 277, 3, 0, "b"},
                   {78, 557, 2, 11, "c\n"},
                   {68, 271, 3, 6, "bc"}
                 ],
                 false
               )
    end

    # The oracle for fix A. The model never drops, absorbs or compacts a byte; production drops text that can never be
    # live again, merges steps and settles discarded groups, all interleaved at random. Tasks and your groups move as
    # units, as the history moves them, and each side decides on its own whether an undo or a reject is refused.
    property "with drops, compaction and discards interleaved, every document matches the never-drop model" do
      Process.delete(:oracle)

      check all(
              original <- StreamData.string([?a..?c, ?\n], max_length: 10),
              commands <- StreamData.list_of(oracle_command(), max_length: 70),
              max_runs: runs(400)
            ) do
        oracle_check(original, commands, false)
      end

      assert Map.get(Process.get(:oracle), :skips, 0) > 0
    end

    # The lifecycle of a record with no made runs left, generated on purpose: few tasks with long chains of steps, so
    # compaction merges often; undo and redo around Minga's steps; discards of owners and of pullers.
    property "replacement coverage survives compaction and finalization exactly as in the model" do
      Process.delete(:oracle)

      check all(
              original <- StreamData.string([?a..?c, ?\n], max_length: 8),
              commands <- StreamData.list_of(oracle_command(), max_length: 80),
              max_runs: runs(400)
            ) do
        oracle_check(original, commands, true)
      end

      counts = Process.get(:oracle, %{})

      for event <- [
            :skips,
            :runless,
            :mixed_owners,
            :anchored,
            :owner_discarded,
            :puller_discarded
          ] do
        assert Map.get(counts, event, 0) > 0, "no #{event} generated"
      end
    end

    # Compaction is invisible: the same history run with and without compaction slices at random points gives the same
    # document and the same refusals (who refused, by task) after every operation. No model is involved.
    property "compaction changes no later document or refusal, whatever happens after it" do
      check all(
              original <- StreamData.string([?a..?c, ?\n], max_length: 8),
              commands <- StreamData.list_of(oracle_command(), max_length: 80),
              max_runs: runs(400)
            ) do
        Enum.reduce(commands, {oracle_world(original, true), oracle_world(original, true)}, fn
          command, twins ->
            {plain, compacted} = twins = twin_step(command, twins)
            assert compacted.text == plain.text
            assert compacted.outcome == plain.outcome
            assert_records(compacted.prov)
            twins
        end)
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

        # Your edits alone: every byte you, the original file or an untracked change wrote that none of your applied
        # groups and no untracked change deleted.
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

  # Reductions this process spends running `fun`: work counted the same on any machine and under any load.
  defp work(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    value = fun.()
    {:reductions, after_fun} = Process.info(self(), :reductions)
    {after_fun - before, value}
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

  # ── Hand-computed cases ─────────────────────────────────────────────

  defp run_hand_case(original, steps) do
    state = %{
      prov: Provenance.new(byte_size(original)),
      model: ProvenanceModel.new(original),
      text: original,
      ids: %{}
    }

    Enum.reduce(steps, state, &hand_step/2)
  end

  defp hand_step({:open, name, owner}, state) do
    {author, key} =
      if owner == :you, do: {:you, nil}, else: {{:minga, owner}, {:minga, owner, "#{name}"}}

    {id, prov} = Provenance.open_group(state.prov, author, key)

    %{
      state
      | prov: prov,
        model: ProvenanceModel.open_group(state.model, id, author, key),
        ids: Map.put(state.ids, name, id)
    }
  end

  defp hand_step({:edit, name, start, length, inserted}, state) do
    group = if name == :untracked, do: :untracked, else: Map.fetch!(state.ids, name)
    removed = binary_part(state.text, start, length)
    text = splice(state.text, start, length, inserted)
    model = ProvenanceModel.edit(state.model, group, start, length, inserted)
    assert ProvenanceModel.text(model) == text

    %{
      state
      | prov: Provenance.edit(state.prov, group, start, removed, inserted),
        model: model,
        text: text
    }
  end

  defp hand_step({:revert, names}, state) do
    ids = Enum.map(names, &Map.fetch!(state.ids, &1))

    {:ok, document, _first, prov} =
      Provenance.revert_all(state.prov, ids, Document.new(state.text))

    model = Enum.reduce(ids, state.model, &ProvenanceModel.set_applied(&2, &1, false))
    assert ProvenanceModel.text(model) == Document.content(document)
    %{state | prov: prov, model: model, text: Document.content(document)}
  end

  defp hand_step({:discard, names}, state) do
    ids = Enum.map(names, &Map.fetch!(state.ids, &1))

    %{
      state
      | prov: Provenance.discard_all(state.prov, ids),
        model: Enum.reduce(ids, state.model, &ProvenanceModel.discard(&2, &1))
    }
  end

  defp hand_step({:undo, name, expected}, state) do
    id = Map.fetch!(state.ids, name)
    production = Provenance.blocker(state.prov, id)
    model = ProvenanceModel.blockers(state.model, id)

    case expected do
      {:refused, task} ->
        assert {:minga, ^task, _step} = production
        assert Enum.any?(model, &match?({:minga, ^task, _step}, &1))
        state

      text ->
        assert production == nil
        assert model == MapSet.new()
        hand_step({:revert, [name]}, state) |> tap(&assert(&1.text == text))
    end
  end

  defp hand_step(:compact, state) do
    assert {:ok, prov, _merged, _examined} = Provenance.compact_oldest(state.prov)
    %{state | prov: prov}
  end

  # A whole task's reject, refused by a later task's deletion the way `UndoHistory.reject_task/4` checks it.
  defp hand_step({:reject_task, names, task, expected}, state) do
    ids = Enum.map(names, &Map.fetch!(state.ids, &1))
    existing = Enum.filter(ids, &Provenance.group?(state.prov, &1))
    blocks? = fn author, _key -> author != :you and author != {:minga, task} end
    production = Provenance.blocker_among(state.prov, existing, blocks?)
    model = ProvenanceModel.blockers_among(state.model, ids, blocks?)

    case expected do
      {:refused, by} ->
        assert {:minga, ^by, _step} = production
        assert Enum.any?(model, &match?({:minga, ^by, _step}, &1))
        state

      text ->
        assert production == nil
        assert model == MapSet.new()
        hand_step({:reject, names, text}, state)
    end
  end

  defp hand_step({:reject, names, expected}, state) do
    ids = Enum.map(names, &Map.fetch!(state.ids, &1))
    existing = Enum.filter(ids, &Provenance.group?(state.prov, &1))
    production_refused? = Provenance.overlaps_among(state.prov, existing) != []
    model_refused? = ProvenanceModel.overlaps_among(state.model, ids) != MapSet.new()

    case expected do
      :refused ->
        assert production_refused?
        assert model_refused?
        state

      text ->
        refute production_refused?
        refute model_refused?

        {:ok, document, _first, prov} =
          Provenance.revert_all(state.prov, existing, Document.new(state.text))

        model = Enum.reduce(ids, state.model, &ProvenanceModel.set_applied(&2, &1, false))
        assert Document.content(document) == text
        assert ProvenanceModel.text(model) == text
        %{state | prov: prov, model: model, text: text}
    end
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
        pick(open_ids(model), a, state, &discard(state, &1))

      # Several groups at once, which often takes the one-pass path.
      kind < 93 and mode == :discard_groups ->
        discard_many(state, model |> open_ids() |> Enum.take_every(rem(a, 3) + 1))

      kind < 97 ->
        edit_command(state, a, b, c, inserted)

      kind < 99 ->
        batch_edit(state, a, b, c, inserted)

      true ->
        untracked_edit(state, a, b, inserted)
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

    each = Provenance.edit_all(prov, id, changes, :each)

    assert same_record?(batch, each, open_ids(model))
    assert byte_records(batch) == byte_records(each)

    # The one pass merges what typing forward merges, so it never holds more runs; the budget never sees it inflate.
    assert Provenance.run_count(batch) <= Provenance.run_count(each)

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
      end) and draft_bytes(one) == draft_bytes(other) and
      dead_text(one) == dead_text(other)
  end

  # How many dead bytes are drafts; how runs split does not change it.
  defp draft_bytes(prov) do
    drafts = MapSet.new(Provenance.drafts(prov), &elem(&1, 1))

    for run <- Provenance.runs(prov),
        MapSet.member?(drafts, run.id),
        reduce: 0,
        do: (acc -> acc + run.bytes)
  end

  # Every byte's replacement fields, live or dead, in order; the links between records; and the next id. Two records
  # whose runs split differently give the same bytes.
  # Every byte's record facts and every record's links, with records numbered by where they first appear (bytes in
  # order, then links), since one pass may number records differently than changes one at a time.
  defp byte_records(prov) do
    runs = Provenance.runs(prov)
    records = Provenance.change_records(prov)

    order =
      runs
      |> Enum.flat_map(&[&1.made_by | Enum.sort(&1.replaced_by)])
      |> Enum.concat(records |> Map.keys() |> Enum.sort())
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new()

    name = fn change -> Map.get(order, change) end
    names = &(&1 |> Enum.map(name) |> Enum.sort())

    bytes =
      Enum.flat_map(runs, fn run ->
        List.duplicate(
          {run.live, run.made_by && name.(run.made_by),
           run.replaced_by |> Enum.map(name) |> Enum.sort()},
          run.bytes
        )
      end)

    links =
      Map.new(records, fn {change, record} ->
        {name.(change), {names.(record.pulls), names.(record.pulled_by)}}
      end)

    {bytes, links}
  end

  # The records hold what the runs say: `made` and `replaced` equal a recomputation from every run's `made_by` and
  # `replaced_by`, a record with no made run left is pulled and owned, links go both ways, and nothing faulted.
  # `pulls` cannot be recomputed from the runs; the never-drop model checks what they do.
  defp assert_records(prov) do
    runs = Provenance.runs(prov)
    records = Provenance.change_records(prov)

    made =
      for run <- runs, run.made_by != nil, reduce: %{} do
        acc -> Map.update(acc, run.made_by, [run.id], &[run.id | &1])
      end

    replaced =
      for run <- runs, change <- run.replaced_by, reduce: %{} do
        acc -> Map.update(acc, change, [run.id], &[run.id | &1])
      end

    assert Enum.all?(Map.keys(made), &Map.has_key?(records, &1))
    assert Enum.all?(Map.keys(replaced), &Map.has_key?(records, &1))

    owned =
      for {change, %{owner: owner}} <- records, is_integer(owner), reduce: %{} do
        acc -> Map.update(acc, owner, [change], &Enum.sort([change | &1]))
      end

    assert Provenance.owned_changes(prov) == owned

    for {change, record} <- records do
      # A record outlives its made runs only while something pulls it, and then keeps the group that made them.
      if Map.has_key?(made, change) do
        assert record.owner == :runs
      else
        assert record.pulled_by != []
        assert record.owner == :permanent or Provenance.group?(prov, record.owner)
      end

      assert record.made == Enum.sort(Map.get(made, change, []))
      assert record.replaced == Enum.sort(Map.get(replaced, change, []))
      assert change < Provenance.next_change(prov)

      for pulled <- record.pulls, do: assert(change in Map.fetch!(records, pulled).pulled_by)
      for puller <- record.pulled_by, do: assert(change in Map.fetch!(records, puller).pulls)
    end

    refute Provenance.faulted?(prov)
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

  defp group_ids({_prov, model, _text}), do: model |> open_ids() |> Enum.sort()
  defp open_ids(model), do: for({id, %{final: false}} <- model.groups, do: id)

  defp applied_ids(_prov, model),
    do: for({id, %{applied: true, final: false}} <- model.groups, do: id)

  defp unapplied_ids(_prov, model),
    do: for({id, %{applied: false, final: false}} <- model.groups, do: id)

  # ── The never-drop oracle ───────────────────────────────────────────

  defp oracle_check(original, commands, focus?) do
    Enum.reduce(commands, oracle_world(original, focus?), fn command, world ->
      before = world
      world = oracle_run(command, world)
      assert ProvenanceModel.text(world.model) == world.text
      assert Provenance.size(world.prov) == byte_size(world.text)
      assert spans(world.prov, world.text) == ProvenanceModel.authors(world.model)
      assert_records(world.prov)
      oracle_census(before, world)
    end)
  end

  # Counts what the history exercised, so the properties can show they generate it.
  defp oracle_census(before, world) do
    skipped = length(world.model.skipped) - length(before.model.skipped)
    if skipped > 0, do: count(:skips)
    records = Provenance.change_records(world.prov)
    if Enum.any?(records, fn {_id, r} -> is_integer(r.owner) end), do: count(:runless)

    if Enum.any?(Provenance.runs(world.prov), &(&1.bytes == 0)), do: count(:anchored)

    writers =
      for run <- Provenance.runs(world.prov), run.made_by != nil, reduce: %{} do
        acc -> Map.update(acc, run.made_by, MapSet.new([run.group]), &MapSet.put(&1, run.group))
      end

    if Enum.any?(writers, fn {_id, groups} -> MapSet.size(groups) > 1 end),
      do: count(:mixed_owners)

    world
  end

  defp oracle_world(original, focus?) do
    %{
      focus: focus?,
      outcome: nil,
      prov: Provenance.new(byte_size(original)),
      model: ProvenanceModel.new(original),
      text: original,
      tasks: %{},
      yours: [],
      next_task: 1
    }
  end

  defp oracle_command do
    StreamData.tuple({
      StreamData.integer(0..99),
      StreamData.integer(0..1_000),
      StreamData.integer(0..5),
      StreamData.integer(0..12),
      StreamData.string([?a..?c, ?\n], max_length: 3)
    })
  end

  defp oracle_run(command, world), do: oracle_step(command, world)

  defp oracle_step({kind, a, b, c, inserted}, %{focus: true} = world) do
    cond do
      kind < 35 -> oracle_edit(world, a, b, c, inserted)
      kind < 45 -> oracle_batch(world, a, b, c, inserted)
      kind < 60 -> oracle_flip_yours(world, a, false)
      kind < 70 -> oracle_flip_yours(world, a, true)
      kind < 78 -> oracle_reject(world, a)
      kind < 88 -> oracle_discard(world, a)
      true -> oracle_compact(world, rem(b, 3) + 1)
    end
  end

  defp oracle_step({kind, a, b, c, inserted}, world) do
    cond do
      kind < 42 -> oracle_edit(world, a, b, c, inserted)
      kind < 48 -> oracle_batch(world, a, b, c, inserted)
      kind < 58 -> oracle_flip_yours(world, a, false)
      kind < 63 -> oracle_flip_yours(world, a, true)
      kind < 73 -> oracle_reject(world, a)
      kind < 80 -> oracle_discard(world, a)
      true -> oracle_compact(world, rem(b, 3) + 1)
    end
  end

  defp count(event),
    do: Process.put(:oracle, Map.update(Process.get(:oracle, %{}), event, 1, &(&1 + 1)))

  defp active_tasks(world) do
    for {task, ids} <- world.tasks,
        Enum.all?(ids, &match?(%{applied: true, final: false}, world.model.groups[&1])),
        do: task
  end

  # Who writes: a new group of yours, one of your applied groups, a new step of a running task or of a new task, or an
  # untracked change. Edits stay short over a short text, so drops and consumed replacements come often.
  defp oracle_writer(world, a, c) do
    yours =
      for id <- world.yours,
          match?(%{applied: true, final: false}, world.model.groups[id]),
          do: id

    tasks = active_tasks(world)

    case oracle_choice(world, c) do
      0 when yours != [] ->
        {Enum.at(yours, rem(a, length(yours))), world}

      choice when choice in [0, 1] ->
        oracle_open(world, :you, nil, nil)

      choice when choice in [2, 3] and tasks != [] ->
        task = tasks |> Enum.sort() |> List.to_tuple() |> elem(rem(a, length(tasks)))
        oracle_open(world, {:minga, task}, {:minga, task, "call-#{world.next_task}-#{a}"}, task)

      choice when choice in [2, 3, 4] ->
        task = "task-#{world.next_task}"
        world = %{world | next_task: world.next_task + 1}
        oracle_open(world, {:minga, task}, {:minga, task, "call-#{a}"}, task)

      5 ->
        {:untracked, world}
    end
  end

  # Focused histories favour existing tasks, so one task's steps pile up over the same text.
  defp oracle_choice(%{focus: true}, c), do: Enum.at([0, 1, 2, 2, 3, 3, 5], rem(c, 7))
  defp oracle_choice(_world, c), do: rem(c, 6)

  defp oracle_open(world, author, key, task) do
    {id, prov} = Provenance.open_group(world.prov, author, key)
    model = ProvenanceModel.open_group(world.model, id, author, key)
    world = %{world | prov: prov, model: model}

    world =
      if task,
        do: %{world | tasks: Map.update(world.tasks, task, [id], &[id | &1])},
        else: %{world | yours: [id | world.yours]}

    {id, world}
  end

  defp oracle_edit(world, a, b, c, inserted) do
    {writer, world} = oracle_writer(world, a, c)
    size = byte_size(world.text)
    start = rem(a, size + 1)
    removed_bytes = min(b, size - start)
    removed = binary_part(world.text, start, removed_bytes)
    count(:edits)

    %{
      world
      | prov: Provenance.edit(world.prov, writer, start, removed, inserted),
        model: ProvenanceModel.edit(world.model, writer, start, removed_bytes, inserted),
        text: splice(world.text, start, removed_bytes, inserted)
    }
  end

  defp oracle_batch(world, a, b, c, inserted) do
    {writer, world} = oracle_writer(world, a, c)
    changes = disjoint_changes(world.text, a, b, inserted)
    count(:batches)

    model =
      changes
      |> Enum.reverse()
      |> Enum.reduce(world.model, fn {start, removed, new}, acc ->
        ProvenanceModel.edit(acc, writer, start, byte_size(removed), new)
      end)

    %{
      world
      | prov:
          Provenance.edit_all(
            world.prov,
            writer,
            changes,
            Enum.at([:auto, :batch, :each], rem(c, 3))
          ),
        model: model,
        text: apply_changes(world.text, changes)
    }
  end

  defp splice(text, start, removed, inserted),
    do:
      binary_part(text, 0, start) <>
        inserted <> binary_part(text, start + removed, byte_size(text) - start - removed)

  # Your undo (or redo) of one group, each side refusing on its own blockers.
  defp oracle_flip_yours(world, a, applied) do
    candidates =
      for id <- world.yours,
          match?(%{final: false}, world.model.groups[id]),
          world.model.groups[id].applied != applied,
          do: id

    case candidates do
      [] ->
        world

      _some ->
        id = Enum.at(candidates, rem(a, length(candidates)))
        blocker = Provenance.blocker(world.prov, id)
        prov_ok? = blocker == nil
        model_ok? = ProvenanceModel.blockers(world.model, id) == MapSet.new()
        count(if prov_ok? == model_ok?, do: :your_flips, else: :your_flip_disagreements)
        world = %{world | outcome: {:flip, id, applied, who(blocker)}}
        oracle_flip(world, [id], applied, prov_ok?, model_ok?)
    end
  end

  # A whole task's reject, as the history does it: refused while another author partly consumed one of its
  # replacements or another task deleted its text after it.
  defp oracle_reject(world, a) do
    case Enum.sort(active_tasks(world)) do
      [] ->
        world

      tasks ->
        task = Enum.at(tasks, rem(a, length(tasks)))
        ids = Map.fetch!(world.tasks, task)
        existing = Enum.filter(ids, &Provenance.group?(world.prov, &1))
        blocks? = fn author, _key -> author != :you and author != {:minga, task} end

        overlaps = Provenance.overlaps_among(world.prov, existing)
        blocker = Provenance.blocker_among(world.prov, existing, blocks?)
        prov_ok? = overlaps == [] and blocker == nil
        refusers = overlaps |> Enum.map(&who(elem(&1, 0))) |> Enum.sort() |> Enum.uniq()
        world = %{world | outcome: {:reject, task, refusers, who(blocker)}}

        model_ok? =
          ProvenanceModel.overlaps_among(world.model, ids) == MapSet.new() and
            ProvenanceModel.blockers_among(world.model, ids, blocks?) == MapSet.new()

        count(if prov_ok?, do: :rejects, else: :refused_rejects)

        world = oracle_flip(world, ids, false, prov_ok?, model_ok?)
        if prov_ok? and model_ok? and rem(a, 2) == 0, do: oracle_finalize(world, ids), else: world
    end
  end

  defp twin_step({kind, _a, b, _c, _inserted}, {plain, compacted}) when kind >= 88,
    do: {plain, oracle_compact(compacted, rem(b, 3) + 1)}

  defp twin_step(command, {plain, compacted}),
    do:
      {oracle_step(command, %{plain | outcome: nil}),
       oracle_step(command, %{compacted | outcome: nil})}

  # Who refused, by task: compaction may rename the step that did, never its task.
  defp who({:minga, task, _step}), do: {:task, task}
  defp who(other), do: other

  defp flip_production(world, ids, false) do
    {:ok, document, _first, prov} =
      Provenance.revert_all(world.prov, ids, Document.new(world.text))

    {prov, Document.content(document)}
  end

  defp flip_production(world, ids, true) do
    {prov, document} =
      Enum.reduce(ids, {world.prov, Document.new(world.text)}, fn id, {prov, document} ->
        {:ok, document, _first, prov} = Provenance.reapply(prov, id, document)
        {prov, document}
      end)

    {prov, Document.content(document)}
  end

  defp oracle_flip(world, ids, applied, prov_ok?, model_ok?) do
    existing = Enum.filter(ids, &Provenance.group?(world.prov, &1))

    {prov, text} =
      if prov_ok?,
        do: flip_production(world, existing, applied),
        else: {world.prov, world.text}

    model =
      if model_ok?,
        do: Enum.reduce(ids, world.model, &ProvenanceModel.set_applied(&2, &1, applied)),
        else: world.model

    %{world | prov: prov, model: model, text: text}
  end

  # A group of yours falls off the stack (kept or, when undone, forgotten), or a whole task becomes final.
  defp oracle_discard(world, a) do
    open_yours = for id <- Enum.reverse(world.yours), not world.model.groups[id].final, do: id
    tasks = for {task, [id | _]} <- world.tasks, not world.model.groups[id].final, do: task

    cond do
      rem(a, 2) == 0 and open_yours != [] ->
        oracle_finalize(world, [hd(open_yours)])

      tasks != [] ->
        oracle_finalize(
          world,
          Map.fetch!(
            world.tasks,
            tasks |> Enum.sort() |> List.to_tuple() |> elem(rem(a, length(tasks)))
          )
        )

      true ->
        world
    end
  end

  defp oracle_finalize(world, ids) do
    count(:discards)
    existing = Enum.filter(ids, &Provenance.group?(world.prov, &1))
    owned = Provenance.owned_changes(world.prov)
    if Enum.any?(existing, &Map.has_key?(owned, &1)), do: count(:owner_discarded)
    records = Provenance.change_records(world.prov)

    pullers =
      for run <- Provenance.runs(world.prov),
          run.group in existing,
          change = run.made_by,
          change != nil,
          Map.fetch!(records, change).pulls != [],
          do: change

    if pullers != [], do: count(:puller_discarded)

    %{
      world
      | prov: Provenance.discard_all(world.prov, existing),
        model: Enum.reduce(ids, world.model, &ProvenanceModel.discard(&2, &1))
    }
  end

  defp oracle_compact(world, 0), do: world

  defp oracle_compact(world, slices) do
    case Provenance.compact_oldest(world.prov) do
      :none ->
        world

      {:ok, prov, _, _examined} ->
        count(:merges)
        oracle_compact(%{world | prov: prov}, slices - 1)
    end
  end

  defp minga?(model, id), do: match?({:minga, _task}, model.groups[id].author)

  defp your_applied?(_model, :untracked), do: true

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

    live_ids = for {id, group} <- model.groups, not group.final, do: id

    for id <- live_ids do
      blockers = ProvenanceModel.blockers(model, id)

      case Provenance.blocker(prov, id) do
        nil -> assert blockers == MapSet.new()
        key -> assert key in blockers
      end
    end

    for id <- live_ids do
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

    assert_records(prov)
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

  defp draft_component(_prov, [], seen), do: seen

  defp draft_component(prov, [id | rest], seen) do
    if MapSet.member?(seen, id),
      do: draft_component(prov, rest, seen),
      else:
        draft_component(
          prov,
          Enum.to_list(draft_neighbours(prov, id)) ++ rest,
          MapSet.put(seen, id)
        )
  end

  defp draft_neighbours(prov, id), do: elem(Provenance.draft_partners(prov, id, %{}), 0)

  # PROPERTY_RUNS scales every property here, for the high-count runs a review asks for.
  defp runs(count), do: count * String.to_integer(System.get_env("PROPERTY_RUNS", "1"))
end
