defmodule Minga.Buffer.Operation do
  @moduledoc """
  Pure buffer edit operations with delta generation.

  `Document` owns the gap-buffer data structure. This module owns domain edits that need both the updated document and the sync delta describing the change. `Buffer.Process` wraps these operations with process concerns like read-only checks, undo, dirty tracking, events, and persistence.
  """

  alias Minga.Buffer.Cursor
  alias Minga.Buffer.Document
  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.Lines
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

  @doc "Clears one line, returning the yanked text, new document, and delta."
  @spec clear_line(Document.t(), non_neg_integer()) ::
          :unchanged | {:edited, String.t(), Document.t(), EditDelta.t()}
  def clear_line(%Document{} = doc, line) when line >= 0 do
    case Lines.fetch(doc, line) do
      nil ->
        :unchanged

      "" ->
        clear_empty_line(doc, line)

      text ->
        clear_non_empty_line(doc, line, text)
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
    selection = Selection.linewise(doc, start_line, end_line)
    %Span{start: raw_start_byte, stop: old_end_byte} = selection.span
    start_byte = effective_linewise_delete_start(doc, raw_start_byte, old_end_byte)
    new_doc = Selection.delete(doc, selection)

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

  @spec clear_empty_line(Document.t(), non_neg_integer()) ::
          {:edited, String.t(), Document.t(), EditDelta.t()} | :unchanged
  defp clear_empty_line(%Document{} = doc, line) do
    new_doc = Cursor.place(doc, {line, 0})

    if new_doc == doc do
      :unchanged
    else
      start_byte = Position.point_for(doc, {line, 0})
      delta = EditDelta.deletion(start_byte, start_byte, {line, 0}, {line, 0})
      {:edited, "", new_doc, delta}
    end
  end

  @spec clear_non_empty_line(Document.t(), non_neg_integer(), String.t()) ::
          {:edited, String.t(), Document.t(), EditDelta.t()}
  defp clear_non_empty_line(%Document{} = doc, line, text) do
    start_pos = {line, 0}
    end_pos = {line, Position.last_character_on_line(text)}
    selection = Selection.characterwise(doc, start_pos, end_pos)
    %Span{start: start_byte, stop: old_end_byte} = selection.span
    {yanked, new_doc} = Selection.clear_line(doc, line)

    delta =
      EditDelta.deletion(
        start_byte,
        old_end_byte,
        Position.from_point(doc, start_byte),
        Position.from_point(doc, old_end_byte)
      )

    {:edited, yanked, new_doc, delta}
  end

  @spec effective_linewise_delete_start(Document.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp effective_linewise_delete_start(%Document{} = doc, start_byte, old_end_byte)
       when start_byte > 0 do
    do_effective_linewise_delete_start(start_byte, old_end_byte, Document.content_byte_size(doc))
  end

  defp effective_linewise_delete_start(%Document{}, start_byte, _old_end_byte), do: start_byte

  @spec do_effective_linewise_delete_start(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: non_neg_integer()
  defp do_effective_linewise_delete_start(start_byte, document_size, document_size) do
    start_byte - 1
  end

  defp do_effective_linewise_delete_start(start_byte, _old_end_byte, _document_size) do
    start_byte
  end
end
