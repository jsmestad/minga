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

    test "appending ten thousand times keeps locators short" do
      id =
        Enum.reduce(1..10_000, Locator.between(nil, nil), fn _, id -> Locator.between(id, nil) end)

      assert [_one_digit] = id
    end
  end

  describe "against the byte-by-byte model" do
    property "random edits, reverts, reapplies and discards match the model" do
      check all(
              original <- StreamData.string([?a..?e, ?\n], max_length: 20),
              commands <- StreamData.list_of(command(), max_length: 60),
              max_runs: 300
            ) do
        initial = {Provenance.new(byte_size(original)), ProvenanceModel.new(original), original}

        Enum.reduce(commands, initial, fn command, state ->
          state = run(command, state)
          assert_matches(state)
          state
        end)
      end
    end

    property "rejecting every Minga step leaves exactly your edits replayed alone" do
      check all(
              original <- StreamData.string([?a..?e, ?\n], max_length: 20),
              commands <- StreamData.list_of(command(), max_length: 60),
              max_runs: 300
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

      kind < 93 and mode == :discard_groups ->
        pick(Map.keys(model.groups), a, state, &discard(state, &1))

      kind < 93 ->
        edit_command(state, a, b, c, inserted)

      true ->
        untracked_edit(state, a, b, inserted)
    end
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

    runs = Provenance.runs(prov)
    assert Enum.all?(runs, &(&1.bytes > 0))
    assert ids_sorted?(Enum.map(runs, & &1.id))
    assert balanced?(prov, length(runs))
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
end
