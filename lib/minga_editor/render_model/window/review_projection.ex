defmodule MingaEditor.RenderModel.Window.ReviewProjection do
  @moduledoc "Disposable resident review rows with baseline- and hunk-bound identities."

  alias Minga.Core.Face
  alias Minga.Core.WrapMap
  alias Minga.RenderModel.Window.ContentDigest
  alias Minga.RenderModel.Window.Row
  alias Minga.RenderModel.Window.RowDelta
  alias Minga.RenderModel.Window.RowSlotAllocator
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.DiffReview.DisplayLine
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Renderer.Composition
  alias MingaEditor.RenderModel.Window.ReviewLayout

  @source_face %Face{name: "agent.review.source"}
  @enforce_keys [
    :compatibility,
    :rows_revision,
    :review,
    :baseline,
    :baseline_keys,
    :hunk_lineages,
    :next_lineage,
    :line_cache,
    :rows,
    :row_count,
    :hunk_starts,
    :content_digest
  ]
  defstruct @enforce_keys

  @typep fragment :: {RowSlotAllocator.key(), Row.t()}
  @typep line_cache :: %{term() => {DisplayLine.kind(), String.t(), [fragment()]}}
  @typep lineage_state :: {%{non_neg_integer() => non_neg_integer()}, non_neg_integer()}
  @typep source_inputs :: {[String.t()], lineage_state()}
  @typep build_context :: {
           [Row.t()],
           line_cache(),
           RowSlotAllocator.t(),
           MapSet.t(),
           MapSet.t(),
           %{non_neg_integer() => non_neg_integer()},
           non_neg_integer(),
           ContentDigest.t()
         }
  @type t :: %__MODULE__{
          compatibility: term(),
          rows_revision: {non_neg_integer(), tuple()},
          review: DiffReview.t(),
          baseline: [String.t()],
          baseline_keys: MapSet.t(),
          hunk_lineages: %{non_neg_integer() => non_neg_integer()},
          next_lineage: non_neg_integer(),
          line_cache: line_cache(),
          rows: [Row.t()],
          row_count: non_neg_integer(),
          hunk_starts: %{non_neg_integer() => non_neg_integer()},
          content_digest: ContentDigest.t()
        }
  @type result ::
          {:ok, t(), RowSlotAllocator.t(), RowDelta.t() | nil}
          | :reset_required
          | {:error, :review_unavailable}

  @doc "Reuses unchanged rows or reconciles one authoritative review revision atomically."
  @spec refresh(
          t() | nil,
          Preview.t(),
          term(),
          ReviewLayout.t(),
          RowSlotAllocator.t(),
          non_neg_integer()
        ) :: result()
  def refresh(
        previous,
        %Preview{content: {:diff, review}} = preview,
        selection,
        layout,
        allocator,
        epoch
      ) do
    compatibility =
      {epoch, selection, review.path, preview.selection_revision,
       ReviewLayout.identity_key(layout)}

    revision = {preview.rows_revision, ReviewLayout.style_key(layout)}
    reconcile(previous, review, compatibility, revision, layout, allocator, epoch)
  end

  def refresh(_previous, %Preview{}, _selection, _layout, _allocator, _epoch),
    do: {:error, :review_unavailable}

  @doc "Exposes bounded source evidence from the projection that was actually rendered."
  @spec observation_source(t()) :: {term(), Preview.review_source()}
  def observation_source(%__MODULE__{
        compatibility: {_epoch, scope, path, selection, _layout},
        rows_revision: {rows, _style}
      }),
      do: {scope, {:diff, path, rows, selection}}

  @spec reconcile(
          t() | nil,
          DiffReview.t(),
          term(),
          {non_neg_integer(), tuple()},
          ReviewLayout.t(),
          RowSlotAllocator.t(),
          non_neg_integer()
        ) :: result()
  defp reconcile(
         %__MODULE__{compatibility: key, rows_revision: revision} = previous,
         _review,
         key,
         revision,
         _layout,
         allocator,
         _epoch
       ),
       do: {:ok, previous, allocator, nil}

  defp reconcile(
         %__MODULE__{compatibility: key},
         _review,
         current,
         _revision,
         _layout,
         _allocator,
         _epoch
       )
       when key != current,
       do: :reset_required

  defp reconcile(previous, review, compatibility, revision, layout, allocator, epoch) do
    case reconcile_source(previous, review, revision) do
      :reset_required ->
        :reset_required

      source ->
        compose(previous, review, source, compatibility, revision, layout, allocator, epoch)
    end
  end

  # Fresh previews can reuse revision numbers, so compare the source values too.
  @spec reconcile_source(t() | nil, DiffReview.t(), {non_neg_integer(), tuple()}) ::
          source_inputs() | :reset_required
  defp reconcile_source(
         %__MODULE__{
           rows_revision: {rows, _style},
           review: %DiffReview{after_lines: lines, hunks: hunks},
           baseline: baseline,
           hunk_lineages: lineages,
           next_lineage: next
         },
         %DiffReview{after_lines: lines, hunks: hunks},
         {rows, _new_style}
       ),
       do: {baseline, {lineages, next}}

  defp reconcile_source(previous, review, _revision) do
    baseline = DiffReview.original_lines(review)

    case previous do
      %__MODULE__{baseline: retained} when retained != baseline -> :reset_required
      _ -> {baseline, carry_lineages(previous, review)}
    end
  end

  @spec compose(
          t() | nil,
          DiffReview.t(),
          source_inputs(),
          term(),
          {non_neg_integer(), tuple()},
          ReviewLayout.t(),
          RowSlotAllocator.t(),
          non_neg_integer()
        ) :: result()
  defp compose(
         previous,
         review,
         {baseline, {lineages, _next} = lineage_state},
         compatibility,
         revision,
         layout,
         allocator,
         epoch
       ) do
    {old_lines, baseline_keys} = retained_inputs(previous, revision)
    initial = {[], %{}, allocator, baseline_keys, MapSet.new(), %{}, 0, ContentDigest.empty()}
    scope = {epoch, 0, :normal}

    result =
      review
      |> DiffReview.to_display_lines()
      |> Enum.reduce_while({:ok, initial}, fn line, {:ok, context} ->
        source = line_source(line.source, lineages)

        case project_line(line, source, old_lines, layout, elem(context, 2), scope) do
          {:ok, fragments, updated_allocator} ->
            {:cont, {:ok, append_line(context, line, source, fragments, updated_allocator)}}

          :reset_required ->
            {:halt, :reset_required}
        end
      end)

    finish(
      result,
      previous,
      review,
      baseline,
      compatibility,
      revision,
      lineage_state,
      scope
    )
  end

  @spec retained_inputs(t() | nil, {non_neg_integer(), tuple()}) :: {line_cache(), MapSet.t()}
  defp retained_inputs(nil, _revision), do: {%{}, MapSet.new()}

  defp retained_inputs(
         %__MODULE__{
           rows_revision: {_old_revision, style},
           line_cache: cache,
           baseline_keys: keys
         },
         {_revision, style}
       ),
       do: {cache, keys}

  defp retained_inputs(%__MODULE__{baseline_keys: keys}, _revision), do: {%{}, keys}

  @spec carry_lineages(t() | nil, DiffReview.t()) :: lineage_state()
  defp carry_lineages(nil, review), do: allocate_lineages(review, %{}, %{}, 0)

  defp carry_lineages(%__MODULE__{} = previous, review) do
    allocate_lineages(
      review,
      DiffReview.matching_hunks(previous.review, review),
      previous.hunk_lineages,
      previous.next_lineage
    )
  end

  @spec allocate_lineages(DiffReview.t(), map(), map(), non_neg_integer()) ::
          {map(), non_neg_integer()}
  defp allocate_lineages(review, matches, previous, next) do
    review.hunks
    |> Enum.with_index()
    |> Enum.reduce({%{}, next}, fn {_hunk, index}, {lineages, next} ->
      case Map.fetch(matches, index) do
        {:ok, previous_index} ->
          {Map.put(lineages, index, Map.fetch!(previous, previous_index)), next}

        :error ->
          {Map.put(lineages, index, next), next + 1}
      end
    end)
  end

  @spec line_source(DisplayLine.source(), map()) :: term()
  defp line_source({:baseline, line}, _lineages), do: {:baseline, line}

  defp line_source({:hunk_header, index}, lineages),
    do: {:hunk_header, Map.fetch!(lineages, index)}

  defp line_source({:added, index, offset}, lineages),
    do: {:added, Map.fetch!(lineages, index), offset}

  @spec project_line(
          DisplayLine.t(),
          term(),
          line_cache(),
          ReviewLayout.t(),
          RowSlotAllocator.t(),
          RowSlotAllocator.scope()
        ) :: {:ok, [fragment()], RowSlotAllocator.t()} | :reset_required
  defp project_line(
         %DisplayLine{kind: kind, text: text},
         source,
         old_lines,
         layout,
         allocator,
         scope
       ) do
    case Map.get(old_lines, source) do
      {^kind, ^text, fragments} -> {:ok, fragments, allocator}
      _changed -> compose_line(kind, text, source, layout, allocator, scope)
    end
  end

  @spec compose_line(
          DisplayLine.kind(),
          String.t(),
          term(),
          ReviewLayout.t(),
          RowSlotAllocator.t(),
          RowSlotAllocator.scope()
        ) :: {:ok, [fragment()], RowSlotAllocator.t()} | :reset_required
  defp compose_line(kind, text, source, layout, allocator, scope) do
    text = normalize_tabs(prefix(kind) <> text, layout.tab_width)

    [visual_rows] =
      WrapMap.compute([text], layout.text_width,
        breakindent: false,
        linebreak: false,
        oracle: layout.oracle,
        tab_width: layout.tab_width
      )

    spans = [ReviewLayout.span(layout, kind)]

    visual_rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], allocator}, fn {visual, index}, {:ok, fragments, allocator} ->
      key = fragment_key(source, visual.byte_offset)

      case RowSlotAllocator.allocate(allocator, scope, key) do
        {:ok, slot, allocator} ->
          text = WrapMap.display_text(visual)

          row = %Row{
            row_id: Row.stable_id(:normal, 0, slot),
            row_type: row_type(index),
            buf_line: 0,
            visual_index: index,
            text: text,
            spans: spans,
            content_hash: Row.compute_hash(text, spans)
          }

          {:cont, {:ok, [{key, row} | fragments], allocator}}

        :reset_required ->
          {:halt, :reset_required}
      end
    end)
    |> finish_fragments()
  end

  @spec finish_fragments({:ok, [fragment()], RowSlotAllocator.t()} | :reset_required) ::
          {:ok, [fragment()], RowSlotAllocator.t()} | :reset_required
  defp finish_fragments({:ok, fragments, allocator}),
    do: {:ok, Enum.reverse(fragments), allocator}

  defp finish_fragments(:reset_required), do: :reset_required

  @spec normalize_tabs(String.t(), pos_integer()) :: String.t()
  defp normalize_tabs(text, tab_width) do
    case :binary.match(text, "\t") do
      :nomatch ->
        text

      _tab ->
        [{text, @source_face}]
        |> Composition.present_whitespace(tab_width, false, nil)
        |> Enum.map_join(fn {part, _face} -> part end)
    end
  end

  @spec prefix(DisplayLine.kind()) :: String.t()
  defp prefix(:context), do: "  "
  defp prefix(:added), do: "+ "
  defp prefix(:removed), do: "- "
  defp prefix(:hunk_header), do: ""

  @spec row_type(non_neg_integer()) :: Row.row_type()
  defp row_type(0), do: :normal
  defp row_type(_index), do: :wrap_continuation

  @spec fragment_key(term(), non_neg_integer()) :: RowSlotAllocator.key()
  defp fragment_key({:baseline, line}, offset), do: {:baseline, line, offset}
  defp fragment_key({:hunk_header, lineage}, offset), do: {:hunk_header, lineage, offset}
  defp fragment_key({:added, lineage, line}, offset), do: {:added, lineage, line, offset}

  @spec append_line(
          build_context(),
          DisplayLine.t(),
          term(),
          [fragment()],
          RowSlotAllocator.t()
        ) :: build_context()
  defp append_line(
         {rows, lines, _allocator, baseline, live, starts, count, digest},
         line,
         source,
         fragments,
         allocator
       ) do
    starts = record_hunk_start(starts, line, count)
    lines = Map.put(lines, source, {line.kind, line.text, fragments})

    {rows, baseline, live, count, digest} =
      Enum.reduce(fragments, {rows, baseline, live, count, digest}, fn {key, row},
                                                                       {rows, baseline, live,
                                                                        count, digest} ->
        {baseline, live} = retain_key(key, baseline, live)
        row = Row.reposition(row, count)

        {[row | rows], baseline, live, count + 1,
         ContentDigest.add(digest, row.row_id, row.content_hash)}
      end)

    {rows, lines, allocator, baseline, live, starts, count, digest}
  end

  @spec record_hunk_start(map(), DisplayLine.t(), non_neg_integer()) :: map()
  defp record_hunk_start(starts, %DisplayLine{kind: :hunk_header, hunk_index: index}, count),
    do: Map.put(starts, index, count)

  defp record_hunk_start(starts, _line, _count), do: starts

  @spec retain_key(RowSlotAllocator.key(), MapSet.t(), MapSet.t()) :: {MapSet.t(), MapSet.t()}
  defp retain_key({:baseline, _line, _offset} = key, baseline, live),
    do: {MapSet.put(baseline, key), live}

  defp retain_key(key, baseline, live), do: {baseline, MapSet.put(live, key)}

  @spec finish(
          {:ok, build_context()} | :reset_required,
          t() | nil,
          DiffReview.t(),
          [String.t()],
          term(),
          {non_neg_integer(), tuple()},
          lineage_state(),
          RowSlotAllocator.scope()
        ) :: result()
  defp finish(
         :reset_required,
         _previous,
         _review,
         _baseline,
         _compatibility,
         _revision,
         _lineage_state,
         _scope
       ),
       do: :reset_required

  defp finish(
         {:ok, {rows, lines, allocator, baseline_keys, live, starts, count, digest}},
         previous,
         review,
         baseline,
         compatibility,
         revision,
         {lineages, next},
         scope
       ) do
    rows = Enum.reverse(rows)
    allocator = RowSlotAllocator.retain(allocator, scope, MapSet.union(baseline_keys, live))

    projection = %__MODULE__{
      compatibility: compatibility,
      rows_revision: revision,
      review: review,
      baseline: baseline,
      baseline_keys: baseline_keys,
      hunk_lineages: lineages,
      next_lineage: next,
      line_cache: lines,
      rows: rows,
      row_count: count,
      hunk_starts: starts,
      content_digest: digest
    }

    {:ok, projection, allocator, delta(previous, rows)}
  end

  @spec delta(t() | nil, [Row.t()]) :: RowDelta.t() | nil
  defp delta(nil, _rows), do: nil
  defp delta(%__MODULE__{rows: previous}, rows), do: RowDelta.from_snapshots(previous, rows)
end
