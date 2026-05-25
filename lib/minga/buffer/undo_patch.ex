defmodule Minga.Buffer.UndoPatch do
  @moduledoc """
  Reversible byte-range edit for undo and redo history.

  A patch records the bytes removed and inserted by one atomic edit, plus the cursor position to restore when that patch is applied. Undo history stores patches instead of full document snapshots so memory usage follows edit size rather than file size.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.EditDelta

  @enforce_keys [:start_byte, :old_text, :new_text, :cursor]
  defstruct [:start_byte, :old_text, :new_text, :cursor]

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

  @doc "Builds a minimal byte-range patch from two document versions."
  @spec from_documents(Document.t(), Document.t()) :: t()
  def from_documents(%Document{} = old_document, %Document{} = new_document) do
    old_size = Document.content_byte_size(old_document)
    new_size = Document.content_byte_size(new_document)
    start_byte = common_prefix_size(old_document, new_document, min(old_size, new_size), 0)
    old_tail = old_size - start_byte
    new_tail = new_size - start_byte

    suffix_size =
      common_suffix_size(old_document, new_document, old_size, new_size, start_byte, 0)

    %__MODULE__{
      start_byte: start_byte,
      old_text:
        old_document
        |> Document.slice_byte_range(start_byte, old_tail - suffix_size)
        |> own_binary(),
      new_text:
        new_document
        |> Document.slice_byte_range(start_byte, new_tail - suffix_size)
        |> own_binary(),
      cursor: Document.cursor(old_document)
    }
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

  @spec common_prefix_size(Document.t(), Document.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp common_prefix_size(_left, _right, limit, count) when count == limit, do: count

  defp common_prefix_size(left, right, limit, count) do
    continue_common_prefix_size(
      left,
      right,
      limit,
      count,
      Document.byte_at(left, count) == Document.byte_at(right, count)
    )
  end

  @spec continue_common_prefix_size(
          Document.t(),
          Document.t(),
          non_neg_integer(),
          non_neg_integer(),
          boolean()
        ) ::
          non_neg_integer()
  defp continue_common_prefix_size(left, right, limit, count, true) do
    common_prefix_size(left, right, limit, count + 1)
  end

  defp continue_common_prefix_size(_left, _right, _limit, count, false), do: count

  @spec common_suffix_size(
          Document.t(),
          Document.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp common_suffix_size(_left, _right, old_size, _new_size, start_byte, count)
       when count == old_size - start_byte,
       do: count

  defp common_suffix_size(_left, _right, _old_size, new_size, start_byte, count)
       when count == new_size - start_byte,
       do: count

  defp common_suffix_size(left, right, old_size, new_size, start_byte, count) do
    old_byte = Document.byte_at(left, old_size - count - 1)
    new_byte = Document.byte_at(right, new_size - count - 1)

    continue_common_suffix_size(
      left,
      right,
      old_size,
      new_size,
      start_byte,
      count,
      old_byte == new_byte
    )
  end

  @spec continue_common_suffix_size(
          Document.t(),
          Document.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          boolean()
        ) :: non_neg_integer()
  defp continue_common_suffix_size(left, right, old_size, new_size, start_byte, count, true) do
    common_suffix_size(left, right, old_size, new_size, start_byte, count + 1)
  end

  defp continue_common_suffix_size(
         _left,
         _right,
         _old_size,
         _new_size,
         _start_byte,
         count,
         false
       ),
       do: count
end
