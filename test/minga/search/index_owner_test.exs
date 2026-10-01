defmodule Minga.Search.IndexOwnerTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.EditDelta
  alias Minga.Editing.Search.Index
  alias Minga.Search.IndexOwner

  setup do
    owner = start_supervised!({IndexOwner, name: nil})
    buffer = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(buffer), do: send(buffer, :stop) end)
    {:ok, owner: owner, buffer: buffer}
  end

  test "serves exact bounded queries and invalidates the prior generation", %{
    owner: owner,
    buffer: buffer
  } do
    {:ok, first} =
      IndexOwner.install(owner, buffer, 4, 1, 10, Index.build(["foo", "none", "foo"], "foo"))

    assert {:ok, [%{line: 2, col: 0}]} = IndexOwner.matches_in_range(owner, first, 1, 2)
    assert {:ok, %{match_count: 2, current_index: 1}} = IndexOwner.summary(owner, first, {0, 0})

    delta = EditDelta.replacement(4, 8, {1, 0}, {1, 4}, "foo", {1, 3})
    assert {:ok, second} = IndexOwner.apply_edits(owner, first, 2, 11, [delta], 1, ["foo"])

    refute IndexOwner.current?(owner, first)
    assert IndexOwner.matches_in_range(owner, first, 0, 2) == :stale
    assert {:ok, %{count: 3, metrics: %{updated_lines: 1}}} = IndexOwner.stats(owner, second)
  end

  test "a query replacement cannot re-enter through its stale generation", %{
    owner: owner,
    buffer: buffer
  } do
    {:ok, old} = IndexOwner.install(owner, buffer, 1, 1, 1, Index.build(["old"], "old"))
    {:ok, current} = IndexOwner.install(owner, buffer, 2, 1, 1, Index.build(["new"], "new"))

    assert IndexOwner.matches_in_range(owner, old, 0, 0) == :stale

    assert {:ok, [%{line: 0, col: 0, length: 3}]} =
             IndexOwner.matches_in_range(owner, current, 0, 0)
  end
end
