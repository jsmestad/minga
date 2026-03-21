#!/usr/bin/env elixir
# Benchmarks Minga.Clipboard write latency as perceived by the Editor GenServer.
#
# Run with: mix run bench/clipboard_write.exs
#
# Measures wall-clock time for clipboard writes using the same path the
# editor uses (write_async for register sync, write for explicit "+" register).
# Reports min/max/mean for both sync and async paths.

alias Minga.Clipboard

warmup_runs = 3
bench_runs = 10

# Warm up (populate persistent_term cache, settle one-time costs)
for _ <- 1..warmup_runs do
  Clipboard.write("warmup")
end

# Benchmark synchronous write (used for explicit "+ register and reads)
sync_times =
  for _ <- 1..bench_runs do
    start = System.monotonic_time(:microsecond)
    Clipboard.write("benchmark text for clipboard latency measurement")
    elapsed = System.monotonic_time(:microsecond) - start
    elapsed
  end

# Benchmark async write (used for dd/yy/cc register sync)
async_times =
  for _ <- 1..bench_runs do
    start = System.monotonic_time(:microsecond)
    Clipboard.write_async("benchmark text for clipboard latency measurement")
    elapsed = System.monotonic_time(:microsecond) - start
    elapsed
  end

# Wait for async tasks to finish
Process.sleep(200)

sync_mean = div(Enum.sum(sync_times), length(sync_times))
async_mean = div(Enum.sum(async_times), length(async_times))

IO.puts("Clipboard.write/1 (sync) latency (#{length(sync_times)} runs)")
IO.puts("  Min:  #{Enum.min(sync_times)} µs")
IO.puts("  P50:  #{Enum.sort(sync_times) |> Enum.at(div(length(sync_times), 2))} µs")
IO.puts("  Mean: #{sync_mean} µs")
IO.puts("  Max:  #{Enum.max(sync_times)} µs")
IO.puts("")
IO.puts("Clipboard.write_async/1 latency (#{length(async_times)} runs)")
IO.puts("  Min:  #{Enum.min(async_times)} µs")
IO.puts("  P50:  #{Enum.sort(async_times) |> Enum.at(div(length(async_times), 2))} µs")
IO.puts("  Mean: #{async_mean} µs")
IO.puts("  Max:  #{Enum.max(async_times)} µs")
IO.puts("")
IO.puts("METRIC clipboard_write_µs=#{async_mean}")
IO.puts("METRIC sync_write_µs=#{sync_mean}")
