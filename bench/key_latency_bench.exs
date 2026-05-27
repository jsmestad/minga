defmodule Minga.Bench.KeyLatency do
  @moduledoc false

  alias Minga.Test.EditorCase
  alias Minga.Test.HeadlessPort

  @events [
    [:minga, :input, :dispatch, :stop],
    [:minga, :render, :pipeline, :stop],
    [:minga, :render, :stage, :stop],
    [:minga, :render, :emit_prepare, :stop]
  ]

  @runs 5
  @warmup_keys 20
  @measured_keys 120
  @width 100
  @height 40

  def run do
    parent = self()
    handler_id = "minga-key-latency-bench-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      @events,
      fn event, measurements, metadata, _config ->
        send(parent, {:bench_telemetry, event, measurements, metadata})
      end,
      nil
    )

    try do
      results = for _ <- 1..@runs, do: run_once()
      emit_metrics(results)
    after
      :telemetry.detach(handler_id)
    end
  end

  defp run_once do
    registry = :"minga_bench_events_#{System.unique_integer([:positive])}"
    {:ok, _events} = Registry.start_link(keys: :duplicate, name: registry)

    ctx =
      EditorCase.start_editor(
        document(),
        width: @width,
        height: @height,
        file_path: "bench_elixir.ex",
        events_registry: registry
      )

    try do
      warmup_motion(ctx)
      motion = measure_keys(ctx, List.duplicate(?j, @measured_keys))
      enter_insert(ctx)
      warmup_insert(ctx)
      insert = measure_keys(ctx, List.duplicate(?a, @measured_keys))

      %{
        motion: summarize(motion),
        insert: summarize(insert)
      }
    after
      stop_if_alive(ctx.editor)
      stop_if_alive(ctx.buffer)
      stop_if_alive(ctx.port)
      stop_if_alive(Process.whereis(registry))
    end
  end

  defp document do
    1..2_000
    |> Enum.map_join("\n", fn i -> "line #{i} alpha beta gamma delta epsilon zeta eta theta" end)
  end

  defp warmup_motion(ctx), do: Enum.each(List.duplicate(?j, @warmup_keys), &send_key(ctx, &1))

  defp enter_insert(ctx), do: send_key(ctx, ?i)

  defp warmup_insert(ctx), do: Enum.each(List.duplicate(?a, @warmup_keys), &send_key(ctx, &1))

  defp measure_keys(ctx, keys) do
    drain_events([])
    Enum.map(keys, fn key -> send_key(ctx, key) end)
  end

  defp send_key(%{editor: editor, port: port}, codepoint) do
    _ = :sys.get_state(editor)
    ref = HeadlessPort.prepare_await(port)
    started_at = System.monotonic_time(:microsecond)
    send(editor, {:minga_input, {:key_press, codepoint, 0}})

    case HeadlessPort.collect_frame(ref, 5_000) do
      {:ok, _snapshot} ->
        stopped_at = System.monotonic_time(:microsecond)
        events = drain_events([])
        %{wall_us: stopped_at - started_at, events: events}

      {:error, :timeout} ->
        raise "timed out waiting for rendered frame after key #{inspect(codepoint)}"
    end
  end

  defp drain_events(acc) do
    receive do
      {:bench_telemetry, event, measurements, metadata} ->
        drain_events([%{event: event, measurements: measurements, metadata: metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp summarize(samples) do
    wall = Enum.map(samples, & &1.wall_us)
    events = Enum.flat_map(samples, & &1.events)

    %{
      median_wall_us: median(wall),
      p95_wall_us: percentile(wall, 0.95),
      input_us: median_duration(events, [:minga, :input, :dispatch, :stop]),
      render_us: median_duration(events, [:minga, :render, :pipeline, :stop]),
      port_us: median_duration(events, [:minga, :render, :emit_prepare, :stop]),
      content_us: median_stage_duration(events, :content),
      chrome_us: median_stage_duration(events, :chrome),
      emit_us: median_stage_duration(events, :emit)
    }
  end

  defp median_duration(events, event_name) do
    events
    |> Enum.filter(&(&1.event == event_name))
    |> Enum.map(&native_to_us(&1.measurements.duration))
    |> median()
  end

  defp median_stage_duration(events, stage) do
    events
    |> Enum.filter(&(&1.event == [:minga, :render, :stage, :stop] and &1.metadata.stage == stage))
    |> Enum.map(&native_to_us(&1.measurements.duration))
    |> median()
  end

  defp native_to_us(duration), do: System.convert_time_unit(duration, :native, :microsecond)

  defp emit_metrics(results) do
    insert_summaries = Enum.map(results, & &1.insert)
    motion_summaries = Enum.map(results, & &1.motion)

    metrics = %{
      "key_latency_us" => median_field(insert_summaries, :median_wall_us),
      "insert_p95_us" => median_field(insert_summaries, :p95_wall_us),
      "motion_latency_us" => median_field(motion_summaries, :median_wall_us),
      "input_dispatch_us" => median_field(insert_summaries, :input_us),
      "render_us" => median_field(insert_summaries, :render_us),
      "emit_prepare_us" => median_field(insert_summaries, :port_us),
      "content_stage_us" => median_field(insert_summaries, :content_us),
      "chrome_stage_us" => median_field(insert_summaries, :chrome_us),
      "emit_stage_us" => median_field(insert_summaries, :emit_us)
    }

    Enum.each(metrics, fn {name, value} -> IO.puts("METRIC #{name}=#{format_number(value)}") end)
  end

  defp median_field(summaries, field),
    do: summaries |> Enum.map(&Map.fetch!(&1, field)) |> median()

  defp median([]), do: 0

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, middle)
    else
      (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    end
  end

  defp percentile([], _ratio), do: 0

  defp percentile(values, ratio) do
    sorted = Enum.sort(values)
    index = max(0, ceil(length(sorted) * ratio) - 1)
    Enum.at(sorted, index)
  end

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)

  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end
end

Minga.Bench.KeyLatency.run()
