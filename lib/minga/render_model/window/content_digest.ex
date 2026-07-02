defmodule Minga.RenderModel.Window.ContentDigest do
  @moduledoc """
  Incrementally maintained content digest for a window's resident row set (#2658).

  The GUI adapter gates each window's content frame-emit on whether the window's
  rows changed since the last emit. With full-document residence a window's row
  list is the whole document, so re-hashing the entire list every frame is
  O(document) and dominates edit-frame build cost. This digest replaces that
  whole-list hash with a value that updates in O(1) per changed row and stays
  correct across row insertion and deletion.

  ## Keying

  The digest is a fold over per-row *cells*, where a cell is
  `phash2({row_id, content_hash})`. `row_id` already encodes the row's buffer
  line (`Row.stable_id/4`), so a cell captures both a row's identity/position and
  its rendered content. Two row lists produce the same digest with overwhelming
  probability when they carry the same multiset of `{row_id, content_hash}` pairs
  (see Collision behaviour below for the probabilistic bound).

  ## Algebra

  Cells are combined with `bxor`, which is associative, commutative, and
  self-inverse. That gives O(1) `add`/`remove`/`update` and makes the digest
  independent of iteration order (position is already carried inside `row_id`, so
  order independence never hides a real change). Editing a row back to its prior
  content restores the prior cell and therefore the prior digest, so no spurious
  frame-emit occurs.

  ## Collision behaviour

  The digest is `phash2`-derived, so a single-row content change is missed only
  when the old and new cells collide (~1 in 2^27 per changed row). For multi-row
  splices the deltas of several rows can also XOR-cancel even when no single row
  collides; the overall miss probability stays in the same ~2^-27 order. This
  matches the collision profile of the whole-list `phash2` it replaces; it does
  not add risk. Row ids are assumed unique within a window (guaranteed by
  `Row.stable_id/4` per position); the digest is a set digest under that
  assumption.
  """

  import Bitwise

  alias Minga.RenderModel.Window.Row

  @typedoc "An opaque non-negative integer digest."
  @opaque t :: non_neg_integer()

  @doc "Returns the digest of an empty row set."
  @spec empty() :: t()
  def empty, do: 0

  @doc "Returns the per-row cell for a `{row_id, content_hash}` pair."
  @spec cell(Row.row_id(), non_neg_integer()) :: non_neg_integer()
  def cell(row_id, content_hash), do: :erlang.phash2({row_id, content_hash})

  @doc "Folds a row into the digest."
  @spec add(t(), Row.row_id(), non_neg_integer()) :: t()
  def add(digest, row_id, content_hash) when is_integer(digest) do
    bxor(digest, cell(row_id, content_hash))
  end

  @doc """
  Removes a row from the digest.

  Self-inverse with `add/3`: removing a row that was previously added restores
  the digest to its pre-add value.
  """
  @spec remove(t(), Row.row_id(), non_neg_integer()) :: t()
  def remove(digest, row_id, content_hash) when is_integer(digest) do
    add(digest, row_id, content_hash)
  end

  @doc "Replaces a row's content hash under the same id."
  @spec update(t(), Row.row_id(), non_neg_integer(), non_neg_integer()) :: t()
  def update(digest, row_id, old_content_hash, new_content_hash) do
    digest
    |> remove(row_id, old_content_hash)
    |> add(row_id, new_content_hash)
  end

  @doc """
  Computes the digest of a row list from scratch.

  This is the O(document) reference used on a full rebuild and as the oracle in
  tests; the incremental `add`/`remove`/`update` operations must always agree
  with it.
  """
  @spec of_rows([Row.t()]) :: t()
  def of_rows(rows) when is_list(rows) do
    Enum.reduce(rows, empty(), fn %Row{row_id: row_id, content_hash: content_hash}, acc ->
      add(acc, row_id, content_hash)
    end)
  end

  @doc "Computes the digest of a list of `{row_id, content_hash}` pairs from scratch."
  @spec of_pairs([{Row.row_id(), non_neg_integer()}]) :: t()
  def of_pairs(pairs) when is_list(pairs) do
    Enum.reduce(pairs, empty(), fn {row_id, content_hash}, acc ->
      add(acc, row_id, content_hash)
    end)
  end
end
