defmodule Minga.Buffer.Operation do
  @moduledoc """
  Pure buffer edit operations with delta generation.

  `Document` owns the gap-buffer data structure. This module owns domain edits that need both the updated document and the sync delta describing the change. `Buffer.Process` wraps these operations with process concerns like read-only checks, undo, dirty tracking, events, and persistence.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.Position
  alias Minga.Buffer.Selection
  alias Minga.Buffer.Span
  alias Minga.Buffer.UndoPatch

  @typedoc "Result of a pure edit operation."
  @type result :: :unchanged | {:edited, Document.t(), EditDelta.t()}

  @typedoc "A range replacement edit using Buffer's characterwise inclusive range semantics."
  @type range_edit :: {Document.position(), Document.position(), String.t()}

  @doc "Inserts text at the current cursor and returns the updated document plus insertion delta."
  @spec insert_at_cursor(Document.t(), String.t()) :: {:edited, Document.t(), EditDelta.t()}
  def insert_at_cursor(%Document{} = doc, text) when is_binary(text) do
    start_byte = Document.cursor_offset(doc)
    start_position = Document.cursor(doc)
    new_doc = Document.insert_text(doc, text)
    delta = EditDelta.insertion(start_byte, start_position, text, Document.cursor(new_doc))

    {:edited, new_doc, delta}
  end

  @doc "Replaces a characterwise range and returns the updated document plus replacement delta."
  @spec replace_range(Document.t(), Document.position(), Document.position(), String.t()) ::
          result()
  def replace_range(%Document{} = doc, from_pos, to_pos, replacement)
      when is_binary(replacement) do
    selection = Selection.characterwise(doc, from_pos, to_pos)
    %Span{start: start_byte, stop: old_end_byte} = selection.span

    new_doc =
      doc
      |> Document.delete_range(from_pos, to_pos)
      |> Document.insert_text(replacement)

    delta =
      EditDelta.replacement(
        start_byte,
        old_end_byte,
        Position.from_point(doc, start_byte),
        Position.from_point(doc, old_end_byte),
        replacement,
        Document.cursor(new_doc)
      )

    {:edited, new_doc, delta}
  end

  @doc "Applies multiple range replacements from the end of the document toward the start."
  @spec replace_ranges(Document.t(), [range_edit()]) :: Document.t()
  def replace_ranges(%Document{} = doc, edits) when is_list(edits) do
    {new_doc, _patches} = replace_ranges_with_patches(doc, edits)
    new_doc
  end

  @doc "Applies multiple range replacements and returns undo patches in newest-first recording order."
  @spec replace_ranges_with_patches(Document.t(), [range_edit()]) ::
          {Document.t(), [UndoPatch.t()]}
  def replace_ranges_with_patches(%Document{} = doc, edits) when is_list(edits) do
    edits
    |> Enum.sort(fn {from_a, _, _}, {from_b, _, _} -> from_a >= from_b end)
    |> Enum.reduce({doc, []}, fn {from_pos, to_pos, replacement}, {acc_doc, patches} ->
      {:edited, new_doc, delta} = replace_range(acc_doc, from_pos, to_pos, replacement)
      patch = UndoPatch.from_delta(delta, acc_doc)
      {new_doc, [patch | patches]}
    end)
  end

  @doc "Deletes the character before the cursor."
  @spec backspace(Document.t()) :: result()
  def backspace(%Document{} = doc) do
    new_doc = Document.delete_before(doc)

    if new_doc == doc do
      :unchanged
    else
      delta =
        EditDelta.deletion(
          Document.cursor_offset(new_doc),
          Document.cursor_offset(doc),
          Document.cursor(new_doc),
          Document.cursor(doc)
        )

      {:edited, new_doc, delta}
    end
  end

  @doc "Deletes the character at the cursor."
  @spec delete_forward(Document.t()) :: result()
  def delete_forward(%Document{} = doc) do
    new_doc = Document.delete_at(doc)

    if new_doc == doc do
      :unchanged
    else
      start_byte = Document.cursor_offset(doc)
      old_end_byte = Position.after_character_at(Document.content(doc), start_byte)

      delta =
        EditDelta.deletion(
          start_byte,
          old_end_byte,
          Document.cursor(doc),
          Position.from_point(doc, old_end_byte)
        )

      {:edited, new_doc, delta}
    end
  end

  @doc "Deletes a characterwise range and returns a deletion delta."
  @spec delete_range(Document.t(), Document.position(), Document.position()) :: result()
  def delete_range(%Document{} = doc, from_pos, to_pos) do
    selection = Selection.characterwise(doc, from_pos, to_pos)
    %Span{start: start_byte, stop: old_end_byte} = selection.span
    new_doc = Document.delete_range(doc, from_pos, to_pos)

    if new_doc == doc do
      :unchanged
    else
      delta =
        EditDelta.deletion(
          start_byte,
          old_end_byte,
          Position.from_point(doc, start_byte),
          Position.from_point(doc, old_end_byte)
        )

      {:edited, new_doc, delta}
    end
  end

  @doc "Deletes a linewise range and returns a deletion delta."
  @spec delete_lines(Document.t(), non_neg_integer(), non_neg_integer()) :: result()
  def delete_lines(%Document{} = doc, start_line, end_line)
      when start_line >= 0 and end_line >= 0 do
    new_doc = Document.delete_lines(doc, start_line, end_line)

    if new_doc == doc do
      :unchanged
    else
      {:edited, new_doc, deletion_delta_from_documents(doc, new_doc)}
    end
  end

  @spec deletion_delta_from_documents(Document.t(), Document.t()) :: EditDelta.t()
  defp deletion_delta_from_documents(%Document{} = old_doc, %Document{} = new_doc) do
    old_content = Document.content(old_doc)
    new_content = Document.content(new_doc)
    start_byte = :binary.longest_common_prefix([old_content, new_content])
    old_tail = byte_size(old_content) - start_byte
    new_tail = byte_size(new_content) - start_byte
    suffix_size = common_suffix_size(old_content, new_content, old_tail, new_tail)
    old_end_byte = byte_size(old_content) - suffix_size

    EditDelta.deletion(
      start_byte,
      old_end_byte,
      Position.from_point(old_doc, start_byte),
      Position.from_point(old_doc, old_end_byte)
    )
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
