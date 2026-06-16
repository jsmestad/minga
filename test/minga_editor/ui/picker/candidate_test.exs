defmodule MingaEditor.UI.Picker.CandidateTest do
  @moduledoc "The lean candidate precomputes normalized scoring fields."
  use ExUnit.Case, async: true

  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.Item

  test "from_items tags each candidate with its original index" do
    items = for i <- 1..3, do: %Item{id: i, label: "item #{i}"}
    candidates = Candidate.from_items(items)

    assert Enum.map(candidates, & &1.index) == [0, 1, 2]
    assert Enum.map(candidates, & &1.item) == items
  end

  test "norm_label is lowercased and icon-stripped" do
    cand = Candidate.from_item(%Item{id: 1, label: "🔥 Config.EXS"}, 0)

    assert cand.norm_label == "config.exs"
    assert cand.label_length == String.length("config.exs")
  end

  test "plain labels keep their text" do
    cand = Candidate.from_item(%Item{id: 1, label: "README.md"}, 0)
    assert cand.norm_label == "readme.md"
  end

  test "norm_search folds description, annotation, and search_text" do
    cand =
      Candidate.from_item(
        %Item{id: 1, label: "app.ex", description: "Lib/Deep", annotation: "M", search_text: "PATH"},
        0
      )

    assert cand.norm_search == "lib/deep m path"
  end

  test "nil annotation is skipped during normalization" do
    cand =
      Candidate.from_item(%Item{id: 1, label: "x", description: "d", annotation: nil, search_text: "y"}, 0)

    assert cand.norm_search == "d y"
  end
end
