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
      |> Document.content()
      |> binary_part(delta.start_byte, delta.old_end_byte - delta.start_byte)

    %__MODULE__{
      start_byte: delta.start_byte,
      old_text: old_text,
      new_text: delta.inserted_text,
      cursor: Document.cursor(old_document)
    }
  end

  @doc "Builds a minimal byte-range patch from two document versions."
  @spec from_documents(Document.t(), Document.t()) :: t()
  def from_documents(%Document{} = old_document, %Document{} = new_document) do
    old_text = Document.content(old_document)
    new_text = Document.content(new_document)
    start_byte = common_prefix_size(old_text, new_text)
    old_tail = byte_size(old_text) - start_byte
    new_tail = byte_size(new_text) - start_byte
    suffix_size = common_suffix_size(old_text, new_text, old_tail, new_tail)

    %__MODULE__{
      start_byte: start_byte,
      old_text: binary_part(old_text, start_byte, old_tail - suffix_size),
      new_text: binary_part(new_text, start_byte, new_tail - suffix_size),
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

  @spec common_prefix_size(binary(), binary()) :: non_neg_integer()
  defp common_prefix_size(left, right) do
    :binary.longest_common_prefix([left, right])
  end

  @spec common_suffix_size(binary(), binary(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp common_suffix_size(left, right, left_tail, right_tail) do
    left_suffix = binary_part(left, byte_size(left) - left_tail, left_tail)
    right_suffix = binary_part(right, byte_size(right) - right_tail, right_tail)
    do_common_suffix_size(left_suffix, right_suffix, left_tail, right_tail, 0)
  end

  @spec do_common_suffix_size(
          binary(),
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp do_common_suffix_size(_left, _right, 0, _right_tail, count), do: count
  defp do_common_suffix_size(_left, _right, _left_tail, 0, count), do: count

  defp do_common_suffix_size(left, right, left_tail, right_tail, count) do
    left_byte = :binary.at(left, left_tail - 1)
    right_byte = :binary.at(right, right_tail - 1)

    continue_common_suffix_size(
      left,
      right,
      left_tail,
      right_tail,
      count,
      left_byte == right_byte
    )
  end

  @spec continue_common_suffix_size(
          binary(),
          binary(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          boolean()
        ) :: non_neg_integer()
  defp continue_common_suffix_size(left, right, left_tail, right_tail, count, true) do
    do_common_suffix_size(left, right, left_tail - 1, right_tail - 1, count + 1)
  end

  defp continue_common_suffix_size(_left, _right, _left_tail, _right_tail, count, false),
    do: count
end
