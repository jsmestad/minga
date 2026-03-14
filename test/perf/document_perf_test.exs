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

  # Number of warmup iterations to prime caches and JIT before measuring.
  @warmup 500

  # Number of times each operation is repeated inside a single measurement
  # to amortize :timer.tc overhead.
  @iterations 5_000

  # Maximum allowed ratio of large-buffer time to small-buffer time.
  # O(1) operations will be well under 5×; O(n) would be 1 000× or more.
  @max_ratio 20.0

  # When both measurements are below this threshold (µs), the ratio is
  # meaningless because we're dividing noise by noise. Skip the ratio
  # assertion and just verify both are fast in absolute terms.
  @noise_floor_us 0.5

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
      assert_no_scaling(small_us, large_us, "cursor/1")
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
      assert_no_scaling(small_us, large_us, "line_count/1")
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
      assert_no_scaling(small_us, large_us, "insert_char/2")
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
      assert_no_scaling(small_us, large_us, "delete_before/1")
    end
  end

  describe "cursor_offset/1 is O(1)" do
    test "cursor_offset does not scan the buffer", %{small: small, large: large} do
      small_us = avg_time_us(fn -> Document.cursor_offset(small) end)
      large_us = avg_time_us(fn -> Document.cursor_offset(large) end)
      assert_no_scaling(small_us, large_us, "cursor_offset/1")
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Builds a gap buffer with `n` lines, cursor at the start.
  @spec build_buf(pos_integer()) :: Document.t()
  defp build_buf(n) do
    Document.new(String.duplicate(@line, n))
  end

  # Runs `fun` with warmup, then measures @iterations and returns the
  # average wall-clock time in microseconds. The warmup pass primes CPU
  # caches and the BEAM JIT so the measurement reflects steady-state.
  @spec avg_time_us((-> term())) :: float()
  defp avg_time_us(fun) do
    Enum.each(1..@warmup, fn _ -> fun.() end)
    {total_us, _} = :timer.tc(fn -> Enum.each(1..@iterations, fn _ -> fun.() end) end)
    total_us / @iterations
  end

  # Asserts that the ratio of large-buffer time to small-buffer time stays
  # below @max_ratio. When both measurements are below the noise floor,
  # the ratio is meaningless (dividing sub-microsecond noise by noise), so
  # we skip the ratio check and only verify both are fast in absolute terms.
  @spec assert_no_scaling(float(), float(), String.t()) :: :ok
  defp assert_no_scaling(small_us, large_us, label) do
    if small_us < @noise_floor_us and large_us < @noise_floor_us do
      # Both are sub-microsecond. The operation is O(1) by any measure.
      # Ratio would be meaningless noise, so just verify absolute speed.
      assert large_us < 1_000,
             "#{label} on large buffer took #{fmt(large_us)}µs (expected < 1ms)"
    else
      ratio = if small_us > 0, do: large_us / small_us, else: 1.0

      assert ratio < @max_ratio,
             """
             #{label} time ratio exceeded O(1) cap.
             small: #{fmt(small_us)}µs  large: #{fmt(large_us)}µs
             ratio: #{Float.round(ratio, 2)}× (must be < #{@max_ratio}×)
             """
    end

    :ok
  end

  # Formats a float µs value for assertion messages.
  @spec fmt(float()) :: String.t()
  defp fmt(us) when us < 1.0, do: "<1"
  defp fmt(us), do: to_string(Float.round(us, 2))
end
