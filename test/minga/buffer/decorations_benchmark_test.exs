defmodule Minga.Buffer.DecorationsBenchmarkTest do
  @moduledoc """
  Benchmark tests verifying that decoration operations meet performance
  requirements: range query + style merge with 1,000 and 10,000 decorations
  must complete in sub-millisecond time per frame.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Decorations

  describe "performance: 1,000 decorations" do
    setup do
      decs = build_decorations(1_000)
      {:ok, decs: decs}
    end

    test "range query for 30-line viewport completes in under 1ms", %{decs: decs} do
      # Simulate querying visible lines (a typical viewport shows ~30-50 lines)
      {elapsed_us, results} =
        :timer.tc(fn ->
          Decorations.highlights_for_lines(decs, 200, 230)
        end)

      assert is_list(results)
      # Must be under 1ms (1000 microseconds)
      assert elapsed_us < 1_000,
             "Query took #{elapsed_us}µs, expected < 1000µs with 1,000 decorations"
    end

    test "range query + style merge for 30 lines completes in under 1ms", %{decs: decs} do
      # Build 30 lines of typical content
      lines = for _ <- 1..30, do: String.duplicate("x", 80)

      {elapsed_us, _} =
        :timer.tc(fn ->
          for {line, i} <- Enum.with_index(lines, 200) do
            ranges = Decorations.highlights_for_line(decs, i)
            Decorations.merge_highlights([{line, []}], ranges, i)
          end
        end)

      assert elapsed_us < 1_000,
             "Query + merge took #{elapsed_us}µs, expected < 1000µs with 1,000 decorations"
    end
  end

  describe "performance: 10,000 decorations" do
    setup do
      decs = build_decorations(10_000)
      {:ok, decs: decs}
    end

    test "range query for 30-line viewport completes in under 2ms", %{decs: decs} do
      {elapsed_us, results} =
        :timer.tc(fn ->
          Decorations.highlights_for_lines(decs, 5_000, 5_030)
        end)

      assert is_list(results)
      # Allow 2ms for 10k decorations (still well within a 16ms frame budget)
      assert elapsed_us < 2_000,
             "Query took #{elapsed_us}µs, expected < 2000µs with 10,000 decorations"
    end

    test "range query + style merge for 30 lines completes in under 2ms", %{decs: decs} do
      lines = for _ <- 1..30, do: String.duplicate("x", 80)

      {elapsed_us, _} =
        :timer.tc(fn ->
          for {line, i} <- Enum.with_index(lines, 5_000) do
            ranges = Decorations.highlights_for_line(decs, i)
            Decorations.merge_highlights([{line, []}], ranges, i)
          end
        end)

      assert elapsed_us < 2_000,
             "Query + merge took #{elapsed_us}µs, expected < 2000µs with 10,000 decorations"
    end

    test "batch clear-and-replace of 10,000 decorations completes in under 50ms" do
      # This is the real-world pattern: LSP diagnostic refresh or agent chat
      # sync clears all decorations in a group and replaces them. The batch
      # API defers tree rebuilding until commit, so 10K operations produce
      # a single from_list rebuild at the end.
      base_decs = build_decorations(10_000)

      {elapsed_us, decs} =
        :timer.tc(fn ->
          Decorations.batch(base_decs, fn d ->
            d = Decorations.remove_group(d, :diagnostics)

            Enum.reduce(0..9_999, d, fn i, acc ->
              {_, acc} =
                Decorations.add_highlight(acc, {i, 0}, {i, 20},
                  style: [bg: 0xECBE7B],
                  group: :diagnostics
                )

              acc
            end)
          end)
        end)

      assert Decorations.highlight_count(decs) == 10_000
      # Batch collects ops then does one from_list rebuild: O(n log n) with
      # low constant factor. Must stay under 50ms even on CI runners.
      assert elapsed_us < 50_000,
             "Batch clear+replace of 10,000 decorations took #{elapsed_us}µs, expected < 50000µs"
    end
  end

  describe "performance: zero decorations (baseline)" do
    test "empty decorations add zero overhead to line rendering" do
      decs = Decorations.new()
      line = String.duplicate("x", 80)

      {elapsed_us, _} =
        :timer.tc(fn ->
          for i <- 0..999 do
            ranges = Decorations.highlights_for_line(decs, i)
            Decorations.merge_highlights([{line, []}], ranges, i)
          end
        end)

      # 1000 lines with empty decorations should take essentially zero time
      assert elapsed_us < 500,
             "Empty decorations took #{elapsed_us}µs for 1000 lines, expected < 500µs"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp build_decorations(count) do
    Enum.reduce(0..(count - 1), Decorations.new(), fn i, decs ->
      {_id, decs} =
        Decorations.add_highlight(decs, {i, 0}, {i, 20},
          style: [bg: 0x3E4452],
          priority: rem(i, 5),
          group: :diagnostics
        )

      decs
    end)
  end
end
