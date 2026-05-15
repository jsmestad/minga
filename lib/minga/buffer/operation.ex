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
    edits
    |> Enum.sort(fn {from_a, _, _}, {from_b, _, _} -> from_a >= from_b end)
    |> Enum.reduce(doc, fn {from_pos, to_pos, replacement}, acc ->
      {:edited, new_doc, _delta} = replace_range(acc, from_pos, to_pos, replacement)
      new_doc
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
    selection = Selection.linewise(doc, start_line, end_line)
    %Span{start: start_byte, stop: old_end_byte} = selection.span
    new_doc = Document.delete_lines(doc, start_line, end_line)

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
end
