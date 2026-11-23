defmodule Minga.Bench.UnchangedDiagnostics do
  @moduledoc """
  Unchanged-diagnostics frame cost (ticket #3488).

  Measures the complete consumer path, key press to committed frame through the real Editor, `Renderer.Server`, GUI encoder and `HeadlessPort`, while a URI holds a fixed diagnostic collection. Nothing republishes diagnostics during the steady-state frames, so any work that scales with the total diagnostic count D on those frames is the cost the ticket targets.

  Matrix:

    * D: 0, 100, 1,000 and 10,000 diagnostics, spread evenly across a 20,000-line file, so a viewport of R rows holds about `R * D / 20_000` visible matches K.
    * Viewport: 20 and 200 content rows.
    * Layout: one window, or two windows (vertical split) sharing the URI.
    * Path: `resident` and `resident_wrapped` use full-document residence (the default for this file size). `windowed` and `windowed_wrapped` set `:resident_store_max_lines` to 0, which forces the windowed emit path that files beyond the residence limits take.
    * Frame kind: cursor-only (`j`/`k` alternating), scroll (`Ctrl-e`/`Ctrl-y` alternating), and publication (republish a shifted list of the same size, then wait for the next frame).

  For each sample the script records wall microseconds from input (or publish call) to the committed frame, VM-wide exact reductions consumed in that interval, and call counts of `Minga.Diagnostics` reader functions. Scenario rows report p10/p50/p90 wall time, p50 reductions, reader calls per frame and the Diagnostics ETS memory in words. Raw samples go to the JSON path printed at the end.

  Run with:

      MIX_ENV=test mix run bench/unchanged_diagnostics.exs

  Set `MINGA_BENCH_DIAG_OUT` to choose the JSON output path and `MINGA_BENCH_DIAG_LABEL` to tag the run (for example `baseline` or `candidate`). Set `MINGA_BENCH_DIAG_QUICK=1` for a reduced matrix.
  """

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.SyncServer
  alias Minga.Test.HeadlessPort
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Frontend.Capabilities

  @file_lines 20_000
  @warmup 10
  @samples 40
  @publish_samples 10
  @ctrl 0x02

  @caps %Capabilities{
    frontend_type: :native_gui,
    float_support: :native,
    image_support: :native,
    semantic_ui: true
  }

  @spec run() :: :ok
  def run do
    quick? = System.get_env("MINGA_BENCH_DIAG_QUICK") == "1"
    label = System.get_env("MINGA_BENCH_DIAG_LABEL", "run")

    out =
      System.get_env(
        "MINGA_BENCH_DIAG_OUT",
        Path.join(System.tmp_dir!(), "minga_unchanged_diagnostics_#{label}.json")
      )

    dir = Path.join(System.tmp_dir!(), "minga_diag_bench_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "bench_diagnostics.ex")
    File.write!(path, document())
    uri = SyncServer.path_to_uri(path)

    counts = if quick?, do: [0, 10_000], else: [0, 100, 1_000, 10_000]
    rows = if quick?, do: [20], else: [20, 200]
    layouts = [:single, :split]
    paths = [:resident, :resident_wrapped, :windowed, :windowed_wrapped]

    results =
      for d <- counts, r <- rows, layout <- layouts, mode <- paths do
        name = "d#{d}_r#{r}_#{layout}_#{mode}"
        IO.puts("scenario #{name}")
        {name, scenario(path, uri, d, r, layout, mode)}
      end

    File.rm_rf!(dir)
    write(out, label, results)
    print(results)
    IO.puts("raw samples: #{out}")
    :ok
  end

  @spec scenario(String.t(), String.t(), non_neg_integer(), pos_integer(), atom(), atom()) ::
          map()
  defp scenario(path, uri, d, r, layout, mode) do
    Diagnostics.clear(:bench, uri)
    Diagnostics.publish(:bench, uri, diagnostics(d, 0))

    result =
      with_editor(path, r, mode, fn ctx ->
        setup_layout(ctx, layout)
        # Park the cursor mid-document so cursor and scroll frames stay steady.
        goto_middle(ctx)
        Enum.each(1..@warmup, &key(ctx, alternate(&1, ?j, ?k), 0))

        cursor = measure(&key(ctx, alternate(&1, ?j, ?k), 0))
        scroll = measure(&key(ctx, alternate(&1, ?e, ?y), @ctrl))
        publish = measure_publish(ctx, uri, d)

        %{
          diagnostics: d,
          rows: r,
          layout: layout,
          path: mode,
          cursor: cursor,
          scroll: scroll,
          publish: publish,
          ets_words: diagnostics_ets_words()
        }
      end)

    Diagnostics.clear(:bench, uri)
    result
  end

  @spec alternate(integer(), char(), char()) :: char()
  defp alternate(i, even, odd), do: if(rem(i, 2) == 0, do: even, else: odd)

  # ── Fixtures ────────────────────────────────────────────────────────────────

  @spec document() :: String.t()
  defp document do
    Enum.map_join(1..@file_lines, "\n", fn i ->
      "  def line_#{i}(alpha, beta), do: alpha + beta * gamma - delta / epsilon"
    end)
  end

  # Spreads `count` diagnostics evenly across the file. `shift` moves every
  # diagnostic down so a republication changes the list without changing D.
  @spec diagnostics(non_neg_integer(), non_neg_integer()) :: [Diagnostic.t()]
  defp diagnostics(0, _shift), do: []

  defp diagnostics(count, shift) do
    step = div(@file_lines, count)

    for i <- 0..(count - 1) do
      line = rem(i * step + shift, @file_lines)

      %Diagnostic{
        range: %{start_line: line, start_col: 6, end_line: line, end_col: 18},
        severity: Enum.at([:error, :warning, :info, :hint], rem(i, 4)),
        message: "bench diagnostic #{i}: undefined variable gamma",
        source: "bench"
      }
    end
  end

  # ── Editor lifecycle ────────────────────────────────────────────────────────

  @spec with_editor(String.t(), pos_integer(), atom(), (map() -> map())) :: map()
  defp with_editor(path, content_rows, mode, fun) do
    id = System.unique_integer([:positive])
    width = 160
    # Tab bar, modeline and minibuffer surround the content rows.
    height = content_rows + 3
    sidebar_registry = :"minga_diag_bench_sidebar_#{id}"
    {:ok, sidebar} = Sidebar.start_link(name: sidebar_registry, notify: false)
    {:ok, port} = HeadlessPort.start_link(width: width, height: height, capabilities: @caps)
    {:ok, buffer} = BufferProcess.start_link(content: File.read!(path), file_path: path)
    wrap? = mode in [:resident_wrapped, :windowed_wrapped]
    if wrap?, do: {:ok, true} = BufferProcess.set_option(buffer, :wrap, true)
    residence = if mode in [:windowed, :windowed_wrapped], do: 0, else: 65_536
    :ok = Minga.Config.set(:resident_store_max_lines, residence)

    {:ok, generation} =
      MingaEditor.GenerationSupervisor.start_editor_generation_link(
        name: :"diag_bench_editor_#{id}",
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
    {:ok, _} = HeadlessPort.collect_frame(ref, 60_000)
    ctx = %{editor: editor, port: port}

    try do
      fun.(ctx)
    after
      Enum.each([generation, buffer, port, sidebar], &stop/1)
    end
  end

  @spec setup_layout(map(), :single | :split) :: :ok
  defp setup_layout(ctx, layout) do
    if layout == :split, do: command(ctx, :split_vertical)
    :ok
  end

  @spec goto_middle(map()) :: :ok
  defp goto_middle(ctx) do
    # `10000G` through normal-mode keys.
    Enum.each(String.to_charlist("10000G"), &key(ctx, &1, 0))
    :ok
  end

  @spec command(map(), atom()) :: :ok
  defp command(%{editor: editor, port: port}, name) do
    ref = HeadlessPort.prepare_await(port)

    :sys.replace_state(
      editor,
      fn state ->
        state |> MingaEditor.Commands.execute(name) |> MingaEditor.Renderer.render()
      end,
      60_000
    )

    {:ok, _} = HeadlessPort.collect_frame(ref, 15_000)
    :ok
  end

  # ── Measurement ─────────────────────────────────────────────────────────────

  @spec key(map(), non_neg_integer(), non_neg_integer()) :: map()
  defp key(%{editor: editor, port: port}, codepoint, mods) do
    _ = :sys.get_state(editor, 30_000)
    ref = HeadlessPort.prepare_await(port)
    sample(fn -> send(editor, {:minga_input, {:key_press, codepoint, mods, 0}}) end, ref)
  end

  @spec sample((-> term()), reference()) :: map()
  defp sample(action, ref) do
    :erlang.trace_pattern({Diagnostics, :_, :_}, true, [:call_count])
    {_, _} = :erlang.statistics(:exact_reductions)
    started = System.monotonic_time(:microsecond)
    action.()

    case HeadlessPort.collect_frame(ref, 30_000) do
      {:ok, _} -> :ok
      {:error, :timeout} -> raise "timed out waiting for a frame"
    end

    wall = System.monotonic_time(:microsecond) - started
    {_, reductions} = :erlang.statistics(:exact_reductions)
    calls = reader_calls()
    :erlang.trace_pattern({Diagnostics, :_, :_}, false, [:call_count])
    %{wall_us: wall, reductions: reductions, diagnostics_calls: calls}
  end

  @spec reader_calls() :: %{String.t() => non_neg_integer()}
  defp reader_calls do
    Diagnostics.__info__(:functions)
    |> Enum.flat_map(fn {name, arity} ->
      case :erlang.trace_info({Diagnostics, name, arity}, :call_count) do
        {:call_count, n} when is_integer(n) and n > 0 -> [{"#{name}/#{arity}", n}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  @spec measure((pos_integer() -> map())) :: [map()]
  defp measure(fun), do: Enum.map(1..@samples, fun)

  @spec measure_publish(map(), String.t(), non_neg_integer()) :: [map()]
  defp measure_publish(%{editor: editor, port: port}, uri, d) do
    Enum.map(1..@publish_samples, fn i ->
      list = diagnostics(d, i)
      _ = :sys.get_state(editor, 30_000)
      ref = HeadlessPort.prepare_await(port)
      sample(fn -> Diagnostics.publish(:bench, uri, list) end, ref)
    end)
  end

  @spec diagnostics_ets_words() :: non_neg_integer()
  defp diagnostics_ets_words do
    :ets.all()
    |> Enum.filter(fn table ->
      name = :ets.info(table, :name)
      is_atom(name) and String.starts_with?(Atom.to_string(name), "Elixir.Minga.Diagnostics")
    end)
    |> Enum.map(&:ets.info(&1, :memory))
    |> Enum.sum()
  end

  @spec stop(pid()) :: :ok
  defp stop(pid) do
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5_000 -> Process.exit(pid, :kill)
    end

    :ok
  end

  # ── Output ──────────────────────────────────────────────────────────────────

  @spec summary([map()]) :: map()
  defp summary(samples) do
    wall = Enum.map(samples, & &1.wall_us)
    reds = Enum.map(samples, & &1.reductions)
    calls = samples |> Enum.map(&Enum.sum(Map.values(&1.diagnostics_calls))) |> Enum.sum()

    %{
      p10: pct(wall, 0.10),
      p50: pct(wall, 0.50),
      p90: pct(wall, 0.90),
      red_p50: pct(reds, 0.50),
      calls_per_frame: Float.round(calls / max(length(samples), 1), 1)
    }
  end

  @spec pct([number()], float()) :: number()
  defp pct([], _), do: 0

  defp pct(values, ratio) do
    sorted = Enum.sort(values)
    Enum.at(sorted, min(length(sorted) - 1, trunc(ratio * length(sorted))))
  end

  @spec print([{String.t(), map()}]) :: :ok
  defp print(results) do
    IO.puts(
      "\n| D | Rows | Layout | Path | Kind | p10 µs | p50 µs | p90 µs | Reductions p50 | Reader calls/frame | ETS words |"
    )

    IO.puts("|---:|---:|---|---|---|---:|---:|---:|---:|---:|---:|")

    Enum.each(results, fn {_name, r} ->
      Enum.each([:cursor, :scroll, :publish], fn kind ->
        s = summary(Map.fetch!(r, kind))

        IO.puts(
          "| #{r.diagnostics} | #{r.rows} | #{r.layout} | #{r.path} | #{kind} | #{s.p10} | #{s.p50} | #{s.p90} | #{s.red_p50} | #{s.calls_per_frame} | #{r.ets_words} |"
        )
      end)
    end)
  end

  @spec write(String.t(), String.t(), [{String.t(), map()}]) :: :ok
  defp write(out, label, results) do
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {dirty, 0} = System.cmd("git", ["status", "--porcelain", "--", "lib"])

    payload = %{
      label: label,
      commit: String.trim(commit),
      lib_dirty: dirty != "",
      otp: System.otp_release(),
      elixir: System.version(),
      schedulers: :erlang.system_info(:schedulers_online),
      arch: to_string(:erlang.system_info(:system_architecture)),
      results:
        Map.new(results, fn {name, r} ->
          {name,
           r
           |> Map.update!(:layout, &Atom.to_string/1)
           |> Map.update!(:path, &Atom.to_string/1)}
        end)
    }

    File.write!(out, JSON.encode!(payload))
    :ok
  end
end

Minga.Bench.UnchangedDiagnostics.run()
