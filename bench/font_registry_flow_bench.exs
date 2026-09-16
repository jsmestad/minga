defmodule Minga.Bench.FontRegistryRecorder do
  @moduledoc false

  use GenServer

  alias Minga.Protocol.Opcodes

  @spec start_link() :: GenServer.on_start()
  def start_link, do: GenServer.start_link(__MODULE__, nil)

  @spec snapshot(pid()) :: map()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(nil), do: {:ok, %{bytes: 0, commands: 0, registrations: 0}}

  @impl true
  def handle_call({:send_render_commands, commands, _sent_at}, _from, _state) do
    summary = %{
      bytes: IO.iodata_length(commands),
      commands: length(commands),
      registrations: Enum.count(commands, &register_font_command?/1)
    }

    {:reply, :accepted, summary}
  end

  def handle_call({:send_lifecycle_command, _command}, _from, state),
    do: {:reply, :accepted, state}

  def handle_call({:send_commands, _commands}, _from, state),
    do: {:reply, :accepted, state}

  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @spec register_font_command?(binary()) :: boolean()
  defp register_font_command?(<<opcode, _rest::binary>>), do: opcode == Opcodes.register_font()
  defp register_font_command?(_command), do: false
end

defmodule Minga.Bench.FontRegistryFlow do
  @moduledoc false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Core.Decorations
  alias Minga.Core.Face
  alias Minga.Language.Highlight.Span, as: HighlightSpan
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.Renderer.BufferChanges
  alias MingaEditor.Renderer.Composition
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Frontend, as: FrontendState
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.Parser, as: ParserState
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.FontRegistry
  alias MingaEditor.UI.Highlight
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @line_count 32
  @segments_per_line 8
  @rows 40
  @cols_per_window 120
  @window_counts [1, 4]
  @family_counts [0, 1, 8]
  @span_kinds [:ordinary, :virtual_text]
  @phases [:first_allocation, :warm_frame, :recovery]

  @spec run() :: :ok
  def run do
    Logger.configure(level: :emergency)

    label = System.get_env("MINGA_FONT_BENCH_LABEL", "unlabelled")
    output = System.fetch_env!("MINGA_FONT_BENCH_OUTPUT")
    warmup = positive_env("MINGA_FONT_BENCH_WARMUP", 20)
    samples = positive_env("MINGA_FONT_BENCH_SAMPLES", 120)
    settle_ms = non_negative_env("MINGA_FONT_BENCH_SETTLE_MS", 5_000)

    receive do
    after
      settle_ms -> :ok
    end

    result = %{
      schema: "minga.font_registry_flow.v1",
      ticket: 3291,
      label: label,
      measured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      metadata: metadata(warmup, samples, settle_ms),
      pipeline: pipeline_results(warmup, samples),
      span_construction: span_results(warmup, samples)
    }

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, JSON.encode!(result))
    IO.puts(JSON.encode!(Map.drop(result, [:pipeline, :span_construction])))
    IO.puts("wrote #{output}")
    :ok
  end

  @spec pipeline_results(pos_integer(), pos_integer()) :: [map()]
  defp pipeline_results(warmup, samples) do
    for windows <- @window_counts,
        families <- @family_counts,
        span_kind <- @span_kinds do
      benchmark_pipeline(windows, families, span_kind, warmup, samples)
    end
  end

  @spec benchmark_pipeline(pos_integer(), non_neg_integer(), atom(), pos_integer(), pos_integer()) ::
          map()
  defp benchmark_pipeline(window_count, family_count, span_kind, warmup, samples) do
    {:ok, recorder} = Minga.Bench.FontRegistryRecorder.start_link()
    {state, fixture} = fixture_state(window_count, family_count, span_kind, recorder)
    input = prepare_input(state)
    warm_input = run_pipeline(input, 1)

    measurements = %{
      first_allocation:
        measure_fresh(
          input,
          warmup,
          samples,
          fn initial -> run_pipeline(initial, 1) end,
          recorder
        ),
      warm_frame: measure_threaded(warm_input, warmup, samples, &run_pipeline/2, recorder),
      recovery:
        measure_fresh(
          recovery_input(warm_input),
          warmup,
          samples,
          fn recovery -> run_pipeline(recovery, 2) end,
          recorder
        )
    }

    assert_pipeline_counts!(measurements, family_count)

    %{
      windows: window_count,
      fallback_families: family_count,
      span_kind: span_kind,
      fixture: fixture,
      phases: measurements
    }
  end

  @spec span_results(pos_integer(), pos_integer()) :: [map()]
  defp span_results(warmup, samples) do
    for families <- @family_counts,
        span_kind <- @span_kinds do
      segments = span_fixture(families, span_kind)
      warm_registry = allocate_segments(segments, FontRegistry.new()) |> elem(1)
      recovery_registry = FontRegistry.require_reregistration(warm_registry)

      phases =
        Map.new(@phases, fn phase ->
          registry = phase_registry(phase, warm_registry, recovery_registry)

          {phase,
           measure_call(warmup, samples, fn ->
             {span_count, result_registry} = allocate_segments(segments, registry)
             {span_count, map_size(result_registry.families)}
           end)}
        end)

      %{
        fallback_families: families,
        span_kind: span_kind,
        fixture: %{
          segments: length(segments),
          text_bytes: segments |> Enum.map_join(&elem(&1, 0)) |> byte_size()
        },
        phases: phases
      }
    end
  end

  @spec measure_fresh(Input.t(), pos_integer(), pos_integer(), (Input.t() -> Input.t()), pid()) ::
          map()
  defp measure_fresh(template, warmup, samples, fun, recorder) do
    Enum.each(1..warmup, fn _ -> fun.(template) end)

    {timings, observations} =
      Enum.map_reduce(1..samples, [], fn _, acc ->
        {elapsed, output} = timed(fn -> fun.(template) end)
        observation = pipeline_observation(output, recorder)
        {elapsed, [observation | acc]}
      end)

    summarize_pipeline(timings, observations)
  end

  @spec measure_threaded(
          Input.t(),
          pos_integer(),
          pos_integer(),
          (Input.t(), pos_integer() -> Input.t()),
          pid()
        ) ::
          map()
  defp measure_threaded(initial, warmup, samples, fun, recorder) do
    warmed = Enum.reduce(1..warmup, initial, fn seq, input -> fun.(input, seq + 1) end)

    {timings, {_output, observations}} =
      Enum.map_reduce(1..samples, {warmed, []}, fn seq, {input, acc} ->
        {elapsed, output} = timed(fn -> fun.(input, warmup + seq + 1) end)
        {elapsed, {output, [pipeline_observation(output, recorder) | acc]}}
      end)

    summarize_pipeline(timings, observations)
  end

  @spec measure_call(pos_integer(), pos_integer(), (-> term())) :: map()
  defp measure_call(warmup, samples, fun) do
    Enum.each(1..warmup, fn _ -> fun.() end)
    timings = Enum.map(1..samples, fn _ -> fun |> timed() |> elem(0) end)
    summarize_timings(timings)
  end

  @spec summarize_pipeline([non_neg_integer()], [map()]) :: map()
  defp summarize_pipeline(timings, observations) do
    summary = summarize_timings(timings)

    Map.merge(summary, %{
      emitted_bytes: value_summary(observations, :bytes),
      command_count: value_summary(observations, :commands),
      registration_count: value_summary(observations, :registrations),
      allocation_count: value_summary(observations, :allocations)
    })
  end

  @spec summarize_timings([non_neg_integer()]) :: map()
  defp summarize_timings(timings) do
    sorted = Enum.sort(timings)

    %{
      unit: "nanoseconds",
      p50: percentile(sorted, 50),
      p95: percentile(sorted, 95),
      min: hd(sorted),
      max: List.last(sorted),
      raw: timings
    }
  end

  @spec value_summary([map()], atom()) :: map()
  defp value_summary(values, key) do
    unique = values |> Enum.map(&Map.fetch!(&1, key)) |> Enum.uniq() |> Enum.sort()
    %{min: hd(unique), max: List.last(unique), unique: unique}
  end

  @spec pipeline_observation(Input.t(), pid()) :: map()
  defp pipeline_observation(%Input{} = output, recorder) do
    recorder
    |> Minga.Bench.FontRegistryRecorder.snapshot()
    |> Map.put(:allocations, map_size(output.font_registry.families))
  end

  @spec assert_pipeline_counts!(map(), non_neg_integer()) :: :ok
  defp assert_pipeline_counts!(measurements, expected) do
    expected_registrations = %{first_allocation: expected, warm_frame: 0, recovery: expected}

    Enum.each(measurements, fn {phase, metrics} ->
      assert_single_value!(metrics.allocation_count, expected, phase, :allocations)

      assert_single_value!(
        metrics.registration_count,
        expected_registrations[phase],
        phase,
        :registrations
      )
    end)

    :ok
  end

  @spec assert_single_value!(map(), non_neg_integer(), atom(), atom()) :: :ok
  defp assert_single_value!(%{unique: [expected]}, expected, _phase, _metric), do: :ok

  defp assert_single_value!(actual, expected, phase, metric) do
    raise "#{phase} #{metric} expected #{expected}, got #{inspect(actual)}"
  end

  @spec run_pipeline(Input.t(), pos_integer()) :: Input.t()
  defp run_pipeline(%Input{} = input, frame_seq) do
    input
    |> Input.with_frame_seq(frame_seq)
    |> RenderPipeline.run()
  end

  @spec recovery_input(Input.t()) :: Input.t()
  defp recovery_input(%Input{} = input) do
    frame = %{input.intent.frame | force_keyframe?: true}
    intent = %{input.intent | frame: frame}

    input
    |> Input.with_font_registry(FontRegistry.require_reregistration(input.font_registry))
    |> Map.put(:intent, intent)
  end

  @spec prepare_input(EditorState.t()) :: Input.t()
  defp prepare_input(%EditorState{} = state) do
    renderer = RendererState.new(editor_pid: nil, pipeline: &RenderPipeline.run/1)
    {_renderer, input} = BufferChanges.prepare(renderer, Intent.from_editor_state(state))
    input
  end

  @spec fixture_state(pos_integer(), non_neg_integer(), atom(), pid()) ::
          {EditorState.t(), map()}
  defp fixture_state(window_count, family_count, span_kind, recorder) do
    lines = fixture_lines()
    content = Enum.join(lines, "\n")
    {:ok, buffer} = BufferProcess.start_link(content: content, filetype: :text)

    if span_kind == :virtual_text do
      install_virtual_text(buffer, family_count)
    end

    window_map =
      Map.new(1..window_count, fn id -> {id, Window.new(id, buffer, @rows, @cols_per_window)} end)

    tree = window_tree(window_count)
    terminal_cols = window_count * @cols_per_window + window_count - 1
    viewport = Viewport.new(@rows, terminal_cols)
    capabilities = %Capabilities{frontend_type: :native_gui, semantic_ui: true}

    highlighting =
      if span_kind == :ordinary do
        Highlighting.put_highlight(
          %Highlighting{},
          buffer,
          ordinary_highlight(lines, family_count)
        )
      else
        %Highlighting{}
      end

    parser = ParserState.accept_highlighting(ParserState.new(), highlighting)

    state = %EditorState{
      workspace: %SessionState{
        buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
        windows: %Windows{tree: tree, map: window_map, active: 1, next_id: window_count + 1}
      },
      frontend:
        FrontendState.new(
          backend: :native_gui,
          port_manager: recorder,
          terminal_viewport: viewport,
          capabilities: capabilities
        ),
      parser: parser
    }

    fixture = %{
      lines: @line_count,
      source_bytes: byte_size(content),
      segments_per_line: @segments_per_line,
      ordinary_spans: if(span_kind == :ordinary, do: @line_count * @segments_per_line, else: 0),
      inline_virtual_texts: if(span_kind == :virtual_text, do: @line_count, else: 0),
      virtual_segments:
        if(span_kind == :virtual_text, do: @line_count * @segments_per_line, else: 0),
      rows: @rows,
      cols_per_window: @cols_per_window
    }

    {state, fixture}
  end

  @spec fixture_lines() :: [String.t()]
  defp fixture_lines do
    line = Enum.map_join(0..(@segments_per_line - 1), " ", &"token#{&1}")
    List.duplicate(line, @line_count)
  end

  @spec ordinary_highlight([String.t()], non_neg_integer()) :: Highlight.t()
  defp ordinary_highlight(lines, family_count) do
    names = Enum.map(0..(@segments_per_line - 1), &"bench.family.#{&1}")

    syntax =
      Map.new(Enum.with_index(names), fn {name, index} ->
        {name, face_style(family_count, index)}
      end)

    spans =
      lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, line_index} ->
        line_start = line_index * (byte_size(line) + 1)

        Enum.map(0..(@segments_per_line - 1), fn segment_index ->
          token_start = line_start + segment_index * 7
          HighlightSpan.new(token_start, token_start + 6, segment_index)
        end)
      end)

    syntax
    |> Highlight.new()
    |> Highlight.put_names(names)
    |> Highlight.put_spans(1, spans)
  end

  @spec install_virtual_text(pid(), non_neg_integer()) :: :ok
  defp install_virtual_text(buffer, family_count) do
    segments =
      Enum.map(0..(@segments_per_line - 1), fn index ->
        {"virtual#{index}", Face.new(face_style(family_count, index))}
      end)

    BufferProcess.batch_decorations(buffer, fn decorations ->
      Enum.reduce(0..(@line_count - 1), decorations, fn line, acc ->
        {_id, updated} =
          Decorations.add_virtual_text(acc, {line, 3}, segments: segments, placement: :inline)

        updated
      end)
    end)
  end

  @spec face_style(non_neg_integer(), non_neg_integer()) :: keyword()
  defp face_style(0, _index), do: [fg: 0xBBC2CF]
  defp face_style(1, _index), do: [fg: 0xBBC2CF, font_family: "Fallback 1"]

  defp face_style(family_count, index) do
    [fg: 0xBBC2CF, font_family: "Fallback #{rem(index, family_count) + 1}"]
  end

  @spec window_tree(pos_integer()) :: WindowTree.t()
  defp window_tree(1), do: WindowTree.new(1)

  defp window_tree(window_count) do
    Enum.reduce((window_count - 1)..1//-1, WindowTree.new(window_count), fn id, right ->
      {:split, :vertical, WindowTree.new(id), right, @cols_per_window}
    end)
  end

  @spec span_fixture(non_neg_integer(), atom()) :: [{String.t(), Face.t()}]
  defp span_fixture(family_count, span_kind) do
    prefix = if span_kind == :ordinary, do: "ordinary", else: "virtual"

    Enum.map(0..(@segments_per_line - 1), fn index ->
      {"#{prefix}#{index}", Face.new(face_style(family_count, index))}
    end)
  end

  @spec phase_registry(atom(), FontRegistry.t(), FontRegistry.t()) :: FontRegistry.t()
  defp phase_registry(:first_allocation, _warm, _recovery), do: FontRegistry.new()
  defp phase_registry(:warm_frame, warm, _recovery), do: warm
  defp phase_registry(:recovery, _warm, recovery), do: recovery

  @spec allocate_segments([{String.t(), Face.t()}], FontRegistry.t()) ::
          {non_neg_integer(), FontRegistry.t()}
  defp allocate_segments(segments, registry) do
    if function_exported?(Composition, :segments_to_text_and_spans, 2) do
      {_text, spans, registry} =
        apply(Composition, :segments_to_text_and_spans, [segments, registry])

      {length(spans), registry}
    else
      apply(FontRegistry, :with_process_registry, [
        registry,
        fn ->
          {_text, spans} = apply(Composition, :segments_to_text_and_spans, [segments])
          current = apply(FontRegistry, :current_process_registry, [registry])
          {length(spans), current}
        end
      ])
    end
  end

  @spec timed((-> result)) :: {non_neg_integer(), result} when result: term()
  defp timed(fun) do
    started = System.monotonic_time()
    result = fun.()
    elapsed = System.monotonic_time() - started
    {System.convert_time_unit(elapsed, :native, :nanosecond), result}
  end

  @spec percentile([non_neg_integer()], 50 | 95) :: non_neg_integer()
  defp percentile(sorted, percentile) do
    index = min(ceil(length(sorted) * percentile / 100) - 1, length(sorted) - 1)
    Enum.at(sorted, index)
  end

  @spec positive_env(String.t(), pos_integer()) :: pos_integer()
  defp positive_env(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> value |> String.to_integer() |> max(1)
    end
  end

  @spec non_negative_env(String.t(), non_neg_integer()) :: non_neg_integer()
  defp non_negative_env(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> value |> String.to_integer() |> max(0)
    end
  end

  @spec metadata(pos_integer(), pos_integer(), non_neg_integer()) :: map()
  defp metadata(warmup, samples, settle_ms) do
    {sha, _} = System.cmd("git", ["rev-parse", "HEAD"])

    {source_diff, _} =
      System.cmd("git", ["diff", "--binary", "HEAD", "--", "lib", "docs/ARCHITECTURE.md"])

    harness = File.read!(__ENV__.file)

    %{
      git_sha: String.trim(sha),
      source_diff_sha256: sha256(source_diff),
      harness_sha256: sha256(harness),
      source_dirty: source_diff != "",
      mix_env: Atom.to_string(Mix.env()),
      elixir: System.version(),
      otp_release: System.otp_release(),
      erts: :erlang.system_info(:version) |> to_string(),
      system_architecture: :erlang.system_info(:system_architecture) |> to_string(),
      os: :os.type() |> inspect(),
      logical_processors: :erlang.system_info(:logical_processors_available),
      schedulers: :erlang.system_info(:schedulers_online),
      startup_settle_ms: settle_ms,
      warmup_samples: warmup,
      measured_samples: samples,
      clock: "System.monotonic_time/native converted to nanoseconds",
      build: "MIX_ENV=prod mix run"
    }
  end

  @spec sha256(binary()) :: String.t()
  defp sha256(data), do: :sha256 |> :crypto.hash(data) |> Base.encode16(case: :lower)
end

Minga.Bench.FontRegistryFlow.run()
