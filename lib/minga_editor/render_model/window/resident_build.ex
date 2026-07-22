defmodule MingaEditor.RenderModel.Window.ResidentBuild do
  @moduledoc "Renderer-owned delta-driven resident composition state."

  alias Minga.Buffer.EditDelta
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.RowDelta
  alias Minga.RenderModel.Window.RowSplice
  alias MingaEditor.RenderModel.Window.ResidentStore
  alias MingaEditor.RenderModel.Window.VisualRow

  @type payload :: VisualRow.t()
  @type retained_rows :: %{optional(Row.row_id()) => {non_neg_integer(), Row.t()}}
  @type t :: %__MODULE__{
          store: ResidentStore.t(),
          compose_fp: integer() | nil,
          highlight_fp: integer() | nil,
          line_count: non_neg_integer()
        }
  defstruct store: %ResidentStore{}, compose_fp: nil, highlight_fp: nil, line_count: 0

  @type inputs :: %{
          required(:line_texts) => [String.t()],
          required(:line_count) => non_neg_integer(),
          required(:compose_fp) => integer(),
          required(:highlight_fp) => integer() | nil,
          required(:reset?) => boolean(),
          required(:hydration_reason) => atom() | nil,
          required(:keyframe?) => boolean(),
          required(:retained_rows) => retained_rows(),
          required(:edit_deltas) => [EditDelta.t()],
          required(:build_all) => (-> [payload()]),
          required(:build_dirty) => (MapSet.t(non_neg_integer()) ->
                                       %{non_neg_integer() => payload()})
        }

  @spec run(t() | nil, inputs()) :: {t(), map()}
  def run(prev, inputs) do
    {state, result} =
      case transition(prev, inputs) do
        :hydrate ->
          hydrate(inputs, hydration_reason(prev, inputs))

        :reuse ->
          reuse(prev)

        {:splice, start, delete_count, insert_count} ->
          splice(prev, inputs, start, delete_count, insert_count)

        {:splices, lines} ->
          splice_lines(prev, inputs, lines)
      end

    if inputs.keyframe?, do: materialize_keyframe(state, result), else: {state, result}
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

  defp delta_transition(deltas, count, count) do
    case in_place_edit_lines(deltas, []) do
      {:ok, lines} -> {:splices, lines |> Enum.uniq() |> Enum.sort()}
      :structural -> structural_delta_transition(deltas, count, count)
    end
  end

  defp delta_transition(deltas, old_count, new_count),
    do: structural_delta_transition(deltas, old_count, new_count)

  defp structural_delta_transition(deltas, old_count, new_count) do
    {start, current_last} = EditDelta.affected_line_range(deltas)
    insert_count = current_last - start + 1
    delete_count = insert_count - (new_count - old_count)

    if delete_count >= 0 and start + delete_count <= old_count,
      do: {:splice, start, delete_count, insert_count},
      else: :hydrate
  end

  @spec in_place_edit_lines([EditDelta.t()], [non_neg_integer()]) ::
          {:ok, [non_neg_integer()]} | :structural
  defp in_place_edit_lines([], lines), do: {:ok, Enum.reverse(lines)}

  defp in_place_edit_lines(
         [
           %EditDelta{
             start_position: {line, _},
             old_end_position: {line, _},
             new_end_position: {line, _}
           }
           | rest
         ],
         lines
       ),
       do: in_place_edit_lines(rest, [line | lines])

  defp in_place_edit_lines(_deltas, _lines), do: :structural

  defp hydrate(inputs, reason) do
    Minga.Telemetry.execute([:minga, :render, :full_hydration], %{count: 1}, %{reason: reason})
    payloads = inputs.build_all.()
    store = ResidentStore.from_entries(Enum.map(payloads, &to_store_entry/1))

    state = %__MODULE__{
      store: store,
      compose_fp: inputs.compose_fp,
      highlight_fp: inputs.highlight_fp,
      line_count: inputs.line_count
    }

    {state,
     %{
       payloads: payloads,
       inserted_payloads: payloads,
       row_delta: nil,
       digest: ResidentStore.digest(store),
       retained_rows: retained_of(payloads),
       rasterized: rasterized_of(payloads),
       spliced: 0,
       work: ResidentStore.work(store)
     }}
  end

  defp reuse(prev) do
    {prev,
     %{
       payloads: [],
       inserted_payloads: [],
       row_delta: empty_delta(prev.line_count),
       digest: ResidentStore.digest(prev.store),
       retained_rows: %{},
       rasterized: 0,
       spliced: 0,
       work: %{rows_visited: 0, rows_copied: 0, rows_emitted: 0, chunks_touched: 0}
     }}
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

  defp splice(prev, inputs, start, delete_count, insert_count) do
    dirty =
      if insert_count == 0, do: MapSet.new(), else: MapSet.new(start..(start + insert_count - 1))

    dirty_payloads = if insert_count == 0, do: %{}, else: inputs.build_dirty.(dirty)

    inserted_payloads =
      if insert_count == 0,
        do: [],
        else: Enum.map(start..(start + insert_count - 1), &Map.fetch!(dirty_payloads, &1))

    inserted = Enum.map(inserted_payloads, &to_store_entry/1)
    store = ResidentStore.replace_range(prev.store, start, delete_count, inserted)
    work = ResidentStore.work(store)
    Minga.Telemetry.execute([:minga, :render, :resident_work], work, %{operation: :splice})
    result_count = prev.line_count - delete_count + insert_count

    {:ok, row_delta} =
      RowDelta.new(prev.line_count, result_count, [
        RowSplice.new(start, delete_count, Enum.map(inserted_payloads, & &1.row))
      ])

    state = %{prev | store: store, line_count: result_count}

    {state,
     %{
       payloads: inserted_payloads,
       inserted_payloads: inserted_payloads,
       row_delta: row_delta,
       digest: ResidentStore.digest(store),
       retained_rows: retained_of(inserted_payloads),
       rasterized: length(inserted_payloads),
       spliced: max(delete_count, insert_count),
       work: work
     }}
  end

  @spec splice_lines(t(), inputs(), [non_neg_integer()]) :: {t(), map()}
  defp splice_lines(prev, inputs, lines) do
    dirty_payloads = inputs.build_dirty.(MapSet.new(lines))

    {store, inserted_payloads, splices} =
      Enum.reduce(lines, {prev.store, [], []}, fn line, {store, payloads, splices} ->
        payload = Map.fetch!(dirty_payloads, line)
        entry = to_store_entry(payload)
        store = ResidentStore.replace_at(store, line, entry)
        splice = RowSplice.new(line, 1, [payload.row])
        {store, [payload | payloads], [splice | splices]}
      end)

    inserted_payloads = Enum.reverse(inserted_payloads)
    {:ok, row_delta} = RowDelta.new(prev.line_count, prev.line_count, Enum.reverse(splices))
    work = ResidentStore.work(store)
    Minga.Telemetry.execute([:minga, :render, :resident_work], work, %{operation: :splices})
    state = %{prev | store: store}

    {state,
     %{
       payloads: inserted_payloads,
       inserted_payloads: inserted_payloads,
       row_delta: row_delta,
       digest: ResidentStore.digest(store),
       retained_rows: retained_of(inserted_payloads),
       rasterized: rasterized_of(inserted_payloads),
       spliced: length(lines),
       work: work
     }}
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
