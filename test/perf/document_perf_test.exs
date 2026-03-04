defmodule Minga.Buffer.DocumentPerfTest do
  @moduledoc """
  Performance regression tests for `Document`.

  These tests verify the O(1) complexity guarantees introduced by the
  cursor/line_count caching optimization.  They are tagged `:perf` and
  excluded from the default `mix test` run.

  Run explicitly with:

      mix test --include perf test/perf/document_perf_test.exs

  ## What is tested

  The key invariant is that `cursor/1` and `line_count/1` execute in
  constant time — their latency must not grow with buffer size.  We
  verify this by measuring wall-clock time at three buffer sizes
  (small, medium, large) and asserting that the ratio between the
  large-buffer time and the small-buffer time stays below a cap of 20×.

  A cap of 20× is intentionally generous: pure O(1) operations typically
  come in under 2× across a 1 000× size difference.  The cap exists only
  to catch a true regression back to O(n) scanning (which would produce
  ratios in the hundreds or thousands for a 1M-line buffer).

  Mutation operations (`insert_char`, `delete_before`, `move_to`) are
  also spot-checked to ensure their incremental cache updates don't
  inadvertently re-introduce O(n) work.
  """

  use ExUnit.Case, async: false

  @moduletag :perf

  alias Minga.Buffer.Document

  # ── Buffer fixtures ───────────────────────────────────────────────────────

  # Each line is "hello world" (11 chars) + newline = 12 bytes.
  @line "hello world\n"

  @small_lines 1_000
  @medium_lines 100_000
  @large_lines 1_000_000

  # Number of times each operation is repeated inside a single measurement
  # to amortize :timer.tc overhead.
  @iterations 1_000

  # Maximum allowed ratio of large-buffer time to small-buffer time.
  # O(1) operations will be well under 5×; O(n) would be 1 000× or more.
  @max_ratio 20.0

  setup_all do
    small = build_buf(@small_lines)
    medium = build_buf(@medium_lines)
    large = build_buf(@large_lines)
    %{small: small, medium: medium, large: large}
  end

  # ── cursor/1 ─────────────────────────────────────────────────────────────

  describe "cursor/1 is O(1)" do
    test "small buffer: cursor completes in < 1ms per call", %{small: buf} do
      avg_us = avg_time_us(fn -> Document.cursor(buf) end)

      assert avg_us < 1_000,
             "cursor/1 on #{@small_lines}-line buffer took #{avg_us}µs (expected < 1ms)"
    end

    test "large buffer: cursor completes in < 1ms per call", %{large: buf} do
      avg_us = avg_time_us(fn -> Document.cursor(buf) end)

      assert avg_us < 1_000,
             "cursor/1 on #{@large_lines}-line buffer took #{avg_us}µs (expected < 1ms)"
    end

    test "cursor does not scale with buffer size", %{small: small, large: large} do
      small_us = avg_time_us(fn -> Document.cursor(small) end)
      large_us = avg_time_us(fn -> Document.cursor(large) end)

      ratio = if small_us > 0, do: large_us / small_us, else: 1.0

      assert ratio < @max_ratio,
             """
             cursor/1 time ratio exceeded O(1) cap.
             small (#{@small_lines} lines): #{fmt(small_us)}µs avg
             large (#{@large_lines} lines): #{fmt(large_us)}µs avg
             ratio: #{Float.round(ratio, 2)}× (must be < #{@max_ratio}×)
             This indicates a regression back to O(n) scanning.
             """
    end
  end

  # ── line_count/1 ─────────────────────────────────────────────────────────

  describe "line_count/1 is O(1)" do
    test "small buffer: line_count completes in < 1ms per call", %{small: buf} do
      avg_us = avg_time_us(fn -> Document.line_count(buf) end)
      assert avg_us < 1_000, "line_count/1 on #{@small_lines}-line buffer took #{avg_us}µs"
    end

    test "large buffer: line_count completes in < 1ms per call", %{large: buf} do
      avg_us = avg_time_us(fn -> Document.line_count(buf) end)
      assert avg_us < 1_000, "line_count/1 on #{@large_lines}-line buffer took #{avg_us}µs"
    end

    test "line_count does not scale with buffer size", %{small: small, large: large} do
      small_us = avg_time_us(fn -> Document.line_count(small) end)
      large_us = avg_time_us(fn -> Document.line_count(large) end)

      ratio = if small_us > 0, do: large_us / small_us, else: 1.0

      assert ratio < @max_ratio,
             """
             line_count/1 time ratio exceeded O(1) cap.
             small (#{@small_lines} lines): #{fmt(small_us)}µs avg
             large (#{@large_lines} lines): #{fmt(large_us)}µs avg
             ratio: #{Float.round(ratio, 2)}× (must be < #{@max_ratio}×)
             """
    end
  end

  # ── Mutation operations ───────────────────────────────────────────────────

  describe "insert_char/2 cache update is fast" do
    test "insert at cursor on large buffer stays under 1ms", %{large: buf} do
      avg_us = avg_time_us(fn -> Document.insert_char(buf, "x") end)
      assert avg_us < 1_000, "insert_char/2 on #{@large_lines}-line buffer took #{avg_us}µs"
    end

    test "insert_char does not scale with buffer size", %{small: small, large: large} do
      small_us = avg_time_us(fn -> Document.insert_char(small, "x") end)
      large_us = avg_time_us(fn -> Document.insert_char(large, "x") end)

      ratio = if small_us > 0, do: large_us / small_us, else: 1.0

      assert ratio < @max_ratio,
             """
             insert_char/2 time ratio exceeded cap.
             small: #{fmt(small_us)}µs  large: #{fmt(large_us)}µs  ratio: #{Float.round(ratio, 2)}×
             """
    end
  end

  describe "delete_before/1 cache update adds no measurable overhead" do
    @doc """
    `delete_before` is inherently O(|before|) because `pop_last_grapheme`
    must scan `before` to find the last grapheme boundary.  Our optimization
    eliminated the *additional* O(|before|) cost of recomputing the cursor
    after deletion.

    We test this by placing the cursor near the start of a huge buffer so
    `before` is only a few bytes.  The operation must be fast regardless of
    total buffer size, proving the cache update itself is O(1).
    """
    test "delete_before is fast when before is short, even on a large buffer", %{large: buf} do
      # Cursor at {0, 5}: before = "hello" (5 bytes), after_ = the rest of the 1M-line buffer.
      buf_near_start = Document.move_to(buf, {0, 5})
      avg_us = avg_time_us(fn -> Document.delete_before(buf_near_start) end)

      assert avg_us < 1_000,
             "delete_before/1 with short `before` on large buffer took #{avg_us}µs (expected < 1ms)"
    end

    test "delete_before speed is proportional to before length, not total buffer size" do
      # Build two buffers with different total sizes but the same short `before`.
      buf_small =
        Document.new(String.duplicate(@line, @small_lines)) |> Document.move_to({0, 5})

      buf_large =
        Document.new(String.duplicate(@line, @large_lines)) |> Document.move_to({0, 5})

      small_us = avg_time_us(fn -> Document.delete_before(buf_small) end)
      large_us = avg_time_us(fn -> Document.delete_before(buf_large) end)

      ratio = if small_us > 0, do: large_us / small_us, else: 1.0

      assert ratio < @max_ratio,
             """
             delete_before/1 scaled with total buffer size (not just `before` length).
             small (#{@small_lines} lines, before=5 chars): #{fmt(small_us)}µs
             large (#{@large_lines} lines, before=5 chars): #{fmt(large_us)}µs
             ratio: #{Float.round(ratio, 2)}× (must be < #{@max_ratio}×)
             """
    end
  end

  describe "cursor_offset/1 is O(1)" do
    test "cursor_offset does not scan the buffer", %{small: small, large: large} do
      small_us = avg_time_us(fn -> Document.cursor_offset(small) end)
      large_us = avg_time_us(fn -> Document.cursor_offset(large) end)

      ratio = if small_us > 0, do: large_us / small_us, else: 1.0

      assert ratio < @max_ratio,
             "cursor_offset/1 scaled unexpectedly: #{Float.round(ratio, 2)}×"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Builds a gap buffer with `n` lines, cursor at the start.
  @spec build_buf(pos_integer()) :: Document.t()
  defp build_buf(n) do
    Document.new(String.duplicate(@line, n))
  end

  # Runs `fun` @iterations times and returns the average wall-clock time in microseconds.
  @spec avg_time_us((-> term())) :: float()
  defp avg_time_us(fun) do
    {total_us, _} = :timer.tc(fn -> Enum.each(1..@iterations, fn _ -> fun.() end) end)
    total_us / @iterations
  end

  # Formats a float µs value for assertion messages.
  @spec fmt(float()) :: String.t()
  defp fmt(us) when us < 1.0, do: "<1"
  defp fmt(us), do: to_string(Float.round(us, 2))
end
