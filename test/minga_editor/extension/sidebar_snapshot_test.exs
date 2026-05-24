defmodule MingaEditor.Extension.Sidebar.SnapshotTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Extension.Sidebar.Snapshot

  test "selection-only changes keep structural fingerprint stable" do
    rows = [
      %{id: "a", text: "alpha", selected?: true},
      %{id: "b", text: "beta", selected?: false}
    ]

    moved_selection = [
      %{id: "a", text: "alpha", selected?: false},
      %{id: "b", text: "beta", selected?: true}
    ]

    first = Snapshot.new(rows: rows)
    second = Snapshot.new(rows: moved_selection)

    assert first.structural_fingerprint == second.structural_fingerprint
    assert first.selection_fingerprint != second.selection_fingerprint
    assert Snapshot.selection_only_change?(first, second)
  end

  test "structural changes update the structural fingerprint" do
    first = Snapshot.new(rows: [%{id: "a", text: "alpha"}])
    second = Snapshot.new(rows: [%{id: "a", text: "alpha"}, %{id: "b", text: "beta"}])

    assert first.structural_fingerprint != second.structural_fingerprint
  end
end
