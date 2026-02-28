#!/usr/bin/env elixir
# Benchee benchmark for GapBuffer cursor/line_count caching.
#
# Run with:
#   mix run bench/gap_buffer.exs
#
# This script builds buffers at three sizes and runs Benchee across the
# key operations to give a human-readable performance report.  Not part
# of CI — run manually when investigating latency.

alias Minga.Buffer.GapBuffer

line = "hello world\n"

IO.puts("Building buffers (cursor at {0, 0})...")

# Buffers with cursor at position {0, 0} — `before` is empty.
# insert_char appends to `before`, so the inherent copy cost is O(0) = O(1).
# This isolates the cache-update cost from gap-buffer structural costs.
start_bufs = %{
  "1K lines" => GapBuffer.new(String.duplicate(line, 1_000)),
  "100K lines" => GapBuffer.new(String.duplicate(line, 100_000)),
  "1M lines" => GapBuffer.new(String.duplicate(line, 1_000_000))
}

# Buffers positioned near the start (before = "hello", 5 bytes) for delete_before.
# delete_before scans `before` to find the last grapheme, so we keep it short
# to isolate the cache-update cost from the grapheme-scan cost.
near_start_bufs = %{
  "1K lines (before=5)" => GapBuffer.new(String.duplicate(line, 1_000)) |> GapBuffer.move_to({0, 5}),
  "100K lines (before=5)" => GapBuffer.new(String.duplicate(line, 100_000)) |> GapBuffer.move_to({0, 5}),
  "1M lines (before=5)" => GapBuffer.new(String.duplicate(line, 1_000_000)) |> GapBuffer.move_to({0, 5})
}

IO.puts("Running benchmarks...\n")

IO.puts("=== cursor/1 and line_count/1 (O(1) — should not scale with buffer size) ===\n")

Benchee.run(
  %{
    "cursor/1" => fn {_label, buf} -> GapBuffer.cursor(buf) end,
    "line_count/1" => fn {_label, buf} -> GapBuffer.line_count(buf) end,
    "cursor_offset/1" => fn {_label, buf} -> GapBuffer.cursor_offset(buf) end
  },
  inputs: start_bufs,
  time: 3,
  memory_time: 1,
  formatters: [Benchee.Formatters.Console],
  print: [benchmarking: true, configuration: false, fast_warning: true]
)

IO.puts("\n=== insert_char/2 — O(|char|) at cursor {0,0} ===\n")

Benchee.run(
  %{
    "insert_char/2 single char" => fn {_label, buf} -> GapBuffer.insert_char(buf, "x") end,
    "insert_char/2 newline" => fn {_label, buf} -> GapBuffer.insert_char(buf, "\n") end
  },
  inputs: start_bufs,
  time: 3,
  memory_time: 1,
  formatters: [Benchee.Formatters.Console],
  print: [benchmarking: true, configuration: false, fast_warning: true]
)

IO.puts("\n=== delete_before/1 — O(|before|), before=5 bytes in all cases ===\n")
IO.puts("(Timing should be ~equal across buffer sizes — only cache-update overhead varies.)\n")

Benchee.run(
  %{
    "delete_before/1" => fn {_label, buf} -> GapBuffer.delete_before(buf) end
  },
  inputs: near_start_bufs,
  time: 3,
  memory_time: 1,
  formatters: [Benchee.Formatters.Console],
  print: [benchmarking: true, configuration: false, fast_warning: true]
)
