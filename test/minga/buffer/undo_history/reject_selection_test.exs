defmodule Minga.Buffer.UndoHistory.RejectSelectionTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Author
  alias Minga.Buffer.Provenance
  alias Minga.Buffer.UndoHistory.RejectSelection

  @draft {:minga, "draft", "first"}
  @rewrite {:minga, "draft", "rewrite"}
  @cover {:minga, "cover", "replace"}
  @earlier {:minga, "earlier", "first"}

  test "an undoable edit between two steps holds only the step it overlaps" do
    {provenance, [older, kept, newer, cover, deletion]} =
      history("ABC", [
        {@draft, [{0, "A", "p"}, {1, "B", "ab"}]},
        {nil, [{1, "a", "v"}]},
        {@rewrite, [{0, "p", "r"}, {3, "C", "x"}]},
        {@cover, [{3, "x", "yz"}]},
        {nil, [{3, "y", ""}]}
      ])

    for roots <- [[older, newer], [newer, older]] do
      assert {selected, {:yours, ^kept}, _rounds, _held} =
               RejectSelection.plan(provenance, %{}, roots, %{})

      assert selected == MapSet.new([newer, cover, deletion])
    end
  end

  test "an impossible draft merge cannot pull a protected edit into an independent proposal" do
    {provenance, [earlier, _older, _kept, newer, cover, deletion]} =
      history("LMNB", [
        {@earlier, [{0, "L", "l"}]},
        {@draft, [{2, "", "x"}, {3, "B", "ab"}]},
        {nil, [{4, "a", "v"}]},
        {@rewrite, [{0, "l", "r"}, {2, "x", ""}]},
        {@cover, [{1, "MN", "yz"}]},
        {nil, [{1, "y", ""}]}
      ])

    assert {selected, nil, _rounds, _held} =
             RejectSelection.plan(provenance, %{}, [earlier], %{})

    assert selected == MapSet.new([earlier, newer, cover, deletion])
  end

  test "finalizing an intervening edit while a newer edit is retained does not invent a merge" do
    {provenance, [older, permanent, newer, cover, deletion]} =
      history("ABC", [
        {@draft, [{0, "A", "p"}, {1, "B", "ab"}]},
        {nil, [{1, "a", "v"}]},
        {@rewrite, [{0, "p", "r"}, {3, "C", "x"}]},
        {@cover, [{3, "x", "yz"}]},
        {nil, [{3, "y", ""}]}
      ])

    provenance = Provenance.discard(provenance, permanent)

    assert {selected, _hold, _rounds, _held} =
             RejectSelection.plan(provenance, %{}, [older, newer], %{})

    assert selected == MapSet.new([newer, cover, deletion])
  end

  test "a later overwriter cannot join independent drafts on the far side of a user edit" do
    {provenance, [left, right, _user, overwriter, _later_user]} =
      history("AB!!", [
        {@draft, [{0, "A", "p"}]},
        {{:minga, "draft", "second"}, [{1, "B", "q"}]},
        {nil, [{2, "!", "u"}]},
        {@rewrite, [{0, "pq", "zz"}]},
        {nil, [{3, "!", "v"}]}
      ])

    for group <- [left, right, overwriter] do
      {partners, _scan} = Provenance.draft_partners(provenance, group, %{})
      assert MapSet.size(partners) == 0
    end
  end

  test "opening the next user edit does not visit separated runs that share one draft pair" do
    small = first_user_edit_reductions(100)
    large = first_user_edit_reductions(800)

    assert large < small * 3
  end

  defp first_user_edit_reductions(count) do
    writes = for i <- 1..count, do: {i, "", "x"}
    removals = for i <- 1..count, do: {2 * i - 1, "x", ""}

    {provenance, _groups} =
      history(String.duplicate("|", count + 1), [{@draft, writes}, {@rewrite, removals}], :batch)

    assert Provenance.draft_count(provenance) == count
    {:reductions, before} = Process.info(self(), :reductions)
    {user, provenance} = Provenance.open_group(provenance, :you, nil)
    provenance = Provenance.edit(provenance, user, count + 1, "", "!")
    {:reductions, finished} = Process.info(self(), :reductions)
    assert Provenance.size(provenance) == count + 2
    finished - before
  end

  defp history(initial, edits, mode \\ :each) do
    {ids, provenance} =
      Enum.map_reduce(edits, Provenance.new(byte_size(initial)), fn {key, changes}, provenance ->
        author = if key == nil, do: :you, else: Author.author(key)
        {id, provenance} = Provenance.open_group(provenance, author, key)
        {id, Provenance.edit_all(provenance, id, changes, mode)}
      end)

    {provenance, ids}
  end
end
