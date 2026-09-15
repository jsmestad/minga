defmodule Minga.Buffer.CompletionCursorContextPerfTest do
  @moduledoc """
  Guards completion cursor-context work against document-size scaling.

  Run explicitly with:

      mix test --include perf test/perf/completion_cursor_context_perf_test.exs
  """

  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Buffer.CursorContext
  alias Minga.Buffer.Process, as: BufferProcess

  @moduletag :perf

  @small_lines 100
  @residence_limit_lines 65_536
  @line "αe\u0301_identifier_padding_for_completion"
  @warmup 50
  @samples 200
  @absolute_p95_limit_us 5_000
  @max_scaling_ratio 10
  @ratio_noise_floor_us 500

  test "copied bytes and p95 latency stay bounded at the supported residence limit" do
    small = start_buffer(@small_lines)
    large = start_buffer(@residence_limit_lines)

    small_context = Buffer.cursor_context(small)
    large_context = Buffer.cursor_context(large)

    assert copied_work_units(small_context) == byte_size(@line)
    assert copied_work_units(large_context) == byte_size(@line)
    assert :binary.referenced_byte_size(small_context.line_text) == byte_size(@line)
    assert :binary.referenced_byte_size(large_context.line_text) == byte_size(@line)

    small_p95 = measured_p95_us(small)
    large_p95 = measured_p95_us(large)

    assert small_p95 < @absolute_p95_limit_us
    assert large_p95 < @absolute_p95_limit_us
    assert large_p95 <= max(small_p95 * @max_scaling_ratio, @ratio_noise_floor_us)
  end

  @spec start_buffer(pos_integer()) :: pid()
  defp start_buffer(line_count) do
    content = String.duplicate(@line <> "\n", line_count - 1) <> @line
    {:ok, buffer} = BufferProcess.start_link(content: content)
    :ok = Buffer.move_to(buffer, {div(line_count, 2), byte_size("αe\u0301_identifier")})
    buffer
  end

  @spec copied_work_units(CursorContext.t()) :: non_neg_integer()
  defp copied_work_units(%CursorContext{line_text: line_text}), do: byte_size(line_text)

  @spec measured_p95_us(pid()) :: non_neg_integer()
  defp measured_p95_us(buffer) do
    for _ <- 1..@warmup, do: Buffer.cursor_context(buffer)

    durations =
      for _ <- 1..@samples do
        {duration, %CursorContext{}} = :timer.tc(Buffer, :cursor_context, [buffer])
        duration
      end

    sorted = Enum.sort(durations)
    Enum.at(sorted, floor(@samples * 0.95) - 1)
  end
end
