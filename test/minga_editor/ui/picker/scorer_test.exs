defmodule MingaEditor.UI.Picker.ScorerTest do
  @moduledoc "Bounded top-K scoring matches the brute-force ordering it replaces."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaEditor.UI.Picker.Candidate
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Scorer

  # Reference implementation: the previous behavior, score every candidate then
  # fully sort. Ties broken by original index, exactly as `top_k` claims to.
  defp brute_force(candidates, segments) do
    candidates
    |> Enum.map(fn c -> {Scorer.score_candidate(c, segments), c} end)
    |> Enum.filter(fn {score, _c} -> score > 0 end)
    |> Enum.sort_by(fn {score, c} -> {-score, c.index} end)
    |> Enum.map(fn {_score, c} -> c end)
  end

  defp candidates(labels) do
    labels
    |> Enum.map(&%Item{id: &1, label: &1})
    |> Candidate.from_items()
  end

  describe "top_k/3 vs brute force" do
    test "with k >= matches, returns the exact full sorted order" do
      cands = candidates(["config.exs", "xconfig.exs", "lib/config/runtime.exs", "readme.md"])
      segments = ["config"]

      assert Scorer.top_k(cands, segments, Enum.count(cands)) == brute_force(cands, segments)
    end

    test "bounded result is the prefix of the brute-force order" do
      cands =
        candidates(["config.exs", "xconfig.exs", "lib/config/runtime.exs", "config_helper.ex"])

      segments = ["config"]

      full = brute_force(cands, segments)

      for k <- 1..length(cands) do
        assert Scorer.top_k(cands, segments, k) == Enum.take(full, k)
      end
    end

    test "prefix beats substring beats fuzzy, label beats search-only" do
      cands =
        candidates([
          # fuzzy on label
          "ceonfig.ex",
          # substring on label
          "xconfig.exs",
          # prefix on label
          "config.exs"
        ])

      [first, second, third] = Scorer.top_k(cands, ["config"], 3) |> Enum.map(& &1.item.label)

      assert first == "config.exs"
      assert second == "xconfig.exs"
      assert third == "ceonfig.ex"
    end

    test "drops candidates that fail any segment (orderless)" do
      cands = candidates(["buffer-switch", "buffer-kill", "file-open"])
      result = Scorer.top_k(cands, ["b", "sw"], 10) |> Enum.map(& &1.item.label)

      assert result == ["buffer-switch"]
    end

    test "matches against the search field when the label does not match" do
      cands = [%Item{id: 1, label: "app.ex", search_text: "lib/deep/path/app.ex"}]
      cands = Candidate.from_items(cands)

      assert Scorer.top_k(cands, ["deep"], 5) |> Enum.count() == 1
    end
  end

  describe "bounded large sets" do
    test "never returns more than k and stays a prefix of brute force" do
      labels = for i <- 1..10_000, do: "module_#{i}_config.ex"
      cands = candidates(labels)
      segments = ["config"]

      result = Scorer.top_k(cands, segments, 200)

      assert Enum.count(result) == 200
      assert result == Enum.take(brute_force(cands, segments), 200)
    end
  end

  property "top_k always equals the prefix of the brute-force order" do
    check all(
            labels <-
              list_of(string(?a..?z, min_length: 1, max_length: 6), min_length: 1, max_length: 40),
            query <- string(?a..?z, min_length: 1, max_length: 3),
            k <- integer(1..50)
          ) do
      cands = candidates(labels)
      segments = [query]

      assert Scorer.top_k(cands, segments, k) == Enum.take(brute_force(cands, segments), k)
    end
  end
end
