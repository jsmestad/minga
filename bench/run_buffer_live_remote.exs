# Runs inside a live editor VM; started by bench/run_buffer_live.exs. Do not run it directly.
#
# Streams edits into the active buffer and times each frame against the real frontend. Bindings: scenario
# ("A" one writer appending, "B" a second writer also inserting at line `mid`), hz, seconds, mid.
#
# Reported times:
#   pipeline_us              the [:minga, :render, :pipeline] span: the BEAM builds and writes the frame.
#   frontend_apply_us        from the end of that span to the frontend's frame_applied for the same frame
#                            number. Decoding and applying, not pixels on the display.
#   edit_to_acknowledged_us  from a buffer write returning to the acknowledgement of the first frame whose
#                            pipeline started after it. Includes the debounce wait; an upper bound.
alias Minga.Buffer.EditSource
alias Minga.Buffer.Process, as: BP

editor = Process.whereis(MingaEditor)
buffer = :sys.get_state(editor).workspace.buffers.active
table = :ets.new(:live_bench, [:public, :duplicate_bag])
now = fn -> System.monotonic_time(:microsecond) end

collector =
  spawn(fn ->
    MingaEditor.Frontend.Manager.subscribe()

    loop = fn loop ->
      receive do
        {:minga_input, {:frame_applied, _generation, seq}} ->
          :ets.insert(table, {:ack, seq, System.monotonic_time(:microsecond)})
          loop.(loop)

        :stop ->
          :ok

        _other ->
          loop.(loop)
      end
    end

    loop.(loop)
  end)

handler = {:live_bench, make_ref()}

:telemetry.attach_many(
  handler,
  [
    [:minga, :render, :pipeline, :start],
    [:minga, :render, :pipeline, :stop],
    [:minga, :render, :pipeline, :exception],
    [:minga, :render, :full_hydration],
    [:minga, :render, :line_fetch]
  ],
  fn event, measurements, metadata, t ->
    at = System.monotonic_time(:microsecond)

    case event do
      [:minga, :render, :pipeline, :start] ->
        :ets.insert(t, {:start, metadata[:frame_seq], at})

      [:minga, :render, :pipeline, :stop] ->
        :ets.insert(
          t,
          {:stop, metadata[:frame_seq], at,
           System.convert_time_unit(measurements.duration, :native, :microsecond)}
        )

      [:minga, :render, :pipeline, :exception] ->
        :ets.insert(t, {:exception, metadata[:frame_seq], at})

      [:minga, :render, :full_hydration] ->
        :ets.insert(t, {:hydration, metadata[:reason], at})

      [:minga, :render, :line_fetch] ->
        :ets.insert(t, {:fetch, measurements[:lines_fetched], at})
    end
  end,
  table
)

sampler =
  spawn(fn ->
    loop = fn loop ->
      {:message_queue_len, n} = Process.info(editor, :message_queue_len)
      :ets.insert(table, {:queue, n, System.monotonic_time(:microsecond)})
      Process.sleep(10)
      loop.(loop)
    end

    loop.(loop)
  end)

Process.sleep(500)
period = div(1_000_000, hz)
line_count0 = BP.line_count(buffer)
started = now.()

wait = fn deadline ->
  ms = div(deadline - now.(), 1000)
  if ms > 0, do: Process.sleep(ms)
end

{_version, _grown} =
  Enum.reduce(0..(hz * seconds - 1), {BP.version(buffer), 0}, fn n, {version, grown} ->
    {version, grown} =
      if scenario == "B" do
        wait.(started + n * period)
        text = "mid #{n} a\nmid #{n} b\nmid #{n} c\n"

        {:ok, v} =
          BP.replace_byte_range_if_version(
            buffer,
            version,
            {mid + grown, 0},
            0,
            text,
            EditSource.unknown()
          )

        :ets.insert(table, {:edit, :mid, now.()})
        {v, grown + 3}
      else
        {version, grown}
      end

    wait.(started + n * period + div(period, 2))
    text = "end #{n} a\nend #{n} b\nend #{n} c\n"
    last = line_count0 + grown + n * 3 - 1

    {:ok, v} =
      BP.replace_byte_range_if_version(buffer, version, {last, 0}, 0, text, EditSource.unknown())

    :ets.insert(table, {:edit, :end, now.()})
    {v, grown}
  end)

last_write = now.()
Process.sleep(4_000)
Process.exit(sampler, :kill)
send(collector, :stop)
:telemetry.detach(handler)
rows = :ets.tab2list(table)

pct = fn list, p ->
  case Enum.sort(list) do
    [] -> nil
    sorted -> Enum.at(sorted, min(length(sorted) - 1, trunc(p * length(sorted))))
  end
end

stats = fn list ->
  %{
    n: length(list),
    p50: pct.(list, 0.5),
    p95: pct.(list, 0.95),
    max: Enum.max(list, fn -> nil end)
  }
end

stops = for {:stop, seq, at, duration} <- rows, at >= started, do: {seq, at, duration}
starts = for {:start, seq, at} <- rows, at >= started, into: %{}, do: {seq, at}
acks = for {:ack, seq, at} <- rows, into: %{}, do: {seq, at}
edits = for {:edit, _writer, at} <- rows, do: at

frames =
  for {seq, stop_at, duration} <- stops, ack_at = acks[seq], is_integer(ack_at) do
    %{
      seq: seq,
      start: starts[seq],
      stop: stop_at,
      ack: ack_at,
      pipeline: duration,
      frontend: ack_at - stop_at
    }
  end
  |> Enum.sort_by(& &1.stop)

# An edit is on screen when the frontend acknowledges the first frame whose pipeline started after the edit.
edit_latency =
  for edit_at <- edits,
      frame = Enum.find(frames, &(is_integer(&1.start) and &1.start >= edit_at)),
      frame != nil,
      do: frame.ack - edit_at

%{
  scenario: scenario,
  hz: hz,
  seconds: seconds,
  writes: length(edits),
  achieved_ms: div(last_write - started, 1000),
  line_count_before: line_count0,
  line_count_after: BP.line_count(buffer),
  pipeline_frames: length(stops),
  frames_acknowledged: length(frames),
  pipeline_exceptions: Enum.count(rows, &match?({:exception, _, _}, &1)),
  full_hydrations:
    Enum.count(rows, fn row -> match?({:hydration, _, at} when at >= started, row) end),
  pipeline_us: stats.(Enum.map(frames, & &1.pipeline)),
  frontend_apply_us: stats.(Enum.map(frames, & &1.frontend)),
  edit_to_acknowledged_us: stats.(edit_latency),
  edits_matched: length(edit_latency),
  lines_fetched: stats.(for {:fetch, n, at} <- rows, at >= started, is_integer(n), do: n),
  editor_queue: stats.(for {:queue, n, at} <- rows, at >= started, do: n),
  last_ack_after_last_write_ms:
    frames |> List.last() |> then(&if(&1, do: div(&1.ack - last_write, 1000)))
}
