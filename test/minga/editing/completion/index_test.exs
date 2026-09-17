defmodule Minga.Editing.Completion.IndexTest do
  use ExUnit.Case, async: true

  alias Minga.Editing.Completion.Index
  alias Minga.Editing.Completion.Item

  defp item(provider, label, fields \\ %{}) do
    Item.from_lsp(provider, Map.merge(%{"label" => label}, fields))
  end

  test "provider arrival order cannot change deterministic ranking" do
    alpha = [item(:alpha, "map"), item(:alpha, "max")]
    beta = [item(:beta, "macro"), item(:beta, "map_set")]

    first =
      Index.empty()
      |> Index.put_provider(:alpha, alpha, false)
      |> Index.put_provider(:beta, beta, false)
      |> Index.snapshot("ma")

    second =
      Index.empty()
      |> Index.put_provider(:beta, beta, false)
      |> Index.put_provider(:alpha, alpha, false)
      |> Index.snapshot("ma")

    assert Enum.map(first.items, &Item.wire_id/1) == Enum.map(second.items, &Item.wire_id/1)
  end

  test "from_items retains each provider identity for exact lookup" do
    alpha = item(:alpha, "map")
    beta = item(:beta, "map")
    index = Index.from_items([alpha, beta])

    assert Index.find_item(index, alpha.id) == alpha
    assert Index.find_item(index, beta.id) == beta
  end

  test "collapses true provider-local duplicates while preserving overloads and sources" do
    duplicate = item(:alpha, "map", %{"detail" => "map(enum, fun)"})
    overload = item(:alpha, "map", %{"detail" => "map(enum, module, fun)"})
    other_source = item(:beta, "map", %{"detail" => "map(enum, fun)"})

    snapshot =
      Index.empty()
      |> Index.put_provider(:alpha, [duplicate, duplicate, overload], false)
      |> Index.put_provider(:beta, [other_source], false)
      |> Index.snapshot("map")

    assert snapshot.total_count == 3
    assert snapshot.matched_count == 3

    assert Enum.map(snapshot.items, & &1.detail) |> Enum.sort() ==
             ["map(enum, fun)", "map(enum, fun)", "map(enum, module, fun)"]

    assert MapSet.new(snapshot.items, & &1.source) == MapSet.new(["alpha", "beta"])
  end

  test "exact prefix and fuzzy matches expose ranges and preselect wins initial selection" do
    items = [
      item(:provider, "map", %{"preselect" => true, "sortText" => "z"}),
      item(:provider, "map_reduce", %{"sortText" => "a"}),
      item(:provider, "my_adapter", %{"sortText" => "b"})
    ]

    index = Index.put_provider(Index.empty(), :provider, items, false)

    assert [%{label: "map", match_ranges: [{0, 3}]} | _] = Index.snapshot(index, "map").items
    assert [%{label: "map", match_ranges: [{0, 2}]} | _] = Index.snapshot(index, "ma").items

    fuzzy = Index.snapshot(index, "mad")

    assert Enum.any?(
             fuzzy.items,
             &(&1.label == "my_adapter" and &1.match_ranges == [{0, 1}, {3, 2}])
           )
  end

  test "100, 1,000, and 50,000 candidates produce bounded top-200 snapshots" do
    for count <- [100, 1_000, 50_000] do
      items =
        for index <- 1..count do
          item(:scale, "candidate_#{String.pad_leading(Integer.to_string(index), 5, "0")}")
        end

      snapshot =
        Index.empty()
        |> Index.put_provider(:scale, items, false)
        |> Index.snapshot("candidate")

      assert snapshot.total_count == count
      assert snapshot.matched_count == count
      assert snapshot.work_count == count
      assert length(snapshot.items) == min(count, 200)
    end
  end

  test "bounded snapshots retain a matching stable selection across provider merges" do
    selected = item(:alpha, "match_z")

    index =
      Index.empty()
      |> Index.put_provider(:alpha, [selected], false)
      |> Index.put_provider(:beta, [item(:beta, "match_a"), item(:beta, "match_b")], false)

    snapshot = Index.snapshot(index, "match", 2, selected.id)

    assert [_, _] = snapshot.items
    assert Enum.any?(snapshot.items, &(&1.id == selected.id))
  end
end
