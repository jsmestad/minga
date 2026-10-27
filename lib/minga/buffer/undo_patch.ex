defmodule Minga.Buffer.UndoPatch do
  @moduledoc """
  Reversible byte-range edit for undo and redo history.

  A patch records the bytes removed and inserted by one atomic edit, plus the cursor position to restore when that patch is applied. Undo history stores patches instead of full document snapshots so memory usage follows edit size rather than file size.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.EditDelta

  @enforce_keys [:start_byte, :old_text, :new_text, :cursor]
  defstruct [:start_byte, :old_text, :new_text, :cursor]

  @affix_chunk_bytes 4096

  @typedoc "A byte fragment captured from a document diff. It may not be valid standalone UTF-8."
  @type byte_fragment :: binary()

  @opaque t :: %__MODULE__{
            start_byte: non_neg_integer(),
            old_text: byte_fragment(),
            new_text: byte_fragment(),
            cursor: Document.position()
          }

  @doc "Builds an undo patch from an edit delta and the document before the edit."
  @spec from_delta(EditDelta.t(), Document.t()) :: t()
  def from_delta(%EditDelta{} = delta, %Document{} = old_document) do
    old_text =
      old_document
      |> Document.slice_byte_range(delta.start_byte, delta.old_end_byte - delta.start_byte)
      |> own_binary()

    %__MODULE__{
      start_byte: delta.start_byte,
      old_text: old_text,
      new_text: own_binary(delta.inserted_text),
      cursor: Document.cursor(old_document)
    }
  end

  @doc """
  Builds a minimal byte-range patch from two document versions.

  The common suffix is measured only on the bytes after the common prefix, so the two never overlap. Boundaries are byte offsets and may fall inside a UTF-8 codepoint. Documents are compared in bounded chunks without materializing their full content; only the changed fragments are retained.
  """
  @spec from_documents(Document.t(), Document.t()) :: t()
  def from_documents(%Document{} = old_document, %Document{} = new_document) do
    old_size = Document.content_byte_size(old_document)
    new_size = Document.content_byte_size(new_document)
    shared_limit = min(old_size, new_size)
    start_byte = common_prefix_size(old_document, new_document, 0, shared_limit)

    suffix_size =
      common_suffix_size(old_document, new_document, 0, shared_limit - start_byte)

    %__MODULE__{
      start_byte: start_byte,
      old_text: changed_fragment(old_document, start_byte, old_size - start_byte - suffix_size),
      new_text: changed_fragment(new_document, start_byte, new_size - start_byte - suffix_size),
      cursor: Document.cursor(old_document)
    }
  end

  @spec changed_fragment(Document.t(), non_neg_integer(), non_neg_integer()) :: byte_fragment()
  defp changed_fragment(document, start_byte, byte_count),
    do: document |> Document.slice_byte_range(start_byte, byte_count) |> own_binary()

  # Each chunk is a sub-binary of one gap half, or at most a chunk-sized copy when it straddles the gap.
  @spec common_prefix_size(Document.t(), Document.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp common_prefix_size(_old, _new, offset, limit) when offset == limit, do: offset

  defp common_prefix_size(old, new, offset, limit) do
    count = min(@affix_chunk_bytes, limit - offset)

    matched =
      :binary.longest_common_prefix([
        Document.slice_byte_range(old, offset, count),
        Document.slice_byte_range(new, offset, count)
      ])

    if matched == count,
      do: common_prefix_size(old, new, offset + count, limit),
      else: offset + matched
  end

  @spec common_suffix_size(Document.t(), Document.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp common_suffix_size(_old, _new, matched, limit) when matched == limit, do: matched

  defp common_suffix_size(old, new, matched, limit) do
    count = min(@affix_chunk_bytes, limit - matched)

    chunk_matched =
      :binary.longest_common_suffix([
        suffix_chunk(old, matched, count),
        suffix_chunk(new, matched, count)
      ])

    if chunk_matched == count,
      do: common_suffix_size(old, new, matched + count, limit),
      else: matched + chunk_matched
  end

  @spec suffix_chunk(Document.t(), non_neg_integer(), non_neg_integer()) :: binary()
  defp suffix_chunk(document, matched, count) do
    end_byte = Document.content_byte_size(document) - matched
    Document.slice_byte_range(document, end_byte - count, count)
  end

  @doc "Returns the inverse patch for the current document state."
  @spec invert(t(), Document.t()) :: t()
  def invert(%__MODULE__{} = patch, %Document{} = current_document) do
    %__MODULE__{
      start_byte: patch.start_byte,
      old_text: patch.new_text,
      new_text: patch.old_text,
      cursor: Document.cursor(current_document)
    }
  end

  @doc "Applies the patch to a document, returning the previous document state for undo or the next state for redo."
  @spec apply(t(), Document.t()) :: Document.t()
  def apply(%__MODULE__{} = patch, %Document{} = document) do
    Document.replace_at_byte_range(
      document,
      patch.start_byte,
      byte_size(patch.new_text),
      patch.old_text,
      patch.cursor
    )
  end

  @spec own_binary(binary()) :: binary()
  defp own_binary(binary), do: :binary.copy(binary)
end
