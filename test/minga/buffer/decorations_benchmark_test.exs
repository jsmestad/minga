defmodule Minga.Core.DecorationsBenchmarkTest do
  @moduledoc """
  Structural tests verifying decoration batch performance characteristics.

  Uses deterministic structural assertions (tree height, version bumps)
  instead of wall-clock timing. This proves the batch API uses O(n log n)
  single-rebuild rather than O(n²) repeated inserts, without flaking on
  slow CI runners.

  ## What we're proving

  1. **Deferred execution**: batch mode collects operations in a pending
     list and applies them all at once (single version bump, not N bumps)
  2. **Balanced rebuild**: the resulting tree has optimal height (proves
     `from_list` median-split, not sequential inserts)
  3. **Correctness at scale**: batch operations produce the right results
     with 1K and 10K decorations
  """
  use ExUnit.Case, async: true

  alias Minga.Core.Decorations

  describe "batch deferred execution" do
    test "batch commits with single version bump regardless of operation count" do
      base = build_decorations(100)
      original_version = base.version

      result =
        Decorations.batch(base, fn d ->
          d = Decorations.remove_group(d, :diagnostics)

          Enum.reduce(0..499, d, fn i, acc ->
            {_id, acc} =
              Decorations.add_highlight(acc, {i, 0}, {i, 20},
                style: Minga.Core.Face.new(bg: 0xECBE7B),
                group: :diagnostics
              )

            acc
          end)
        end)

      # Single version bump, not 501 (1 remove_group + 500 adds)
      assert result.version == original_version + 1
      assert Decorations.highlight_count(result) == 500
    end

    test "non-batch add_highlight bumps version per operation" do
      decs = Decorations.new()

      {_id, decs} =
        Decorations.add_highlight(decs, {0, 0}, {0, 10},
          style: Minga.Core.Face.new(bg: 0xFF0000),
          group: :test
        )

      v1 = decs.version

      {_id, decs} =
        Decorations.add_highlight(decs, {1, 0}, {1, 10},
          style: Minga.Core.Face.new(bg: 0xFF0000),
          group: :test
        )

      # Each non-batch operation bumps version individually
      assert decs.version == v1 + 1
    end

    test "batch with no operations still applies cleanly" do
      base = build_decorations(50)
      count_before = Decorations.highlight_count(base)

      result = Decorations.batch(base, fn d -> d end)

      assert Decorations.highlight_count(result) == count_before
    end
  end

  describe "batch produces optimally balanced tree" do
    test "1K batch rebuild has optimal tree height" do
      result = batch_replace(Decorations.new(), 1_000)

      assert Decorations.highlight_count(result) == 1_000
      # from_list median-split produces height = floor(log2(n)) + 1
      assert result.highlights.height == expected_from_list_height(1_000)
    end

    test "10K batch rebuild has optimal tree height" do
      result = batch_replace(Decorations.new(), 10_000)

      assert Decorations.highlight_count(result) == 10_000
      assert result.highlights.height == expected_from_list_height(10_000)
    end

    test "batch clear-and-replace preserves optimal height" do
      base = build_decorations(1_000)

      result =
        Decorations.batch(base, fn d ->
          d = Decorations.remove_group(d, :diagnostics)

          Enum.reduce(0..4_999, d, fn i, acc ->
            {_id, acc} =
              Decorations.add_highlight(acc, {i, 0}, {i, 20},
                style: Minga.Core.Face.new(bg: 0xECBE7B),
                group: :diagnostics
              )

            acc
          end)
        end)

      assert Decorations.highlight_count(result) == 5_000
      assert result.highlights.height == expected_from_list_height(5_000)
    end

    test "overlapping intervals do not affect tree balance" do
      # 100 intervals all on line 0 with overlapping columns
      result =
        Decorations.batch(Decorations.new(), fn d ->
          Enum.reduce(0..99, d, fn i, acc ->
            {_id, acc} =
              Decorations.add_highlight(acc, {0, i}, {0, i + 20},
                style: Minga.Core.Face.new(bg: 0xECBE7B),
                group: :test
              )

            acc
          end)
        end)

      assert Decorations.highlight_count(result) == 100
      assert result.highlights.height == expected_from_list_height(100)
    end
  end

  describe "batch correctness at scale" do
    test "batch clear-and-replace at 1K produces correct query results" do
      base = build_decorations(1_000)

      result =
        Decorations.batch(base, fn d ->
          d = Decorations.remove_group(d, :diagnostics)

          Enum.reduce(0..999, d, fn i, acc ->
            {_id, acc} =
              Decorations.add_highlight(acc, {i, 0}, {i, 20},
                style: Minga.Core.Face.new(bg: 0xECBE7B),
                group: :diagnostics
              )

            acc
          end)
        end)

      assert Decorations.highlight_count(result) == 1_000

      # Query a specific range and verify results
      highlights = Decorations.highlights_for_lines(result, 500, 509)
      assert length(highlights) == 10
    end

    test "batch clear-and-replace at 10K produces correct query results" do
      base = build_decorations(10_000)

      result =
        Decorations.batch(base, fn d ->
          d = Decorations.remove_group(d, :diagnostics)

          Enum.reduce(0..9_999, d, fn i, acc ->
            {_id, acc} =
              Decorations.add_highlight(acc, {i, 0}, {i, 20},
                style: Minga.Core.Face.new(bg: 0xECBE7B),
                group: :diagnostics
              )

            acc
          end)
        end)

      assert Decorations.highlight_count(result) == 10_000

      # Query a 30-line viewport window in the middle
      highlights = Decorations.highlights_for_lines(result, 5_000, 5_029)
      assert length(highlights) == 30
    end

    test "batch on empty decorations works" do
      result =
        Decorations.batch(Decorations.new(), fn d ->
          Enum.reduce(0..9, d, fn i, acc ->
            {_id, acc} =
              Decorations.add_highlight(acc, {i, 0}, {i, 10},
                style: Minga.Core.Face.new(bg: 0xECBE7B),
                group: :test
              )

            acc
          end)
        end)

      assert Decorations.highlight_count(result) == 10
      assert result.highlights.height == expected_from_list_height(10)
    end

    test "batch that only removes produces correct results" do
      base = build_decorations(100)
      assert Decorations.highlight_count(base) == 100

      result =
        Decorations.batch(base, fn d ->
          Decorations.remove_group(d, :diagnostics)
        end)

      assert Decorations.highlight_count(result) == 0
      assert Decorations.empty?(result)
    end
  end

  describe "query correctness at scale" do
    test "range query returns correct results from 10K-decoration tree" do
      decs = build_decorations(10_000)

      # Query a 30-line viewport window
      highlights = Decorations.highlights_for_lines(decs, 5_000, 5_029)
      assert length(highlights) == 30

      # Each result should be on the expected line (sort since tree traversal order varies)
      lines = highlights |> Enum.map(fn hl -> elem(hl.start, 0) end) |> Enum.sort()
      assert lines == Enum.to_list(5_000..5_029)
    end

    test "query + merge produces correct highlight segments at scale" do
      decs = build_decorations(10_000)
      lines = for _ <- 1..30, do: String.duplicate("x", 80)

      merged =
        for {line, i} <- Enum.with_index(lines, 5_000) do
          ranges = Decorations.highlights_for_line(decs, i)
          Decorations.merge_highlights([{line, Minga.Core.Face.new()}], ranges, i)
        end

      # Should produce 30 lines of merged results
      assert length(merged) == 30
      # Each merged line should have segments (not be empty)
      assert Enum.all?(merged, fn segments -> segments != [] end)
    end
  end

  describe "zero decorations baseline" do
    test "empty decorations short-circuit without allocations" do
      decs = Decorations.new()

      assert Decorations.empty?(decs)
      assert Decorations.highlights_for_line(decs, 0) == []
      assert Decorations.highlights_for_lines(decs, 0, 100) == []
      assert Decorations.highlight_count(decs) == 0
      refute Decorations.has_virtual_texts?(decs)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Computes the expected height of a perfectly balanced tree built by
  # from_list's median-split algorithm (splits at div(n, 2) each level;
  # see IntervalTree.build_balanced/1).
  @spec expected_from_list_height(non_neg_integer()) :: non_neg_integer()
  defp expected_from_list_height(0), do: 0
  defp expected_from_list_height(n), do: trunc(:math.log2(n)) + 1

  # Runs a batch that clears diagnostics and adds `count` new ones.
  @spec batch_replace(Decorations.t(), non_neg_integer()) :: Decorations.t()
  defp batch_replace(base, count) do
    Decorations.batch(base, fn d ->
      d = Decorations.remove_group(d, :diagnostics)

      Enum.reduce(0..(count - 1), d, fn i, acc ->
        {_id, acc} =
          Decorations.add_highlight(acc, {i, 0}, {i, 20},
            style: Minga.Core.Face.new(bg: 0xECBE7B),
            group: :diagnostics
          )

        acc
      end)
    end)
  end

  @spec build_decorations(pos_integer()) :: Decorations.t()
  defp build_decorations(count) do
    Enum.reduce(0..(count - 1), Decorations.new(), fn i, decs ->
      {_id, decs} =
        Decorations.add_highlight(decs, {i, 0}, {i, 20},
          style: Minga.Core.Face.new(bg: 0x3E4452),
          priority: rem(i, 5),
          group: :diagnostics
        )

      decs
    end)
  end
end
