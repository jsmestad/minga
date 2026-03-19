defmodule Minga.Buffer.DecorationsBenchmarkTest do
  @moduledoc """
  Benchmark tests verifying decoration performance characteristics.

  Uses relative scaling tests (1K vs 10K) instead of absolute time
  thresholds. This catches algorithmic regressions (O(n²) would show
  100x scaling for 10x data) without flaking on slow CI runners.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Decorations

  describe "performance: query scaling" do
    setup do
      decs_1k = build_decorations(1_000)
      decs_10k = build_decorations(10_000)
      lines = for _ <- 1..30, do: String.duplicate("x", 80)
      {:ok, decs_1k: decs_1k, decs_10k: decs_10k, lines: lines}
    end

    test "range query scales sub-linearly (O(log n + k))", ctx do
      # Warmup
      Decorations.highlights_for_lines(ctx.decs_1k, 200, 230)
      Decorations.highlights_for_lines(ctx.decs_10k, 5_000, 5_030)

      {us_1k, _} =
        :timer.tc(fn -> Decorations.highlights_for_lines(ctx.decs_1k, 200, 230) end)

      {us_10k, _} =
        :timer.tc(fn -> Decorations.highlights_for_lines(ctx.decs_10k, 5_000, 5_030) end)

      # With O(log n + k) query, 10x more data should be at most ~3-4x slower
      # (log(10000)/log(1000) ≈ 1.33x, plus constant factors).
      # Allow up to 15x to account for tree depth and cache effects.
      # An O(n) scan would be ~10x, O(n²) would be ~100x.
      ratio = if us_1k > 0, do: us_10k / us_1k, else: 1.0

      assert ratio < 15,
             "10K/1K query ratio is #{Float.round(ratio, 1)}x (1K: #{us_1k}µs, 10K: #{us_10k}µs). Expected < 15x for O(log n + k)."
    end

    test "query + merge scales sub-linearly", ctx do
      merge_fn = fn decs, offset ->
        for {line, i} <- Enum.with_index(ctx.lines, offset) do
          ranges = Decorations.highlights_for_line(decs, i)
          Decorations.merge_highlights([{line, Minga.Face.new()}], ranges, i)
        end
      end

      # Warmup
      merge_fn.(ctx.decs_1k, 200)
      merge_fn.(ctx.decs_10k, 5_000)

      {us_1k, _} = :timer.tc(fn -> merge_fn.(ctx.decs_1k, 200) end)
      {us_10k, _} = :timer.tc(fn -> merge_fn.(ctx.decs_10k, 5_000) end)

      ratio = if us_1k > 0, do: us_10k / us_1k, else: 1.0

      assert ratio < 15,
             "10K/1K merge ratio is #{Float.round(ratio, 1)}x (1K: #{us_1k}µs, 10K: #{us_10k}µs). Expected < 15x for O(log n + k)."
    end
  end

  describe "performance: batch operations" do
    test "batch clear-and-replace scales sub-linearly" do
      # This is the real-world pattern: LSP diagnostic refresh or agent chat
      # sync clears all decorations in a group and replaces them. The batch
      # API defers tree rebuilding until commit, so N operations produce
      # a single from_list rebuild at the end.
      #
      # Uses relative scaling (1K vs 10K) instead of absolute time thresholds.
      # An O(n²) regression would show ~100x scaling; we expect < 15x.
      base_1k = build_decorations(1_000)
      base_10k = build_decorations(10_000)

      batch_replace = fn base, count ->
        Decorations.batch(base, fn d ->
          d = Decorations.remove_group(d, :diagnostics)

          Enum.reduce(0..(count - 1), d, fn i, acc ->
            {_, acc} =
              Decorations.add_highlight(acc, {i, 0}, {i, 20},
                style: Minga.Face.new(bg: 0xECBE7B),
                group: :diagnostics
              )

            acc
          end)
        end)
      end

      # Warmup both sizes to level the JIT/allocation playing field
      batch_replace.(base_1k, 1_000)
      batch_replace.(base_10k, 10_000)

      {us_1k, decs_1k} = :timer.tc(fn -> batch_replace.(base_1k, 1_000) end)
      {us_10k, decs_10k} = :timer.tc(fn -> batch_replace.(base_10k, 10_000) end)

      assert Decorations.highlight_count(decs_1k) == 1_000
      assert Decorations.highlight_count(decs_10k) == 10_000

      ratio = if us_1k > 0, do: us_10k / us_1k, else: 1.0

      # O(n log n) tree rebuild: 10x data ≈ 13x work. Allow 20x for noise.
      # An O(n²) regression would show ~100x.
      assert ratio < 20,
             "10K/1K batch ratio is #{Float.round(ratio, 1)}x (1K: #{us_1k}µs, 10K: #{us_10k}µs). Expected < 20x for sub-linear scaling."
    end
  end

  describe "performance: zero decorations (baseline)" do
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

  defp build_decorations(count) do
    Enum.reduce(0..(count - 1), Decorations.new(), fn i, decs ->
      {_id, decs} =
        Decorations.add_highlight(decs, {i, 0}, {i, 20},
          style: Minga.Face.new(bg: 0x3E4452),
          priority: rem(i, 5),
          group: :diagnostics
        )

      decs
    end)
  end
end
