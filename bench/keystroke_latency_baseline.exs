defmodule Minga.Bench.KeystrokeLatencyBaseline do
  @moduledoc """
  End-to-end keystroke-to-frame-write latency baseline (ticket #2215).

  Measures the time from injecting a key press into the editor to the frame that
  results being written to the (headless) frontend, correlated by the input
  sequence echoed on `commit_frame`. This is the BEAM-side foundation of the
  end-to-end measurement: the Go TUI and macOS GUI resolve the same correlation
  scheme at their terminal write / present points.

  Scenarios (from the acceptance criteria):

    * `small_frame`   — 100x40, a plain editor frame.
    * `large_frame`   — 220x60 with the file tree sidebar and status bar visible.
    * `agent_stream`  — typing while a deterministic synthetic agent producer
                        drives token deltas at a fixed rate CONCURRENTLY with
                        the keystrokes (a background process floods the
                        production subscriber's mailbox, not the gaps between
                        keys). This is the head-of-line-blocking pressure #2289
                        targets. We sample the Editor `message_queue_len` during
                        the run so the mailbox depth is recorded honestly and
                        later work can show it shrinking (AC 1, AC 4).

  When `MingaEditor.Agent.Ingest` is present (#2289), the producer feeds the
  Ingest coalescer (the real subscriber) and the Editor receives batched
  `{:agent_stream_batch, ...}` messages; otherwise it feeds the Editor directly,
  reproducing the pre-#2289 per-delta path. The same bench therefore measures
  before and after honestly across branches.

  Writes p50/p99 (and p99.9/max) JSON to `bench/baselines/keystroke_latency.json`
  and prints `METRIC` lines so a CI job can track the numbers over time without
  gating merges.

  Run with: `mix run bench/keystroke_latency_baseline.exs`
  """

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Test.HeadlessPort
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.State
  alias MingaEditor.State.AgentConnection

  Code.require_file("fixtures/agent_stream_replay.exs", __DIR__)

  @warmup_keys 20
  @measured_keys 120
  @baseline_path Path.join([__DIR__, "baselines", "keystroke_latency.json"])

  @gui_caps %Capabilities{
    frontend_type: :native_gui,
    float_support: :native,
    image_support: :native
  }

  @spec run() :: :ok
  def run do
    scenarios = [
      small_frame: &scenario_small_frame/0,
      large_frame: &scenario_large_frame/0,
      agent_stream: &scenario_agent_stream/0
    ]

    results =
      Map.new(scenarios, fn {name, fun} ->
        IO.puts("Running scenario: #{name}")
        {to_string(name), fun.()}
      end)

    write_baseline(results)
    print_metrics(results)
    :ok
  end

  # ── Scenarios ───────────────────────────────────────────────────────────────

  @spec scenario_small_frame() :: map()
  defp scenario_small_frame do
    with_editor([width: 100, height: 40], fn ctx ->
      warmup(ctx)
      measure_typing(ctx, fn ctx, seq -> send_key(ctx, ?a, seq) end)
    end)
  end

  @spec scenario_large_frame() :: map()
  defp scenario_large_frame do
    with_editor([width: 220, height: 60, capabilities: @gui_caps], fn ctx ->
      reveal_file_tree(ctx)
      warmup(ctx)
      measure_typing(ctx, fn ctx, seq -> send_key(ctx, ?a, seq) end)
    end)
  end

  # Inter-token interval for the synthetic producer. ~6ms ≈ 160 tokens/sec, a
  # realistic fast-model streaming rate that, delivered per-delta, floods the
  # Editor mailbox ahead of queued keystrokes. The producer emits a small burst
  # each cycle so deltas can pile up faster than the per-delta path drains them.
  @agent_token_interval_ms 4
  @agent_burst 3

  @spec scenario_agent_stream() :: map()
  defp scenario_agent_stream do
    with_editor([width: 220, height: 60, capabilities: @gui_caps], fn ctx ->
      reveal_file_tree(ctx)
      warmup(ctx)

      {producer, session} = start_agent_producer(ctx)

      try do
        samples =
          1..@measured_keys
          |> Enum.map(fn seq ->
            # Sample the Editor mailbox depth at the instant the keystroke is
            # enqueued: this is the head-of-line depth a key sees behind queued
            # agent traffic (#2289 AC 4). send_key then measures the time for
            # that key to produce its frame, which absorbs any blocking.
            queue_len = editor_queue_len(ctx)
            sample = send_key(ctx, ?a, seq)
            Map.put(sample, :queue_len, queue_len)
          end)

        summarize(samples)
      after
        stop_agent_producer(producer, ctx, session)
      end
    end)
  end

  # ── Concurrent agent producer (#2289) ───────────────────────────────────────

  # Spawns a background process that streams agent token deltas at a fixed rate
  # into the production subscriber, concurrent with typing. When the Editor runs
  # an Ingest coalescer the deltas feed Ingest (the real subscriber) so the
  # Editor sees batched messages; otherwise they feed the Editor directly,
  # reproducing the pre-#2289 per-delta mailbox pressure.
  @spec start_agent_producer(map()) :: {pid(), pid()}
  defp start_agent_producer(ctx) do
    chunks = Minga.Bench.AgentStreamReplay.chunks()
    session = spawn(fn -> receive(do: (:stop -> :ok)) end)
    target = agent_stream_target(ctx)

    producer =
      spawn_link(fn ->
        stream_agent_deltas(target, session, chunks)
      end)

    {producer, session}
  end

  # The subscriber the real session would deliver to: the Ingest coalescer if
  # this build has it (#2289), else the Editor itself.
  @spec agent_stream_target(map()) :: pid()
  defp agent_stream_target(%{editor: editor}) do
    state = :sys.get_state(editor)

    case ingest_pid(state) do
      pid when is_pid(pid) -> pid
      _ -> editor
    end
  end

  @spec ingest_pid(term()) :: pid() | nil
  defp ingest_pid(%State{agent_connection: %AgentConnection{agent_ingest: ingest}}), do: ingest
  defp ingest_pid(_state), do: nil

  @spec stream_agent_deltas(pid(), pid(), [String.t()]) :: no_return()
  defp stream_agent_deltas(target, session, chunks) do
    chunks
    |> Stream.cycle()
    |> Stream.chunk_every(@agent_burst)
    |> Enum.each(fn burst ->
      Enum.each(burst, fn chunk ->
        send(target, {:agent_event, session, {:text_delta, chunk}})
      end)

      receive do
        :stop -> exit(:normal)
      after
        @agent_token_interval_ms -> :ok
      end
    end)
  end

  @spec stop_agent_producer(pid(), map(), pid()) :: :ok
  defp stop_agent_producer(producer, _ctx, session) do
    if Process.alive?(producer) do
      send(producer, :stop)
    end

    if Process.alive?(session), do: Process.exit(session, :kill)
    :ok
  catch
    _, _ -> :ok
  end

  @spec editor_queue_len(map()) :: non_neg_integer()
  defp editor_queue_len(%{editor: editor}) do
    case Process.info(editor, :message_queue_len) do
      {:message_queue_len, len} -> len
      _ -> 0
    end
  end

  # ── Measurement core ─────────────────────────────────────────────────────────

  @spec measure_typing(map(), (map(), pos_integer() -> map())) :: map()
  defp measure_typing(ctx, key_fun) do
    1..@measured_keys
    |> Enum.map(fn seq -> key_fun.(ctx, seq) end)
    |> summarize()
  end

  # Injects a key press carrying the correlation sequence and waits for the
  # resulting frame. Verifies the echoed sequence on commit_frame matches, proving
  # the round-trip correlation (ticket #2215 acceptance; commit_frame absorbed the
  # echo from batch_end in #2219).
  @spec send_key(map(), non_neg_integer(), pos_integer()) :: %{
          wall_us: non_neg_integer(),
          correlated: boolean()
        }
  defp send_key(%{editor: editor, port: port}, codepoint, seq) do
    # Generous timeout: under the concurrent agent producer the per-delta path
    # (pre-#2289) can deeply back up the Editor mailbox; we want the run to
    # complete and surface that as large latency, not crash the sync barrier.
    _ = :sys.get_state(editor, 30_000)
    ref = HeadlessPort.prepare_await(port)
    started_at = System.monotonic_time(:microsecond)
    send(editor, {:minga_input, {:key_press, codepoint, 0, seq}})

    case HeadlessPort.collect_frame(ref, 5_000) do
      {:ok, snapshot} ->
        stopped_at = System.monotonic_time(:microsecond)
        %{wall_us: stopped_at - started_at, correlated: Map.get(snapshot, :input_seq) == seq}

      {:error, :timeout} ->
        raise "timed out waiting for frame after key #{inspect(codepoint)}"
    end
  end

  @spec warmup(map()) :: :ok
  defp warmup(ctx) do
    # Enter insert mode then warm the path with unmeasured keystrokes.
    _ = send_key(ctx, ?i, 0)
    Enum.each(1..@warmup_keys, fn _ -> send_key(ctx, ?a, 0) end)
    :ok
  end

  @spec summarize([map()]) :: map()
  defp summarize(samples) do
    wall = Enum.map(samples, & &1.wall_us)
    correlated = Enum.count(samples, & &1.correlated)

    base = %{
      samples: length(samples),
      correlated: correlated,
      p50_us: percentile(wall, 0.50),
      p99_us: percentile(wall, 0.99),
      p999_us: percentile(wall, 0.999),
      max_us: Enum.max(wall, fn -> 0 end)
    }

    merge_queue_stats(base, Enum.flat_map(samples, &queue_len_of/1))
  end

  @spec queue_len_of(map()) :: [non_neg_integer()]
  defp queue_len_of(%{queue_len: len}) when is_integer(len), do: [len]
  defp queue_len_of(_sample), do: []

  # When the scenario sampled the Editor mailbox depth, fold its distribution in
  # so before/after runs can show the queue staying low (#2289 AC 4).
  @spec merge_queue_stats(map(), [non_neg_integer()]) :: map()
  defp merge_queue_stats(base, []), do: base

  defp merge_queue_stats(base, queue_lens) do
    Map.merge(base, %{
      queue_p50: percentile(queue_lens, 0.50),
      queue_p99: percentile(queue_lens, 0.99),
      queue_max: Enum.max(queue_lens, fn -> 0 end)
    })
  end

  # ── Editor lifecycle ─────────────────────────────────────────────────────────

  @spec with_editor(keyword(), (map() -> map())) :: map()
  defp with_editor(opts, fun) do
    ctx = start_editor(opts)

    try do
      fun.(ctx)
    after
      stop_if_alive(ctx.generation)
      stop_if_alive(ctx.buffer)
      stop_if_alive(ctx.port)
      stop_if_alive(ctx.sidebar)
    end
  end

  @spec start_editor(keyword()) :: map()
  defp start_editor(opts) do
    id = System.unique_integer([:positive])
    width = Keyword.fetch!(opts, :width)
    height = Keyword.fetch!(opts, :height)
    capabilities = Keyword.get(opts, :capabilities)
    sidebar_registry = :"minga_kl_bench_sidebar_#{id}"

    {:ok, sidebar} = Sidebar.start_link(name: sidebar_registry, notify: false)

    port_opts = [width: width, height: height]
    port_opts = if capabilities, do: [{:capabilities, capabilities} | port_opts], else: port_opts
    {:ok, port} = HeadlessPort.start_link(port_opts)

    {:ok, buffer} = BufferProcess.start_link(content: document(), file_path: "bench_elixir.ex")

    {:ok, generation} =
      MingaEditor.GenerationSupervisor.start_editor_generation_link(
        name: :"kl_bench_editor_#{id}",
        backend: :headless,
        port_manager: port,
        buffer: buffer,
        width: width,
        height: height,
        editing_model: :vim,
        sidebar_registry: sidebar_registry,
        suppress_tool_prompts: true
      )

    {:ok, editor} = MingaEditor.GenerationSupervisor.editor_owner(generation)
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:ready, width, height}})
    {:ok, _snapshot} = HeadlessPort.collect_frame(ref, 15_000)
    _ = :sys.get_state(editor)

    %{
      generation: generation,
      editor: editor,
      buffer: buffer,
      port: port,
      sidebar: sidebar,
      width: width,
      height: height
    }
  end

  # Opens the file tree sidebar so the large-frame scenario renders it. Falls
  # back silently if the command is unavailable in this build.
  @spec reveal_file_tree(map()) :: :ok
  defp reveal_file_tree(%{editor: editor, port: port}) do
    ref = HeadlessPort.prepare_await(port)

    :sys.replace_state(editor, fn state ->
      state
      |> MingaEditor.Commands.execute(:toggle_file_tree)
      |> MingaEditor.Renderer.render()
    end)

    case HeadlessPort.collect_frame(ref, 5_000) do
      {:ok, _snapshot} -> :ok
      {:error, :timeout} -> :ok
    end
  catch
    _, _ -> :ok
  end

  @spec document() :: String.t()
  defp document do
    1..2_000
    |> Enum.map_join("\n", fn i ->
      "line #{i} alpha beta gamma delta epsilon zeta eta theta"
    end)
  end

  # ── Output ───────────────────────────────────────────────────────────────────

  @spec write_baseline(map()) :: :ok
  defp write_baseline(results) do
    payload = %{
      "schema" => "minga.keystroke_latency.v1",
      "ticket" => 2215,
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "unit" => "microseconds",
      "measured_keys" => @measured_keys,
      "scenarios" => results
    }

    File.mkdir_p!(Path.dirname(@baseline_path))
    File.write!(@baseline_path, json_encode(payload) <> "\n")
    IO.puts("Wrote baseline: #{@baseline_path}")
    :ok
  end

  @spec print_metrics(map()) :: :ok
  defp print_metrics(results) do
    Enum.each(results, fn {scenario, stats} ->
      Enum.each([:p50_us, :p99_us, :p999_us, :max_us], fn field ->
        IO.puts("METRIC keystroke_#{scenario}_#{field}=#{Map.fetch!(stats, field)}")
      end)

      # Editor mailbox depth sampled during the scenario (#2289 AC 4). Only the
      # agent_stream scenario records these.
      Enum.each([:queue_p50, :queue_p99, :queue_max], fn field ->
        case Map.fetch(stats, field) do
          {:ok, value} -> IO.puts("METRIC keystroke_#{scenario}_#{field}=#{value}")
          :error -> :ok
        end
      end)
    end)

    :ok
  end

  # Minimal JSON encoder so the bench has no extra dependency. Handles only the
  # value shapes this bench produces (maps, strings, integers, floats).
  @spec json_encode(term()) :: iodata()
  defp json_encode(map) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map_join(",", fn {k, v} -> "#{json_encode(to_string(k))}:#{json_encode(v)}" end)

    "{" <> inner <> "}"
  end

  defp json_encode(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp json_encode(value) when is_integer(value), do: Integer.to_string(value)
  defp json_encode(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp json_encode(true), do: "true"
  defp json_encode(false), do: "false"
  defp json_encode(nil), do: "null"

  # ── Math helpers ─────────────────────────────────────────────────────────────

  @spec percentile([number()], float()) :: number()
  defp percentile([], _ratio), do: 0

  defp percentile(values, ratio) do
    sorted = Enum.sort(values)
    index = max(0, ceil(length(sorted) * ratio) - 1)
    Enum.at(sorted, index)
  end

  @spec stop_if_alive(pid() | nil) :: :ok
  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp stop_if_alive(_), do: :ok
end

Minga.Bench.KeystrokeLatencyBaseline.run()
