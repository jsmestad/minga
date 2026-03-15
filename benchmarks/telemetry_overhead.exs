# Benchmark: telemetry span overhead with no handler attached.
#
# Run with: mix run benchmarks/telemetry_overhead.exs
#
# Verifies AC 4 of ticket #527: "Zero measurable overhead when no
# handler is attached."

alias Minga.Telemetry

# Detach all handlers so we measure the "no handler" case
Minga.Telemetry.DevHandler.detach()

fun = fn -> :ok end

Benchee.run(
  %{
    "direct_call" => fn -> fun.() end,
    "telemetry_span_no_handler" => fn ->
      Telemetry.span([:minga, :benchmark, :noop], %{}, fun)
    end
  },
  time: 2,
  warmup: 1,
  memory_time: 1,
  print: [fast_warning: false]
)
