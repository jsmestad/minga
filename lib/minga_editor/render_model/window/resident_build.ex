defmodule MingaEditor.RenderModel.Window.ResidentBuild do
  @moduledoc """
  Per-window incremental build state for full-document residence (#2658).

  Carried across frames in the window render cache. Given the current frame's
  line texts and the composition-context fingerprints, it decides between three
  outcomes and keeps the resident entry list, its retained-row map, and its
  `Minga.RenderModel.Window.ContentDigest` in sync in O(changed rows):

    * **full rebuild** — first residence frame, a frontend reset, a composition
      context change (theme, decorations, search overlay, tab width…), a
      tree-sitter re-highlight, or a row-count change (insert/delete). Runs the
      caller's `build_all` closure (the ordinary #2287 build, which itself reuses
      unchanged composed rows), then recomputes the digest from scratch.
    * **splice** — some line texts changed with the context and row count stable
      (in-place edits, substitution preview). Only the changed line indices are
      recomposed via the caller's `build_dirty` closure; the rest of the entry
      list and the digest are updated incrementally.
    * **reuse** — nothing changed (scroll, cursor motion). The prior resident
      entry list, retained-row map, and digest are returned unchanged.

  The dirty set is derived by comparing this frame's line texts against the prior
  frame's, so every source that alters a resident row's rendered content routes
  to either a precise splice (buffer text edits) or a conservative full rebuild
  (everything the context fingerprint or the highlight fingerprint captures:
  selection- and search-driven span overlays, diagnostics, git signs, decorations,
  re-highlight spans). Nothing that changes a row is allowed to skip the digest,
  which is the completeness guarantee AC 2 depends on.
  """

  alias Minga.RenderModel.Window.ContentDigest
  alias Minga.RenderModel.Window.Row
  alias MingaEditor.RenderModel.Window.ResidentStore

  @typedoc "A composed visual-row entry (`MingaEditor.RenderModel.Window.Builder` shape)."
  @type payload :: %{required(:row) => Row.t(), optional(atom()) => term()}

  @typedoc "Retained composed rows keyed by row id, for #2287 reuse and classifier state."
  @type retained_rows :: %{optional(Row.row_id()) => {non_neg_integer(), Row.t()}}

  @type t :: %__MODULE__{
          store: ResidentStore.t(),
          retained_rows: retained_rows(),
          compose_fp: integer() | nil,
          highlight_fp: integer() | nil,
          line_count: integer(),
          line_texts: [String.t()]
        }

  defstruct store: %ResidentStore{},
            retained_rows: %{},
            compose_fp: nil,
            highlight_fp: nil,
            line_count: -1,
            line_texts: []

  @typedoc """
  Per-frame residence build inputs.

  * `line_texts` — the full document's line texts (index = buffer line).
  * `compose_fp` — the shared composition-context fingerprint (decorations,
    invisibles, tab width, todo faces…); any change forces a full rebuild.
  * `highlight_fp` — a fingerprint of the tree-sitter highlight; a re-highlight
    forces a full rebuild so re-colored rows never stay stale.
  * `reset?` — a frontend/geometry reset for this frame.
  * `build_all` — builds every resident entry (the ordinary #2287 build).
  * `build_dirty` — builds entries for exactly the given dirty line indices.
  """
  @type inputs :: %{
          required(:line_texts) => [String.t()],
          required(:compose_fp) => integer(),
          required(:highlight_fp) => integer() | nil,
          required(:reset?) => boolean(),
          required(:build_all) => (-> [payload()]),
          required(:build_dirty) => (MapSet.t(non_neg_integer()) ->
                                       %{non_neg_integer() => payload()})
        }

  @typedoc """
  Per-frame residence build result.

  `payloads` is the full resident entry list; `digest` is the incremental
  content digest; `retained_rows` carries the #2287 reuse map; `rasterized`
  counts freshly composed rows; `spliced` counts rows touched by the incremental
  splice (0 on full rebuild and reuse).
  """
  @type result :: %{
          payloads: [payload()],
          digest: ContentDigest.t(),
          retained_rows: retained_rows(),
          rasterized: non_neg_integer(),
          spliced: non_neg_integer()
        }

  @doc """
  Runs one residence build frame, returning the next persistent state and the
  frame result.
  """
  @spec run(t() | nil, inputs()) :: {t(), result()}
  def run(prev, inputs) do
    if full_rebuild?(prev, inputs) do
      full_rebuild(inputs)
    else
      incremental(prev, inputs)
    end
  end

  @spec full_rebuild?(t() | nil, inputs()) :: boolean()
  defp full_rebuild?(nil, _inputs), do: true

  defp full_rebuild?(%__MODULE__{} = prev, inputs) do
    inputs.reset? or
      prev.compose_fp != inputs.compose_fp or
      prev.highlight_fp != inputs.highlight_fp or
      prev.line_count != length(inputs.line_texts)
  end

  @spec full_rebuild(inputs()) :: {t(), result()}
  defp full_rebuild(inputs) do
    payloads = inputs.build_all.()
    store = ResidentStore.from_entries(Enum.map(payloads, &to_store_entry/1))
    retained = retained_of(payloads)

    state = %__MODULE__{
      store: store,
      retained_rows: retained,
      compose_fp: inputs.compose_fp,
      highlight_fp: inputs.highlight_fp,
      line_count: length(payloads),
      line_texts: inputs.line_texts
    }

    {state,
     %{
       payloads: payloads,
       digest: ResidentStore.digest(store),
       retained_rows: retained,
       rasterized: rasterized_of(payloads),
       spliced: 0
     }}
  end

  @spec incremental(t(), inputs()) :: {t(), result()}
  defp incremental(%__MODULE__{} = prev, inputs) do
    dirty = dirty_indices(prev.line_texts, inputs.line_texts)

    if MapSet.size(dirty) == 0 do
      reuse(prev, inputs)
    else
      splice(prev, inputs, dirty)
    end
  end

  @spec reuse(t(), inputs()) :: {t(), result()}
  defp reuse(%__MODULE__{} = prev, inputs) do
    state = %{prev | line_texts: inputs.line_texts}

    {state,
     %{
       payloads: ResidentStore.payloads(prev.store),
       digest: ResidentStore.digest(prev.store),
       retained_rows: prev.retained_rows,
       rasterized: 0,
       spliced: 0
     }}
  end

  @spec splice(t(), inputs(), MapSet.t(non_neg_integer())) :: {t(), result()}
  defp splice(%__MODULE__{} = prev, inputs, dirty) do
    dirty_payloads = inputs.build_dirty.(dirty)

    store =
      ResidentStore.rebuild(prev.store, dirty, fn index ->
        to_store_entry(Map.fetch!(dirty_payloads, index))
      end)

    retained =
      Enum.reduce(dirty_payloads, prev.retained_rows, fn {_index, payload}, acc ->
        Map.put(acc, payload.row.row_id, {retain_hash(payload), payload.row})
      end)

    state = %{prev | store: store, retained_rows: retained, line_texts: inputs.line_texts}

    {state,
     %{
       payloads: ResidentStore.payloads(store),
       digest: ResidentStore.digest(store),
       retained_rows: retained,
       rasterized: map_size(dirty_payloads),
       spliced: MapSet.size(dirty)
     }}
  end

  # Indices where the line text changed between frames. The lists are the same
  # length (a row-count change forces a full rebuild before we reach here).
  @spec dirty_indices([String.t()], [String.t()]) :: MapSet.t(non_neg_integer())
  defp dirty_indices(prev_texts, new_texts) do
    prev_texts
    |> Enum.zip(new_texts)
    |> Enum.with_index()
    |> Enum.reduce(MapSet.new(), fn {{prev_text, new_text}, index}, acc ->
      if prev_text == new_text, do: acc, else: MapSet.put(acc, index)
    end)
  end

  @spec to_store_entry(payload()) :: ResidentStore.entry()
  defp to_store_entry(%{row: %Row{} = row} = payload) do
    ResidentStore.entry(row.row_id, row.content_hash, payload)
  end

  @spec retained_of([payload()]) :: retained_rows()
  defp retained_of(payloads) do
    Map.new(payloads, fn %{row: %Row{} = row} = payload ->
      {row.row_id, {retain_hash(payload), row}}
    end)
  end

  @spec retain_hash(payload()) :: non_neg_integer()
  defp retain_hash(%{row: %Row{content_hash: content_hash}} = payload) do
    Map.get(payload, :input_hash, content_hash)
  end

  @spec rasterized_of([payload()]) :: non_neg_integer()
  defp rasterized_of(payloads) do
    Enum.count(payloads, fn payload -> not Map.get(payload, :reused?, false) end)
  end
end
