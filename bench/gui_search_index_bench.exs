defmodule Minga.Bench.GuiSearchIndex do
  @moduledoc false

  alias Minga.Buffer.EditDelta
  alias Minga.Editing.Search.Index
  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.SearchStateEncoder
  alias MingaEditor.RenderModel.UI.SearchStateBuilder
  alias MingaEditor.State.Search.Projection

  @sizes [40, 65_536, 100_000]
  @initial_samples 3
  @frame_rounds 9
  @frames_per_round 1_000
  @edit_samples 31
  @dense_single_line_matches 70_000

  @spec run() :: :ok
  def run do
    unless Mix.env() == :prod do
      raise "run the GUI search benchmark with MIX_ENV=prod"
    end

    revision = System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim()

    results =
      for size <- @sizes,
          density <- [:sparse, :dense],
          matcher <- [:literal, :regex] do
        measure(size, density, matcher)
      end ++ [measure_dense_single_line()]

    IO.puts(
      JSON.encode!(%{
        schema: "minga.gui_search_index.v1",
        ticket: 3280,
        revision: revision,
        mix_env: Mix.env(),
        otp_release: System.otp_release(),
        elixir_version: System.version(),
        schedulers: :erlang.system_info(:schedulers_online),
        units: %{latency: "microseconds", size: "bytes_or_words"},
        samples: %{
          initial: @initial_samples,
          frame_rounds: @frame_rounds,
          frames_per_round: @frames_per_round,
          edit: @edit_samples
        },
        results: results
      })
    )

    :ok
  end

  @spec measure(pos_integer(), :sparse | :dense, :literal | :regex) :: map()
  defp measure(size, density, matcher) do
    IO.puts(:stderr, "measuring lines=#{size} density=#{density} matcher=#{matcher}")
    {lines, query, options} = fixture(size, density, matcher)

    initial_samples =
      samples(@initial_samples, fn ->
        Index.build(lines, query, options)
      end)

    index = Index.build(lines, query, options)
    initial_metrics = Index.metrics(index)
    stage(size, density, matcher, "initial")

    {cursor_samples, cursor_output} =
      samples_with_result(@frame_rounds, fn -> cursor_frames(index, @frames_per_round) end)

    {unchanged_samples, unchanged_output} =
      samples_with_result(@frame_rounds, fn -> unchanged_frames(index, @frames_per_round) end)

    stage(size, density, matcher, "frames")

    middle = div(size, 2)
    replacement = EditDelta.replacement(0, 6, {middle, 0}, {middle, 6}, "changed", {middle, 7})

    restore =
      EditDelta.replacement(
        0,
        7,
        {middle, 0},
        {middle, 7},
        Enum.at(lines, middle),
        {middle, line_length(lines, middle)}
      )

    {edit_samples, edited} =
      samples_with_result(@edit_samples, fn ->
        index
        |> Index.apply_edits([replacement], middle, ["changed"])
        |> Index.apply_edits([restore], middle, [Enum.at(lines, middle)])
      end)

    stage(size, density, matcher, "edit")

    insertion = EditDelta.insertion(0, {0, 0}, "header\n", {1, 0})

    {shift_samples, shifted} =
      samples_with_result(@edit_samples, fn ->
        Index.apply_edits(index, [insertion], 0, ["header", hd(lines)])
      end)

    stage(size, density, matcher, "shift")

    projection = projection(index, {div(size, 2), 0})
    model = SearchStateBuilder.build(projection)
    {wire, _caches} = SearchStateEncoder.encode(model, Caches.new())

    %{
      lines: size,
      density: density,
      matcher: matcher,
      matches: Index.count(index),
      matching: %{
        initial_build_us: percentiles(initial_samples),
        initial_work: initial_metrics,
        edit_undo_us: percentiles(edit_samples),
        edit_undo_work_delta: metric_delta(Index.metrics(edited), initial_metrics),
        early_insert_us: percentiles(shift_samples),
        early_insert_work_delta: metric_delta(Index.metrics(shifted), initial_metrics)
      },
      render_encode: %{
        cursor_1_000_frames_us: percentiles(cursor_samples),
        cursor_wire_bytes: cursor_output,
        unchanged_1_000_frames_us: percentiles(unchanged_samples),
        unchanged_wire_bytes: unchanged_output,
        matching_work_delta: metric_delta(Index.metrics(index), initial_metrics)
      },
      retained_size: %{
        index_words: :erts_debug.flat_size(index),
        projection_external_bytes: :erlang.external_size(projection),
        model_external_bytes: :erlang.external_size(model),
        wire_bytes: byte_size(wire)
      }
    }
  end

  @spec measure_dense_single_line() :: map()
  defp measure_dense_single_line do
    IO.puts(:stderr, "measuring dense single-line matches=#{@dense_single_line_matches}")
    line = String.duplicate("x ", @dense_single_line_matches)

    initial_samples =
      samples(@initial_samples, fn ->
        Index.build([line], "x")
      end)

    index = Index.build([line], "x")
    initial_metrics = Index.metrics(index)

    {cursor_samples, cursor_output} =
      samples_with_result(@frame_rounds, fn ->
        dense_single_line_frames(index, @frames_per_round, @dense_single_line_matches)
      end)

    last_col = (@dense_single_line_matches - 1) * 2
    projection = projection(index, {0, last_col})
    model = SearchStateBuilder.build(projection)
    {wire, _caches} = SearchStateEncoder.encode(model, Caches.new())

    %{
      lines: 1,
      shape: :dense_single_line,
      density: :dense,
      matcher: :literal,
      matches: Index.count(index),
      correctness: %{
        ordinal_65_536: Index.current_ordinal(index, {0, 65_535 * 2}),
        last_ordinal: Index.current_ordinal(index, {0, last_col})
      },
      matching: %{
        initial_build_us: percentiles(initial_samples),
        initial_work: initial_metrics
      },
      render_encode: %{
        cursor_1_000_frames_us: percentiles(cursor_samples),
        cursor_wire_bytes: cursor_output,
        matching_work_delta: metric_delta(Index.metrics(index), initial_metrics)
      },
      retained_size: %{
        index_words: :erts_debug.flat_size(index),
        projection_external_bytes: :erlang.external_size(projection),
        model_external_bytes: :erlang.external_size(model),
        wire_bytes: byte_size(wire)
      }
    }
  end

  @spec stage(pos_integer(), atom(), atom(), String.t()) :: :ok
  defp stage(size, density, matcher, stage) do
    IO.puts(
      :stderr,
      "measured lines=#{size} density=#{density} matcher=#{matcher} stage=#{stage}"
    )
  end

  @spec fixture(pos_integer(), :sparse | :dense, :literal | :regex) ::
          {[String.t()], String.t(), keyword()}
  defp fixture(size, density, matcher) do
    lines =
      for line <- 0..(size - 1) do
        fixture_line(line, density)
      end

    case matcher do
      :literal -> {lines, "needle", []}
      :regex -> {lines, "needle-[0-9]+", [regex: true]}
    end
  end

  @spec fixture_line(non_neg_integer(), :sparse | :dense) :: String.t()
  defp fixture_line(line, :dense), do: "needle-#{line} needle-#{line}"

  defp fixture_line(line, :sparse) when rem(line, 1_000) == 0,
    do: "prefix needle-#{line} suffix"

  defp fixture_line(line, :sparse), do: "ordinary line #{line}"

  @spec cursor_frames(Index.t(), pos_integer()) :: non_neg_integer()
  defp cursor_frames(index, count) do
    {_caches, bytes} =
      Enum.reduce(0..(count - 1), {Caches.new(), 0}, fn frame, {caches, bytes} ->
        model = index |> projection({frame, 0}) |> SearchStateBuilder.build()
        {wire, caches} = SearchStateEncoder.encode(model, caches)
        {caches, bytes + if(wire == nil, do: 0, else: byte_size(wire))}
      end)

    bytes
  end

  @spec dense_single_line_frames(Index.t(), pos_integer(), pos_integer()) :: non_neg_integer()
  defp dense_single_line_frames(index, count, match_count) do
    {_caches, bytes} =
      Enum.reduce(0..(count - 1), {Caches.new(), 0}, fn frame, {caches, bytes} ->
        cursor = {0, rem(frame * 67, match_count) * 2}
        model = index |> projection(cursor) |> SearchStateBuilder.build()
        {wire, caches} = SearchStateEncoder.encode(model, caches)
        {caches, bytes + if(wire == nil, do: 0, else: byte_size(wire))}
      end)

    bytes
  end

  @spec unchanged_frames(Index.t(), pos_integer()) :: non_neg_integer()
  defp unchanged_frames(index, count) do
    model = index |> projection({0, 0}) |> SearchStateBuilder.build()

    {_caches, bytes} =
      Enum.reduce(1..count, {Caches.new(), 0}, fn _frame, {caches, bytes} ->
        {wire, caches} = SearchStateEncoder.encode(model, caches)
        {caches, bytes + if(wire == nil, do: 0, else: byte_size(wire))}
      end)

    bytes
  end

  @spec projection(Index.t(), {non_neg_integer(), non_neg_integer()}) :: Projection.t()
  defp projection(index, cursor) do
    %Projection{
      active: true,
      query: index.query,
      session_id: 1,
      acknowledged_edit_seq: 1,
      match_count: Index.count(index),
      current_index: Index.current_ordinal(index, cursor),
      case_sensitive: true,
      whole_word: false,
      regex: Keyword.fetch!(index.options, :regex),
      replace_mode: false,
      status: :ready
    }
  end

  @spec line_length([String.t()], non_neg_integer()) :: non_neg_integer()
  defp line_length(lines, line), do: lines |> Enum.at(line) |> byte_size()

  @spec metric_delta(Index.metrics(), Index.metrics()) :: Index.metrics()
  defp metric_delta(after_metrics, before_metrics) do
    Map.new(after_metrics, fn {key, value} -> {key, value - Map.fetch!(before_metrics, key)} end)
  end

  @spec samples(pos_integer(), (-> term())) :: [non_neg_integer()]
  defp samples(count, operation) do
    for _sample <- 1..count do
      {elapsed, _result} = :timer.tc(operation)
      :erlang.garbage_collect()
      elapsed
    end
  end

  @spec samples_with_result(pos_integer(), (-> result)) :: {[non_neg_integer()], result}
        when result: term()
  defp samples_with_result(count, operation) do
    {samples, result} =
      Enum.reduce(1..count, {[], nil}, fn _sample, {samples, _result} ->
        {elapsed, result} = :timer.tc(operation)
        {[elapsed | samples], result}
      end)

    {Enum.reverse(samples), result}
  end

  @spec percentiles([non_neg_integer()]) :: map()
  defp percentiles(samples) do
    sorted = Enum.sort(samples)
    %{p50: percentile(sorted, 50), p95: percentile(sorted, 95), p99: percentile(sorted, 99)}
  end

  @spec percentile([non_neg_integer()], 0..100) :: non_neg_integer()
  defp percentile(sorted, percentile) do
    index = min(ceil(length(sorted) * percentile / 100) - 1, length(sorted) - 1)
    Enum.at(sorted, index)
  end
end

Minga.Bench.GuiSearchIndex.run()
