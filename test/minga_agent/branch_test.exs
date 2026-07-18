defmodule MingaAgent.BranchTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Branch
  alias MingaAgent.TranscriptEntry

  @created_at ~U[2026-07-17 12:00:00Z]

  test "stores an immutable snapshot of identified entries" do
    entries = [
      TranscriptEntry.new(7, {:user, "question"}),
      TranscriptEntry.new(11, {:assistant, "answer"})
    ]

    branch = Branch.new("experiment", entries, @created_at)

    assert branch.name == "experiment"
    assert Branch.messages(branch) == [{:user, "question"}, {:assistant, "answer"}]
    assert Branch.entry_ids(branch) == [7, 11]
    assert branch.created_at == @created_at
  end

  test "lists branch names and message counts" do
    branches = [
      branch("first", [{1, {:user, "one"}}]),
      branch("second", [{2, {:user, "two"}}, {3, {:assistant, "three"}}])
    ]

    result = Branch.list(branches)

    assert result =~ "first"
    assert result =~ "1 messages"
    assert result =~ "second"
    assert result =~ "2 messages"
  end

  test "lists help when no branches exist" do
    assert Branch.list([]) =~ "No branches"
  end

  defp branch(name, pairs) do
    entries = Enum.map(pairs, fn {id, message} -> TranscriptEntry.new(id, message) end)
    Branch.new(name, entries, @created_at)
  end
end
