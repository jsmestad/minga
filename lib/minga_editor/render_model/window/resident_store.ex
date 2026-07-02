defmodule MingaEditor.RenderModel.Window.ResidentStore do
  @moduledoc """
  Persistent per-window resident row entry list plus its content digest (#2658).

  With full-document residence a window's row set is the whole document. Rebuilding
  that list, its retained-row map, and its content fingerprint from scratch every
  frame makes edit-frame build cost O(document). This structure carries the
  resident entry list and an incrementally maintained
  `Minga.RenderModel.Window.ContentDigest` across frames so the per-frame build
  splices only the rows a dirty set marks changed and updates the digest in O(1)
  per changed row.

  The store is the single persistent structure the ticket introduces: the render
  pipeline stashes it in the window render cache and threads it through
  `MingaEditor.RenderModel.Window.Builder` on the residence path. Off the
  residence path (the default) it is never constructed, so behaviour is byte
  identical to the windowed build.

  ## Entries

  An entry is a plain map `%{id, content_hash, payload}`:

  * `id` — the row identity (a `Row.row_id`), unique within the window.
  * `content_hash` — the row's rendered-content hash, what the digest folds.
  * `payload` — opaque to the store; the builder stashes the composed visual-row
    entry (its `Row` and retention metadata) here.

  ## Value-keyed, not identity-memoized

  Reuse keys off `content_hash` (a value), never pointer identity, so this respects
  the #2445 ruling against identity memoization. The oracle for every operation is
  a from-scratch rebuild over the same entries; the incremental result must always
  equal it.
  """

  alias Minga.RenderModel.Window.ContentDigest

  @typedoc "A resident row entry. `payload` is opaque to the store."
  @type entry :: %{
          required(:id) => term(),
          required(:content_hash) => non_neg_integer(),
          required(:payload) => term()
        }

  @type t :: %__MODULE__{
          entries: [entry()],
          digest: ContentDigest.t()
        }

  defstruct entries: [], digest: 0

  @doc "Returns an empty store."
  @spec new() :: t()
  def new, do: %__MODULE__{entries: [], digest: ContentDigest.empty()}

  @doc "Builds an entry from its id, content hash, and opaque payload."
  @spec entry(term(), non_neg_integer(), term()) :: entry()
  def entry(id, content_hash, payload) when is_integer(content_hash) do
    %{id: id, content_hash: content_hash, payload: payload}
  end

  @doc "Builds a store from an ordered entry list, computing the digest from scratch."
  @spec from_entries([entry()]) :: t()
  def from_entries(entries) when is_list(entries) do
    %__MODULE__{entries: entries, digest: digest_of(entries)}
  end

  @doc "Returns the ordered entry list."
  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{entries: entries}), do: entries

  @doc "Returns the ordered opaque payloads."
  @spec payloads(t()) :: [term()]
  def payloads(%__MODULE__{entries: entries}), do: Enum.map(entries, & &1.payload)

  @doc "Returns the current content digest."
  @spec digest(t()) :: ContentDigest.t()
  def digest(%__MODULE__{digest: digest}), do: digest

  @doc "Returns the number of resident rows."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: length(entries)

  @doc "Returns true when the store holds no rows."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{entries: []}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Replaces the entry at `index`, updating the digest incrementally.

  Out-of-range indices are ignored (returns the store unchanged), keeping the
  operation total for property-test sequences.
  """
  @spec replace_at(t(), non_neg_integer(), entry()) :: t()
  def replace_at(%__MODULE__{entries: entries, digest: digest} = store, index, new_entry)
      when is_integer(index) and index >= 0 do
    case Enum.fetch(entries, index) do
      {:ok, old_entry} ->
        %{
          store
          | entries: List.replace_at(entries, index, new_entry),
            digest: swap_digest(digest, old_entry, new_entry)
        }

      :error ->
        store
    end
  end

  def replace_at(%__MODULE__{} = store, _index, _new_entry), do: store

  @doc """
  Inserts `new_entry` at `index`, shifting later entries right and folding the
  new row into the digest.

  Existing entries keep their `id`/`content_hash`, so their digest cells are
  unchanged; only the inserted row's cell is added.
  """
  @spec insert_at(t(), non_neg_integer(), entry()) :: t()
  def insert_at(%__MODULE__{entries: entries, digest: digest} = store, index, new_entry)
      when is_integer(index) and index >= 0 do
    %{
      store
      | entries: List.insert_at(entries, index, new_entry),
        digest: ContentDigest.add(digest, new_entry.id, new_entry.content_hash)
    }
  end

  def insert_at(%__MODULE__{} = store, _index, _new_entry), do: store

  @doc """
  Deletes the entry at `index`, shifting later entries left and folding the
  removed row out of the digest.
  """
  @spec delete_at(t(), non_neg_integer()) :: t()
  def delete_at(%__MODULE__{entries: entries, digest: digest} = store, index)
      when is_integer(index) and index >= 0 do
    case Enum.fetch(entries, index) do
      {:ok, removed} ->
        %{
          store
          | entries: List.delete_at(entries, index),
            digest: ContentDigest.remove(digest, removed.id, removed.content_hash)
        }

      :error ->
        store
    end
  end

  def delete_at(%__MODULE__{} = store, _index), do: store

  @doc """
  Rebuilds only the entries at the dirty indices, reusing the rest verbatim.

  `dirty_indices` is a `MapSet` of positions into the current entry list;
  `build_fun.(index)` composes the fresh entry for a dirty position. The entry
  count is unchanged (this is the in-place-edit splice; row insert/delete that
  changes the count is handled by a full `from_entries/1` rebuild upstream). An
  empty dirty set returns the store unchanged, so pure scroll and cursor frames
  reuse the resident list and digest with no per-row work.
  """
  @spec rebuild(t(), MapSet.t(non_neg_integer()), (non_neg_integer() -> entry())) :: t()
  def rebuild(%__MODULE__{} = store, dirty_indices, build_fun) when is_function(build_fun, 1) do
    if MapSet.size(dirty_indices) == 0 do
      store
    else
      splice(store, dirty_indices, build_fun)
    end
  end

  @spec splice(t(), MapSet.t(non_neg_integer()), (non_neg_integer() -> entry())) :: t()
  defp splice(%__MODULE__{entries: entries, digest: digest} = store, dirty_indices, build_fun) do
    {reversed, new_digest} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({[], digest}, fn {old_entry, index}, {acc, acc_digest} ->
        if MapSet.member?(dirty_indices, index) do
          new_entry = build_fun.(index)
          {[new_entry | acc], swap_digest(acc_digest, old_entry, new_entry)}
        else
          {[old_entry | acc], acc_digest}
        end
      end)

    %{store | entries: Enum.reverse(reversed), digest: new_digest}
  end

  @spec swap_digest(ContentDigest.t(), entry(), entry()) :: ContentDigest.t()
  defp swap_digest(digest, old_entry, new_entry) do
    digest
    |> ContentDigest.remove(old_entry.id, old_entry.content_hash)
    |> ContentDigest.add(new_entry.id, new_entry.content_hash)
  end

  @spec digest_of([entry()]) :: ContentDigest.t()
  defp digest_of(entries) do
    Enum.reduce(entries, ContentDigest.empty(), fn %{id: id, content_hash: content_hash}, acc ->
      ContentDigest.add(acc, id, content_hash)
    end)
  end
end
