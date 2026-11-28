# Spike #4387, live check. Starts the real editor with the native macOS frontend, opens a large
# file, and streams edits into it from inside the same VM while recording render telemetry.
#
#   RUN_LIVE_FILE=/path/to/50000-line.txt RUN_LIVE_OUT=/path/result.json RUN_LIVE_SCENARIO=A|B \
#     mix run --no-start bench/run_buffer_live.exs
#
# A: one writer inserts at the end. B: a second writer also inserts at line RUN_LIVE_MID.
alias Minga.Buffer.EditSource
alias Minga.Buffer.Process, as: BufferProcess

path = System.fetch_env!("RUN_LIVE_FILE")
out = System.fetch_env!("RUN_LIVE_OUT")
scenario = System.get_env("RUN_LIVE_SCENARIO", "B")
hz = String.to_integer(System.get_env("RUN_LIVE_HZ", "30"))
seconds = String.to_integer(System.get_env("RUN_LIVE_SECONDS", "10"))
mid0 = String.to_integer(System.get_env("RUN_LIVE_MID", "10500"))

Minga.SafeMode.put(true)
Application.put_env(:minga, :start_editor, true)
Application.put_env(:minga, :backend, :gui)
Mix.Task.run("app.start")

pct = fn list, p ->
  case Enum.sort(list) do
    [] -> nil
    s -> Enum.at(s, min(length(s) - 1, trunc(p * length(s))))
  end
end

spawn(fn ->
  Process.sleep(String.to_integer(System.get_env("RUN_LIVE_WARMUP_MS", "15000")))
  editor = Process.whereis(MingaEditor)
  buffer = :sys.get_state(editor).workspace.buffers.active
  table = :ets.new(:live, [:public, :duplicate_bag])

  events = [
    [:minga, :render, :pipeline, :stop],
    [:minga, :render, :pipeline, :exception],
    [:minga, :render, :line_fetch],
    [:minga, :render, :emit_prepare, :stop]
  ]

  :telemetry.attach_many(
    "run-live",
    events,
    fn event, meas, meta, t ->
      small =
        meta
        |> Map.take([
          :rows_rasterized,
          :full_residence?,
          :byte_count,
          :line_count,
          :count,
          :lines
        ])
        |> Map.put(:keys, Map.keys(meta))

      :ets.insert(t, {event, System.monotonic_time(:microsecond), meas, small})
    end,
    table
  )

  sampler =
    spawn(fn ->
      Stream.repeatedly(fn ->
        {:message_queue_len, n} = Process.info(editor, :message_queue_len)
        :ets.insert(table, {:queue, System.monotonic_time(:microsecond), n, %{}})
        Process.sleep(10)
      end)
      |> Stream.run()
    end)

  period_us = div(1_000_000, hz)
  started = System.monotonic_time(:microsecond)
  line_count0 = Minga.Buffer.line_count(buffer)

  wait = fn deadline ->
    ms = div(deadline - System.monotonic_time(:microsecond), 1000)
    if ms > 0, do: Process.sleep(ms)
  end

  {_, _, writes} =
    Enum.reduce(0..(hz * seconds - 1), {Minga.Buffer.version(buffer), 0, 0}, fn n,
                                                                                {version, grown,
                                                                                 writes} ->
      {version, grown, writes} =
        if scenario == "B" do
          wait.(started + n * period_us)
          text = "mid #{n} a\nmid #{n} b\nmid #{n} c\n"

          {:ok, v} =
            BufferProcess.replace_byte_range_if_version(
              buffer,
              version,
              {mid0 + grown, 0},
              0,
              text,
              EditSource.unknown()
            )

          {v, grown + 3, writes + 1}
        else
          {version, grown, writes}
        end

      wait.(started + n * period_us + div(period_us, 2))
      text = "end #{n} a\nend #{n} b\nend #{n} c\n"
      last = line_count0 + grown + n * 3 - 1

      {:ok, v} =
        BufferProcess.replace_byte_range_if_version(
          buffer,
          version,
          {last, 0},
          0,
          text,
          EditSource.unknown()
        )

      {v, grown, writes + 1}
    end)

  last_write = System.monotonic_time(:microsecond)
  Process.sleep(String.to_integer(System.get_env("RUN_LIVE_DRAIN_MS", "12000")))
  Process.exit(sampler, :kill)
  rows = :ets.tab2list(table)
  in_run = fn t -> t >= started end

  stops =
    for {[:minga, :render, :pipeline, :stop], t, meas, meta} <- rows,
        in_run.(t),
        do: {t, meas, meta}

  durs =
    Enum.map(stops, fn {_, meas, _} ->
      System.convert_time_unit(meas.duration, :native, :microsecond)
    end)

  rast = for {_, _, %{rows_rasterized: r}} <- stops, is_integer(r), do: r
  fetch = for {[:minga, :render, :line_fetch], t, _, meta} <- rows, in_run.(t), do: meta

  bytes =
    for {[:minga, :render, :emit_prepare, :stop], t, _, %{byte_count: b}} <- rows,
        in_run.(t),
        is_integer(b),
        do: b

  queue = for {:queue, t, n, _} <- rows, in_run.(t), do: n
  exceptions = for {[:minga, :render, :pipeline, :exception], t, _, _} <- rows, in_run.(t), do: t

  last_big =
    stops
    |> Enum.filter(fn {_, _, m} ->
      is_integer(m[:rows_rasterized]) and m[:rows_rasterized] > 0
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.max(fn -> nil end)

  result = %{
    scenario: scenario,
    hz: hz,
    seconds: seconds,
    writes: writes,
    line_count_before: line_count0,
    line_count_after: Minga.Buffer.line_count(buffer),
    wall_ms_writing: div(last_write - started, 1000),
    pipeline_frames: length(stops),
    pipeline_exceptions: length(exceptions),
    pipeline_ms: %{
      p50: pct.(durs, 0.5),
      p95: pct.(durs, 0.95),
      max: Enum.max(durs, fn -> nil end)
    },
    rows_rasterized: %{
      p50: pct.(rast, 0.5),
      p95: pct.(rast, 0.95),
      max: Enum.max(rast, fn -> nil end),
      frames_over_100: Enum.count(rast, &(&1 > 100))
    },
    bytes: %{p50: pct.(bytes, 0.5), p95: pct.(bytes, 0.95), max: Enum.max(bytes, fn -> nil end)},
    full_residence: Enum.frequencies_by(fetch, & &1[:full_residence?]),
    editor_queue: %{p95: pct.(queue, 0.95), max: Enum.max(queue, fn -> nil end)},
    caught_up_ms_after_last_write: if(last_big, do: div(last_big - last_write, 1000)),
    stop_meta_keys:
      stops
      |> List.first()
      |> then(fn
        nil -> nil
        {_, _, m} -> Enum.map(m.keys, &to_string/1)
      end)
  }

  File.write!(out, JSON.encode!(result))
  System.halt(0)
end)

Minga.CLI.main(["--safe", path])
Process.sleep(:infinity)
