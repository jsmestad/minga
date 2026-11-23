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
  alias Minga.Buffer.RangeBatch
  alias Minga.Buffer.Selection
  alias Minga.Buffer.Span
  alias Minga.Buffer.UndoPatch
  alias Minga.Core.Unicode

  @typedoc "Result of a pure edit operation."
  @type result :: :unchanged | {:edited, Document.t(), EditDelta.t()}

  @typedoc "Result of replacing an explicitly byte-sized range."
  @type byte_range_result :: result() | {:error, :invalid_range}

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
    replace_selection(doc, Selection.characterwise(doc, from_pos, to_pos), replacement)
  end

  @spec replace_selection(Document.t(), Selection.t(), String.t()) :: result()
  defp replace_selection(doc, selection, replacement) when is_binary(replacement) do
    %Span{start: start_byte, stop: old_end_byte} = selection.span

    new_doc =
      doc
      |> Selection.delete(selection)
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

  @doc "Replaces complete lines, adding a separator only when the replacement needs one before an unselected following line."
  @spec replace_lines(Document.t(), non_neg_integer(), non_neg_integer(), String.t()) :: result()
  def replace_lines(%Document{} = doc, start_line, end_line, replacement)
      when start_line >= 0 and end_line >= 0 and is_binary(replacement) do
    selection = Selection.linewise(doc, start_line, end_line)
    %Span{start: start_byte, stop: old_end_byte} = selection.span

    effective_replacement =
      normalize_linewise_replacement(
        replacement,
        unselected_line_follows?(doc, start_line, end_line)
      )

    new_doc =
      Document.replace_at_byte_range(
        doc,
        start_byte,
        old_end_byte - start_byte,
        effective_replacement,
        {0, 0}
      )

    cursor_byte = start_byte + byte_size(replacement)
    new_end_byte = start_byte + byte_size(effective_replacement)
    cursor_position = Position.from_point(new_doc, cursor_byte)
    new_end_position = Position.from_point(new_doc, new_end_byte)
    new_doc = Document.move_to(new_doc, cursor_position)

    delta =
      EditDelta.replacement(
        start_byte,
        old_end_byte,
        Position.from_point(doc, start_byte),
        Position.from_point(doc, old_end_byte),
        effective_replacement,
        new_end_position
      )

    {:edited, new_doc, delta}
  end

  @spec unselected_line_follows?(Document.t(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp unselected_line_follows?(%Document{} = doc, start_line, end_line) do
    last_selected_line = min(max(start_line, end_line), Document.line_count(doc) - 1)
    last_selected_line + 1 < Document.line_count(doc)
  end

  @spec normalize_linewise_replacement(String.t(), boolean()) :: String.t()
  defp normalize_linewise_replacement(replacement, true) do
    if String.ends_with?(replacement, "\n"), do: replacement, else: replacement <> "\n"
  end

  defp normalize_linewise_replacement(replacement, false), do: replacement

  @doc "Replaces a half-open byte range beginning at an editor position."
  @spec replace_byte_range(Document.t(), Document.position(), non_neg_integer(), String.t()) ::
          byte_range_result()
  def replace_byte_range(%Document{} = doc, {line, col} = position, byte_length, replacement)
      when is_integer(line) and line >= 0 and is_integer(col) and col >= 0 and
             is_integer(byte_length) and byte_length >= 0 and is_binary(replacement) do
    with {:ok, start_byte, old_end_byte} <- resolve_byte_range(doc, position, byte_length) do
      if Unicode.valid_utf8?(replacement) do
        replace_valid_byte_range(
          doc,
          position,
          start_byte,
          old_end_byte,
          byte_length,
          replacement
        )
      else
        {:error, :invalid_range}
      end
    end
  end

  def replace_byte_range(%Document{}, _position, byte_length, replacement)
      when is_integer(byte_length) and byte_length >= 0 and is_binary(replacement),
      do: {:error, :invalid_range}

  @spec resolve_byte_range(Document.t(), Document.position(), non_neg_integer()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, :invalid_range}
  defp resolve_byte_range(doc, {line, col} = position, byte_length) do
    case Lines.fetch(doc, line) do
      text when is_binary(text) and col <= byte_size(text) ->
        start_byte = Position.point_for(doc, position)
        end_byte = start_byte + byte_length

        # A valid prefix ends at a code point, so validate the removed bytes separately.
        if end_byte <= Document.content_byte_size(doc) and
             Unicode.valid_utf8?(Document.slice_byte_range(doc, 0, start_byte)) and
             Unicode.valid_utf8?(Document.slice_byte_range(doc, start_byte, byte_length)) do
          {:ok, start_byte, end_byte}
        else
          {:error, :invalid_range}
        end

      _missing_or_short ->
        {:error, :invalid_range}
    end
  end

  @spec replace_valid_byte_range(
          Document.t(),
          Document.position(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: result()
  defp replace_valid_byte_range(_doc, _position, _start, _old_end, 0, ""), do: :unchanged

  defp replace_valid_byte_range(
         doc,
         position,
         start_byte,
         old_end_byte,
         byte_length,
         replacement
       ) do
    old_end_position = Position.from_point(doc, old_end_byte)
    new_doc = Document.replace_at_byte_range(doc, start_byte, byte_length, replacement, {0, 0})
    new_end_byte = start_byte + byte_size(replacement)
    new_end_position = Position.from_point(new_doc, new_end_byte)
    new_doc = Document.move_to(new_doc, new_end_position)

    delta =
      EditDelta.replacement(
        start_byte,
        old_end_byte,
        position,
        old_end_position,
        replacement,
        new_end_position
      )

    {:edited, new_doc, delta}
  end

  @doc "Applies multiple range replacements from the end of the document toward the start."
  @spec replace_ranges(Document.t(), [range_edit()]) :: Document.t()
  def replace_ranges(%Document{} = doc, edits) when is_list(edits) do
    {new_doc, _patches} = replace_ranges_with_patches(doc, edits)
    new_doc
  end

  @doc """
  Applies multiple range replacements and returns undo patches in newest-first recording order.

  Edits apply one at a time from the highest start position to the lowest, and each edit resolves its positions against the document the previous edit produced. `Minga.Buffer.RangeBatch` applies each run of separated edits in one pass with that exact result; any other edit applies on its own.
  """
  @spec replace_ranges_with_patches(Document.t(), [range_edit()]) ::
          {Document.t(), [UndoPatch.t()]}
  def replace_ranges_with_patches(%Document{} = doc, []), do: {doc, []}

  def replace_ranges_with_patches(%Document{} = doc, edits) when is_list(edits) do
    edits
    |> Enum.sort(fn {from_a, _, _}, {from_b, _, _} -> from_a >= from_b end)
    |> replace_ordered(doc, Lines.snapshot(doc), :unchecked, [])
  end

  # Runs need valid UTF-8, because they skip grapheme scans that raise on invalid text. The
  # check waits until at least two edits remain, since one edit gains nothing from a run. Once
  # an edit may have produced invalid text, the rest of the batch applies one edit at a time.
  @typep text_check :: :unchecked | :valid_utf8 | :unverified

  @spec replace_ordered(
          [range_edit(), ...],
          Document.t(),
          Lines.snapshot(),
          text_check(),
          [UndoPatch.t()]
        ) :: {Document.t(), [UndoPatch.t()]}
  defp replace_ordered([_edit] = edits, doc, snapshot, check, patches),
    do: replace_next(edits, doc, snapshot, check, patches)

  defp replace_ordered(edits, doc, {_line_starts, text} = snapshot, :unchecked, patches) do
    check = if Unicode.valid_utf8?(text), do: :valid_utf8, else: :unverified
    replace_ordered(edits, doc, snapshot, check, patches)
  end

  defp replace_ordered(edits, doc, snapshot, :valid_utf8, patches) do
    case RangeBatch.apply_run(doc, snapshot, edits) do
      {:applied, new_doc, run_patches, remaining} ->
        continue_ordered(remaining, new_doc, :valid_utf8, run_patches ++ patches)

      :sequential ->
        replace_next(edits, doc, snapshot, :valid_utf8, patches)
    end
  end

  defp replace_ordered(edits, doc, snapshot, :unverified, patches),
    do: replace_next(edits, doc, snapshot, :unverified, patches)

  # Reuses the run's snapshot, so an edit applied on its own costs what it did before.
  @spec replace_next(
          [range_edit(), ...],
          Document.t(),
          Lines.snapshot(),
          text_check(),
          [UndoPatch.t()]
        ) :: {Document.t(), [UndoPatch.t()]}
  defp replace_next([{from_pos, to_pos, replacement} | rest], doc, snapshot, check, patches) do
    {_line_starts, text} = snapshot
    selection = Selection.characterwise_in(snapshot, from_pos, to_pos)
    {:edited, new_doc, delta} = replace_selection(doc, selection, replacement)
    patches = [UndoPatch.from_delta(delta, doc) | patches]

    continue_ordered(rest, new_doc, check_after(check, text, selection, replacement), patches)
  end

  @spec check_after(text_check(), String.t(), Selection.t(), String.t()) :: text_check()
  defp check_after(:valid_utf8, text, %Selection{span: span}, replacement) do
    if RangeBatch.keeps_valid_utf8?(text, span, replacement), do: :valid_utf8, else: :unverified
  end

  defp check_after(check, _text, _selection, _replacement), do: check

  @spec continue_ordered([range_edit()], Document.t(), text_check(), [UndoPatch.t()]) ::
          {Document.t(), [UndoPatch.t()]}
  defp continue_ordered([], doc, _check, patches), do: {doc, patches}

  defp continue_ordered(edits, doc, check, patches),
    do: replace_ordered(edits, doc, Lines.snapshot(doc), check, patches)

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
      removed = Document.content_byte_size(doc) - Document.content_byte_size(new_doc)
      old_end_byte = start_byte + removed

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
    delete_selection(doc, Selection.characterwise(doc, from_pos, to_pos))
  end

  @doc "Deletes a linewise range and returns a deletion delta."
  @spec delete_lines(Document.t(), non_neg_integer(), non_neg_integer()) :: result()
  def delete_lines(%Document{} = doc, start_line, end_line)
      when start_line >= 0 and end_line >= 0 do
    delete_selection(doc, Selection.linewise(doc, start_line, end_line))
  end

  @spec delete_selection(Document.t(), Selection.t()) :: result()
  defp delete_selection(doc, selection) do
    {new_doc, %Span{start: start_byte, stop: old_end_byte}} =
      Selection.delete_with_span(doc, selection)

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
end
