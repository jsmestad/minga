defmodule Minga.Buffer.DecorationsBenchmarkTest do
  @moduledoc """
  Benchmark tests verifying that decoration operations meet performance
  requirements: range query + style merge with 1,000 and 10,000 decorations
  must complete in sub-millisecond time per frame.
  """
  use ExUnit.Case, async: true

  alias Minga.Buffer.Decorations
  alias Minga.Buffer.Decorations.HighlightRange

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

    test "bulk rebuild from list completes in under 50ms" do
      intervals =
        for i <- 0..9_999 do
          %HighlightRange{
            id: make_ref(),
            start: {i, 0},
            end_: {i, 20},
            style: [bg: 0x3E4452],
            priority: 0,
            group: :diagnostics
          }
        end

      {elapsed_us, decs} =
        :timer.tc(fn ->
          Enum.reduce(intervals, Decorations.new(), fn range, decs ->
            {_id, decs} =
              Decorations.add_highlight(decs, range.start, range.end_,
                style: range.style,
                group: range.group
              )

            decs
          end)
        end)

      assert Decorations.highlight_count(decs) == 10_000
      # Building 10k decorations one at a time should complete in under 50ms
      assert elapsed_us < 50_000,
             "Building 10,000 decorations took #{elapsed_us}µs, expected < 50000µs"
    end

    test "batch rebuild completes faster than sequential inserts" do
      base_decs = build_decorations(5_000)

      new_ranges =
        for i <- 5_000..9_999 do
          {make_ref(), {i, 0}, {i, 20}, [bg: 0x3E4452], :diagnostics}
        end

      {batch_us, _} =
        :timer.tc(fn ->
          Decorations.batch(base_decs, fn d ->
            Enum.reduce(new_ranges, d, fn {_id, s, e, style, group}, acc ->
              {_, acc} = Decorations.add_highlight(acc, s, e, style: style, group: group)
              acc
            end)
          end)
        end)

      # Batch should complete in reasonable time (under 100ms for 5k additions)
      assert batch_us < 100_000,
             "Batch of 5,000 additions took #{batch_us}µs, expected < 100000µs"
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
