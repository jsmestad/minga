defmodule MingaEditor.RenderModel.Window.ResidentBuild do
  @moduledoc "Renderer-owned delta-driven resident composition state."

  alias Minga.Buffer.EditDelta
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.RowDelta
  alias Minga.RenderModel.Window.RowSplice
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.RenderModel.Window.VisualRow
  alias MingaEditor.UI.FontRegistry

  @type payload :: VisualRow.t()
  @type retained_rows :: %{optional(Row.row_id()) => {non_neg_integer(), Row.t()}}
  @type t :: %__MODULE__{
          store: ResidentStore.t(),
          compose_fp: integer() | nil,
          highlight_fp: integer() | nil,
          line_count: non_neg_integer(),
          revision: pos_integer()
        }
  defstruct store: %ResidentStore{},
            compose_fp: nil,
            highlight_fp: nil,
            line_count: 0,
            revision: 1

  @typedoc """
  One replaced run of source lines, addressed in the store before the frame's edits. Splices in a plan are
  ascending and disjoint; the lines one inserts start at its `base_start` plus the net lines added by the
  splices before it.
  """
  @type source_splice :: EditDelta.line_splice()

  @type plan :: :reuse | {:hydrate, atom()} | {:splices, [source_splice()]}

  @typedoc "Fetched source text: the whole document, or the line ranges the plan's splices insert."
  @type source ::
          {:complete, [String.t()]} | {:ranges, [{first :: non_neg_integer(), [String.t()]}]}

  @type inputs :: %{
          required(:source) => source(),
          required(:plan) => plan(),
          required(:line_count) => non_neg_integer(),
          required(:compose_fp) => integer(),
          required(:highlight_fp) => integer() | nil,
          required(:reset?) => boolean(),
          required(:hydration_reason) => atom() | nil,
          required(:keyframe?) => boolean(),
          required(:retained_rows) => retained_rows(),
          required(:edit_deltas) => [EditDelta.t()],
          required(:font_registry) => FontRegistry.t(),
          required(:build_all) => (FontRegistry.t() -> {[payload()], FontRegistry.t()}),
          required(:build_dirty) => (MapSet.t(non_neg_integer()), FontRegistry.t() ->
                                       {%{non_neg_integer() => [payload()]}, FontRegistry.t()})
        }

  @spec run(t() | nil, inputs()) :: {t(), map(), FontRegistry.t()}
  def run(prev, inputs) do
    validate_source!(inputs.source, inputs.plan)

    {state, result, font_registry} =
      case inputs.plan do
        {:hydrate, reason} ->
          hydrate(prev, inputs, reason)

        :reuse ->
          reuse(prev, inputs.font_registry)

        {:splices, source_splices} ->
          splice(prev, inputs, source_splices)
      end

    {state, result} =
      if inputs.keyframe?, do: materialize_keyframe(state, result), else: {state, result}

    {state, result, font_registry}
  end

  @spec validate_source!(source(), plan()) :: :ok
  defp validate_source!(_source, {:hydrate, _reason}), do: :ok
  defp validate_source!(_source, :reuse), do: :ok

  defp validate_source!({:complete, lines}, plan),
    do: validate_source!({:ranges, [{0, lines}]}, plan)

  defp validate_source!({:ranges, ranges}, {:splices, source_splices}) do
    covered? = fn {first, last} ->
      Enum.any?(ranges, fn {range_first, lines} ->
        first >= range_first and last < range_first + length(lines)
      end)
    end

    if source_splices |> EditDelta.inserted_line_ranges() |> Enum.all?(covered?),
      do: :ok,
      else: raise(ArgumentError, "resident splice source does not cover inserted rows")
  end

  @doc "Plans source requirements before the orchestration stage fetches lines."
  @spec plan(t() | nil, map()) :: plan()
  def plan(prev, inputs) do
    case transition(prev, inputs) do
      :hydrate -> {:hydrate, hydration_reason(prev, inputs)}
      plan -> plan
    end
  end

  defp transition(nil, _), do: :hydrate

  defp transition(prev, inputs) do
    if inputs.reset? or prev.compose_fp != inputs.compose_fp or
         prev.highlight_fp != inputs.highlight_fp do
      :hydrate
    else
      delta_transition(inputs.edit_deltas, prev.line_count, inputs.line_count)
    end
  end

  defp delta_transition([], count, count), do: :reuse
  defp delta_transition([], _, _), do: :hydrate

  # Each run of changed lines becomes its own splice, so two edits far apart never rebuild the lines between
  # them. A plan the old store cannot hold (a delete past its end, or counts that do not add up) hydrates.
  defp delta_transition(deltas, old_count, new_count) do
    source_splices = EditDelta.line_splices(deltas)

    net =
      Enum.reduce(source_splices, 0, fn {_start, delete_count, insert_count}, net ->
        net + insert_count - delete_count
      end)

    fits? =
      Enum.all?(source_splices, fn {start, delete_count, _insert_count} ->
        delete_count >= 0 and start + delete_count <= old_count
      end)

    if fits? and old_count + net == new_count, do: {:splices, source_splices}, else: :hydrate
  end

  defp hydrate(prev, %{source: {:complete, lines}, line_count: count} = inputs, reason) do
    if length(lines) != count do
      raise ArgumentError, "resident hydration requires a complete source from line zero"
    end

    Minga.Telemetry.execute([:minga, :render, :full_hydration], %{count: 1}, %{reason: reason})
    {payloads, font_registry} = inputs.build_all.(inputs.font_registry)
    store = ResidentStore.from_entries(Enum.map(payloads, &to_store_entry/1))

    validate_line_count!(store, count)

    state = %__MODULE__{
      store: store,
      compose_fp: inputs.compose_fp,
      highlight_fp: inputs.highlight_fp,
      line_count: inputs.line_count,
      revision: if(prev == nil, do: 1, else: prev.revision + 1)
    }

    {state,
     %{
       payloads: payloads,
       inserted_payloads: payloads,
       row_delta: nil,
       source_splices: [],
       digest: ResidentStore.digest(store),
       retained_rows: retained_of(payloads),
       rasterized: rasterized_of(payloads),
       spliced: 0,
       work: ResidentStore.work(store)
     }, font_registry}
  end

  defp hydrate(_prev, _inputs, _reason),
    do: raise(ArgumentError, "resident hydration requires a complete source from line zero")

  defp reuse(prev, font_registry) do
    {prev,
     %{
       payloads: [],
       inserted_payloads: [],
       row_delta: empty_delta(ResidentStore.size(prev.store)),
       source_splices: [],
       digest: ResidentStore.digest(prev.store),
       retained_rows: %{},
       rasterized: 0,
       spliced: 0,
       work: %{rows_visited: 0, rows_copied: 0, rows_emitted: 0, chunks_touched: 0}
     }, font_registry}
  end

  # A frontend keyframe cannot reference or patch its now-empty adapter cache.
  # Materialize the already-complete renderer-owned store directly; this avoids
  # recomposing or refetching the whole buffer while still emitting every row.
  defp materialize_keyframe(state, %{row_delta: nil} = result), do: {state, result}

  defp materialize_keyframe(state, result) do
    payloads = ResidentStore.payloads(state.store)

    {state,
     %{
       result
       | payloads: payloads,
         inserted_payloads: payloads,
         row_delta: nil,
         retained_rows: retained_of(payloads),
         rasterized: result.rasterized,
         work: %{result.work | rows_emitted: length(payloads)}
     }}
  end

  defp splice(prev, inputs, source_splices) do
    # Splices address the store before the edits; the lines they insert are read at their current positions.
    inserted_ranges = EditDelta.inserted_line_ranges(source_splices)

    dirty =
      Enum.reduce(inserted_ranges, MapSet.new(), fn {first, last}, dirty ->
        Enum.reduce(first..last//1, dirty, &MapSet.put(&2, &1))
      end)

    {groups, font_registry} = inputs.build_dirty.(dirty, inputs.font_registry)

    {store, payloads, splices, _shift, work} =
      Enum.reduce(
        Enum.zip(source_splices, inserted_ranges),
        {prev.store, [], [], 0,
         %{rows_visited: 0, rows_copied: 0, rows_emitted: 0, chunks_touched: 0}},
        fn {{start, delete_count, _insert_count}, {current_first, current_last}},
           {store, payloads, splices, shift, work} ->
          inserted = Enum.flat_map(current_first..current_last//1, &Map.fetch!(groups, &1))

          first = ResidentStore.visual_rank(prev.store, start)
          last = ResidentStore.visual_rank(prev.store, start + delete_count)
          removed = last - first

          next =
            ResidentStore.replace_range(
              store,
              first + shift,
              removed,
              Enum.map(inserted, &to_store_entry/1)
            )

          splice = RowSplice.new(first, removed, Enum.map(inserted, & &1.row))

          {next, Enum.reverse(inserted, payloads), [splice | splices],
           shift + RowSplice.insert_count(splice) - removed,
           Map.merge(work, ResidentStore.work(next), fn _key, a, b -> a + b end)}
        end
      )

    validate_line_count!(store, inputs.line_count)

    {:ok, row_delta} =
      RowDelta.new(
        ResidentStore.size(prev.store),
        ResidentStore.size(store),
        Enum.reverse(splices)
      )

    inserted_payloads = Enum.reverse(payloads)
    Minga.Telemetry.execute([:minga, :render, :resident_work], work, %{operation: :splices})

    state = %{
      prev
      | store: store,
        highlight_fp: inputs.highlight_fp,
        line_count: inputs.line_count,
        revision: prev.revision + 1
    }

    {state,
     %{
       payloads: inserted_payloads,
       inserted_payloads: inserted_payloads,
       row_delta: row_delta,
       source_splices: source_splices,
       digest: ResidentStore.digest(store),
       retained_rows: retained_of(inserted_payloads),
       rasterized: rasterized_of(inserted_payloads),
       spliced:
         Enum.reduce(row_delta.splices, 0, fn splice, count ->
           count + max(splice.delete_count, RowSplice.insert_count(splice))
         end),
       work: work
     }, font_registry}
  end

  defp validate_line_count!(store, expected) do
    count = ResidentStore.line_count(store)

    if count != expected do
      raise ArgumentError, "resident build produced #{count} source starts for #{expected} lines"
    end
  end

  defp empty_delta(count) do
    {:ok, delta} = RowDelta.new(count, count, [])
    delta
  end

  defp hydration_reason(_previous, %{hydration_reason: reason}) when reason != nil, do: reason
  defp hydration_reason(nil, _), do: :initial
  defp hydration_reason(_, %{reset?: true}), do: :reset_required
  defp hydration_reason(_, _), do: :composition_context

  defp to_store_entry(%VisualRow{row: %Row{} = row} = payload),
    do: ResidentStore.entry(row.row_id, row.content_hash, payload)

  defp retained_of(payloads),
    do: Map.new(payloads, &VisualRow.retained_row/1)

  defp rasterized_of(payloads), do: Enum.count(payloads, &(not VisualRow.reused?(&1)))
end
