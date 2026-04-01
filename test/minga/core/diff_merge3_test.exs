defmodule Minga.Core.DiffMerge3Test do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Minga.Test.Generators

  alias Minga.Core.Diff

  describe "merge3/3 basic cases" do
    test "both sides unchanged returns ancestor" do
      ancestor = ["a", "b", "c"]
      assert {:ok, ^ancestor} = Diff.merge3(ancestor, ancestor, ancestor)
    end

    test "only fork changes returns fork version" do
      ancestor = ["a", "b", "c"]
      fork = ["a", "X", "c"]
      assert {:ok, ^fork} = Diff.merge3(ancestor, fork, ancestor)
    end

    test "only parent changes returns parent version" do
      ancestor = ["a", "b", "c"]
      parent = ["a", "Y", "c"]
      assert {:ok, ^parent} = Diff.merge3(ancestor, ancestor, parent)
    end

    test "non-overlapping changes from both sides merge cleanly" do
      ancestor = ["a", "b", "c", "d", "e"]
      fork = ["a", "X", "c", "d", "e"]
      parent = ["a", "b", "c", "Y", "e"]

      assert {:ok, ["a", "X", "c", "Y", "e"]} = Diff.merge3(ancestor, fork, parent)
    end

    test "both sides make identical change auto-resolves" do
      ancestor = ["a", "b", "c"]
      changed = ["a", "X", "c"]

      assert {:ok, ^changed} = Diff.merge3(ancestor, changed, changed)
    end

    test "both sides delete the same lines auto-resolves" do
      ancestor = ["a", "b", "c"]
      both = ["a", "c"]

      assert {:ok, ^both} = Diff.merge3(ancestor, both, both)
    end
  end

  describe "merge3/3 conflicts" do
    test "overlapping changes produce a conflict" do
      ancestor = ["a", "b", "c"]
      fork = ["a", "X", "c"]
      parent = ["a", "Y", "c"]

      assert {:conflict, hunks} = Diff.merge3(ancestor, fork, parent)

      # Should have resolved and conflict regions
      assert Enum.any?(hunks, &match?({:conflict, _, _}, &1))
      assert Enum.any?(hunks, &match?({:resolved, _}, &1))
    end

    test "conflict hunks include resolved regions" do
      ancestor = ["header", "a", "b", "footer"]
      fork = ["header", "X", "b", "footer"]
      parent = ["header", "Y", "b", "footer"]

      assert {:conflict, hunks} = Diff.merge3(ancestor, fork, parent)

      resolved_texts = for {:resolved, lines} <- hunks, do: lines
      assert ["header"] in resolved_texts
    end

    test "fork deletes lines parent modifies produces conflict" do
      ancestor = ["a", "b", "c", "d"]
      fork = ["a", "d"]
      parent = ["a", "X", "c", "d"]

      assert {:conflict, _hunks} = Diff.merge3(ancestor, fork, parent)
    end
  end

  describe "merge3/3 adjacent edits" do
    test "adjacent but non-overlapping edits merge cleanly" do
      ancestor = ["a", "b", "c", "d"]
      fork = ["a", "X", "c", "d"]
      parent = ["a", "b", "Y", "d"]

      assert {:ok, ["a", "X", "Y", "d"]} = Diff.merge3(ancestor, fork, parent)
    end

    test "fork adds lines, parent modifies different region" do
      ancestor = ["a", "b", "c"]
      fork = ["a", "b", "new1", "new2", "c"]
      parent = ["a", "X", "c"]

      assert {:ok, merged} = Diff.merge3(ancestor, fork, parent)
      assert "X" in merged
      assert "new1" in merged
      assert "new2" in merged
    end
  end

  describe "merge3/3 edge cases" do
    test "empty ancestor, fork, and parent" do
      assert {:ok, []} = Diff.merge3([], [], [])
    end

    test "single-line files with conflicting edits" do
      assert {:conflict, _} = Diff.merge3(["a"], ["X"], ["Y"])
    end

    test "large shared context with small changes" do
      ancestor = Enum.map(0..19, &"line#{&1}")
      fork = List.replace_at(ancestor, 2, "fork_change")
      parent = List.replace_at(ancestor, 18, "parent_change")

      assert {:ok, merged} = Diff.merge3(ancestor, fork, parent)
      assert Enum.at(merged, 2) == "fork_change"
      assert Enum.at(merged, 18) == "parent_change"
      assert length(merged) == 20
    end

    test "multiple non-overlapping edits from both sides" do
      ancestor = ["a", "b", "c", "d", "e", "f"]
      fork = ["X", "b", "c", "d", "Y", "f"]
      parent = ["a", "b", "Z", "d", "e", "f"]

      assert {:ok, merged} = Diff.merge3(ancestor, fork, parent)
      assert "X" in merged
      assert "Y" in merged
      assert "Z" in merged
    end
  end

  # max_runs kept low to avoid scheduler starvation under full-suite
  # concurrency (7000+ async tests). Higher values caused intermittent
  # timeouts on CI with max_cases: 8.
  describe "merge3/3 properties" do
    property "merge3 with unchanged parent returns fork verbatim" do
      check all(
              ancestor <- line_list(),
              fork <- line_list(),
              max_runs: 100
            ) do
        assert {:ok, ^fork} = Diff.merge3(ancestor, fork, ancestor)
      end
    end

    property "merge3 with unchanged fork returns parent verbatim" do
      check all(
              ancestor <- line_list(),
              parent <- line_list(),
              max_runs: 100
            ) do
        assert {:ok, ^parent} = Diff.merge3(ancestor, ancestor, parent)
      end
    end

    property "merge3 with identical fork and parent returns that version" do
      check all(
              ancestor <- line_list(),
              changed <- line_list(),
              max_runs: 100
            ) do
        assert {:ok, ^changed} = Diff.merge3(ancestor, changed, changed)
      end
    end

    property "merge3 never crashes on arbitrary inputs" do
      check all(
              a <- line_list(),
              f <- line_list(),
              p <- line_list(),
              max_runs: 200
            ) do
        result = Diff.merge3(a, f, p)

        assert match?({:ok, _}, result) or match?({:conflict, _}, result)
      end
    end
  end
end
