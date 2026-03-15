defmodule Minga.Telemetry do
  @moduledoc """
  Thin convenience wrapper around `:telemetry` for Minga's instrumentation.

  Follows the same pattern as `Minga.Log` (wraps `Logger`): standardizes
  a stdlib interface for project conventions. All event names start with
  `[:minga, ...]`.

  ## Event Naming

  Events follow the `:telemetry` convention of atom lists:

      [:minga, :render, :pipeline]   # full render frame
      [:minga, :render, :stage]      # individual render stage
      [:minga, :input, :dispatch]    # keystroke dispatch
      [:minga, :command, :execute]   # command execution
      [:minga, :port, :emit]         # port command emission

  ## Zero Overhead

  `:telemetry.span/3` calls `System.monotonic_time/0` twice and wraps
  the function in a closure. Cost is ~100ns per span. On a 16ms frame
  budget with ~10 spans, that's noise. When no handler is attached,
  the event emission is a no-op ETS lookup.
  """

  @doc """
  Wraps a function call in a `:telemetry` span.

  Emits `event ++ [:start]` before the function runs, and
  `event ++ [:stop]` (or `event ++ [:exception]`) after. The span
  measurements include `:duration` in native time units.

  ## Examples

      Telemetry.span([:minga, :render, :stage], %{stage: :content}, fn ->
        build_content(state, scrolls)
      end)

  """
  @spec span([atom()], map(), (-> result)) :: result when result: var
  def span(event, metadata, fun)
      when is_list(event) and is_map(metadata) and is_function(fun, 0) do
    :telemetry.span(event, metadata, fn ->
      {fun.(), metadata}
    end)
  end

  @doc """
  Emits a single telemetry event (fire-and-forget, no span).

  Use for point-in-time measurements like byte counts or counters
  that don't wrap a duration.

  ## Examples

      Telemetry.execute([:minga, :port, :emit], %{byte_count: 4096}, %{})

  """
  @spec execute([atom()], map(), map()) :: :ok
  def execute(event, measurements, metadata)
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event, measurements, metadata)
  end
end
