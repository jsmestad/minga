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

  @typedoc "One indentation level to insert at, or remove from, the start of each line."
  @type line_shift :: {:indent, String.t()} | {:dedent, pos_integer()}

  @typedoc "Result of shifting lines: the new document, one delta per changed line, and one undo patch."
  @type shift_result ::
          :unchanged | {:shifted, Document.t(), nonempty_list(EditDelta.t()), UndoPatch.t()}

  @typedoc "A range replacement edit using Buffer's characterwise inclusive range semantics."
  @type range_edit :: {Document.position(), Document.position(), String.t()}

  @typedoc """
  Why a range replacement was rejected. Nothing is applied on error.

  * `:invalid_utf8` means the document would not be valid UTF-8 after the edit, for example because a position falls inside a multi-byte code point or the replacement is not valid UTF-8. A document that is already invalid also rejects every edit, because undo could never replay through it.
  * `:malformed_edit` means the edit is not `{{line, column}, {line, column}, replacement}` with non-negative integer positions and a binary replacement.
  """
  @type edit_error :: :invalid_utf8 | :malformed_edit

  @typedoc "Why a batch of range replacements was rejected, naming the edit by its index in the caller's list."
  @type batch_error :: {:edit_failed, non_neg_integer(), edit_error()}

  @doc "Inserts text at the current cursor and returns the updated document plus insertion delta."
  @spec insert_at_cursor(Document.t(), String.t()) :: {:edited, Document.t(), EditDelta.t()}
  def insert_at_cursor(%Document{} = doc, text) when is_binary(text) do
    start_byte = Document.cursor_offset(doc)
    start_position = Document.cursor(doc)
    new_doc = Document.insert_text(doc, text)
    delta = EditDelta.insertion(start_byte, start_position, text, Document.cursor(new_doc))

    {:edited, new_doc, delta}
  end

  @doc """
  Replaces a characterwise inclusive range and returns the updated document plus replacement delta.

  Positions are clamped to existing text first: a column past its line's content means the line end, and a line past the final line means the final line. The replacement is inserted where the deleted span started, which is the place the delta records, and the cursor lands after it.

  Returns `{:error, reason}`, with the document unchanged, when the edit is malformed or the result would not be valid UTF-8; see `t:edit_error/0`.
  """
  @spec replace_range(Document.t(), term(), term(), term()) :: result() | {:error, edit_error()}
  def replace_range(%Document{} = doc, from_pos, to_pos, replacement) do
    with :ok <- check_edit_shape({from_pos, to_pos, replacement}) do
      {_line_starts, text} = snapshot = Lines.snapshot(doc)

      if Unicode.valid_utf8?(text),
        do: replace_in_valid(doc, snapshot, {from_pos, to_pos, replacement}),
        else: {:error, :invalid_utf8}
    end
  end

  @spec check_edit_shape(term()) :: :ok | {:error, :malformed_edit}
  defp check_edit_shape({from_pos, to_pos, replacement}) when is_binary(replacement) do
    if position?(from_pos) and position?(to_pos), do: :ok, else: {:error, :malformed_edit}
  end

  defp check_edit_shape(_edit), do: {:error, :malformed_edit}

  @spec position?(term()) :: boolean()
  defp position?({line, column}),
    do: is_integer(line) and line >= 0 and is_integer(column) and column >= 0

  defp position?(_position), do: false

  # `snapshot` indexes `doc`, whose text is valid UTF-8, so checking the bytes around the splice
  # decides whether the whole result is valid.
  @spec replace_in_valid(Document.t(), Lines.snapshot(), range_edit()) ::
          result() | {:error, :invalid_utf8}
  defp replace_in_valid(doc, {_line_starts, text} = snapshot, {from_pos, to_pos, replacement}) do
    selection = Selection.clamped_characterwise_in(snapshot, from_pos, to_pos)

    if splice_keeps_valid_utf8?(text, selection.span, replacement),
      do: replace_selection(doc, text, selection, replacement),
      else: {:error, :invalid_utf8}
  end

  # `text` is the content of `doc`. The selection cursor is the position of the span start, so the
  # replacement goes exactly where the delta records it, and the cursor lands exactly after it,
  # as `Document.insert_text/2` leaves it. No grapheme segmentation runs, so text that is not valid
  # UTF-8 cannot make the edit raise.
  @spec replace_selection(Document.t(), String.t(), Selection.t(), String.t()) :: result()
  defp replace_selection(doc, text, %Selection{span: span, cursor: caret}, replacement)
       when is_binary(replacement) do
    %Span{start: start_byte, stop: old_end_byte} = span
    insert_end = Document.position_after_insert(caret, replacement)

    new_doc =
      [
        binary_part(text, 0, start_byte),
        replacement,
        binary_part(text, old_end_byte, byte_size(text) - old_end_byte)
      ]
      |> IO.iodata_to_binary()
      |> Document.new_at(insert_end)

    delta =
      EditDelta.replacement(
        start_byte,
        old_end_byte,
        Position.from_point(doc, start_byte),
        Position.from_point(doc, old_end_byte),
        replacement,
        insert_end
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

  @doc """
  Shifts each line in an inclusive range by one indentation level.

  `{:indent, unit}` inserts `unit` at the start of every line, including blank lines. `{:dedent, width}` removes one leading tab, or up to `width` leading spaces, from every line; see `dedent_bytes/2`. Lines past the end of the document are ignored.

  Returns one delta per changed line, in application order: each delta describes the text as it stands after the previous delta, so parser and LSP clients replay them exactly as they would replay one edit per line. Only the selected lines are read and rewritten, and the single undo patch spans them, so undoing the shift is one patch application.
  """
  @spec shift_lines(Document.t(), non_neg_integer(), non_neg_integer(), line_shift()) ::
          shift_result()
  def shift_lines(%Document{} = doc, start_line, end_line, shift)
      when is_integer(start_line) and start_line >= 0 and is_integer(end_line) and
             end_line >= start_line do
    line_count = Document.line_count(doc)

    if start_line >= line_count do
      :unchanged
    else
      last_line = min(end_line, line_count - 1)
      span_start = Lines.start_of(doc, start_line)
      span_end = line_end(doc, last_line, line_count)
      old_text = Document.slice_byte_range(doc, span_start, span_end - span_start)

      old_text
      |> :binary.split("\n", [:global])
      |> plan_shift(start_line, span_start, shift)
      |> apply_shift(doc, {start_line, last_line}, {span_start, span_end})
    end
  end

  @doc "Returns how many leading bytes one dedent level removes from `line`: one tab, or up to `width` spaces."
  @spec dedent_bytes(String.t(), pos_integer()) :: non_neg_integer()
  def dedent_bytes(<<"\t", _rest::binary>>, _width), do: 1

  def dedent_bytes(line, width) when is_binary(line) and is_integer(width) and width > 0 do
    count_leading_spaces(line, 0, width)
  end

  @spec count_leading_spaces(binary(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp count_leading_spaces(_line, width, width), do: width

  defp count_leading_spaces(<<" ", rest::binary>>, n, width),
    do: count_leading_spaces(rest, n + 1, width)

  defp count_leading_spaces(_line, n, _width), do: n

  @spec line_end(Document.t(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp line_end(doc, line, line_count) when line + 1 < line_count,
    do: Lines.start_of(doc, line + 1) - 1

  defp line_end(doc, _line, _line_count), do: Document.content_byte_size(doc)

  # Walks the selected lines once. `start` is each line's offset in the
  # original document and `growth` the bytes added so far, so `start + growth`
  # is where the line starts once the earlier deltas are applied.
  @spec plan_shift([binary()], non_neg_integer(), non_neg_integer(), line_shift()) ::
          {iodata(), [EditDelta.t()]}
  defp plan_shift(lines, first_line, span_start, shift) do
    {pieces, deltas, _line, _start, _growth} =
      Enum.reduce(lines, {[], [], first_line, span_start, 0}, fn text,
                                                                 {pieces, deltas, line, start,
                                                                  growth} ->
        {removed, inserted} = line_prefix_edit(shift, text)
        kept = binary_part(text, removed, byte_size(text) - removed)
        pieces = [kept, inserted, "\n" | pieces]
        next_start = start + byte_size(text) + 1

        case {removed, inserted} do
          {0, ""} ->
            {pieces, deltas, line + 1, next_start, growth}

          _ ->
            delta = line_start_delta(line, start + growth, removed, inserted)

            {pieces, [delta | deltas], line + 1, next_start,
             growth + byte_size(inserted) - removed}
        end
      end)

    # Every line was preceded by a separator; the first one is not part of the span.
    [_separator | replacement] = Enum.reverse(pieces)
    {replacement, Enum.reverse(deltas)}
  end

  @spec line_prefix_edit(line_shift(), binary()) :: {non_neg_integer(), String.t()}
  defp line_prefix_edit({:indent, unit}, _line), do: {0, unit}
  defp line_prefix_edit({:dedent, width}, line), do: {dedent_bytes(line, width), ""}

  @spec line_start_delta(non_neg_integer(), non_neg_integer(), non_neg_integer(), String.t()) ::
          EditDelta.t()
  defp line_start_delta(line, start_byte, removed, inserted) do
    EditDelta.replacement(
      start_byte,
      start_byte + removed,
      {line, 0},
      {line, removed},
      inserted,
      {line, byte_size(inserted)}
    )
  end

  @spec apply_shift(
          {iodata(), [EditDelta.t()]},
          Document.t(),
          {non_neg_integer(), non_neg_integer()},
          {non_neg_integer(), non_neg_integer()}
        ) :: shift_result()
  defp apply_shift({_replacement, []}, _doc, _lines, _span), do: :unchanged

  defp apply_shift({replacement, deltas}, doc, {first_line, last_line}, {span_start, span_end}) do
    replacement = IO.iodata_to_binary(replacement)
    new_doc = Document.replace_line_span(doc, first_line, last_line, replacement)

    span =
      EditDelta.replacement(
        span_start,
        span_end,
        {first_line, 0},
        Position.from_point(doc, span_end),
        replacement,
        Document.cursor(new_doc)
      )

    {:shifted, new_doc, deltas, UndoPatch.from_delta(span, doc)}
  end

  @doc """
  Applies multiple range replacements and returns undo patches in newest-first recording order.

  Edits apply one at a time from the highest start position to the lowest, and each edit resolves its positions against the document the previous edit produced, with `replace_range/4` semantics. `Minga.Buffer.RangeBatch` applies each run of separated edits in one pass with that exact result; any other edit applies on its own.

  The input document and every document the batch produces must be valid UTF-8, because undo and redo replay the patches through those documents. Otherwise nothing is applied and the error names the first edit, by its index in `edits`, whose application would leave invalid UTF-8. When the input is already invalid, that is the first edit in application order.

  A malformed edit rejects the batch before anything else is checked, with `:malformed_edit` and the index of the first malformed edit.
  """
  @spec replace_ranges_with_patches(Document.t(), [term()]) ::
          {:ok, Document.t(), [UndoPatch.t()]} | {:error, batch_error()}
  def replace_ranges_with_patches(%Document{} = doc, []), do: {:ok, doc, []}

  def replace_ranges_with_patches(%Document{} = doc, edits) when is_list(edits) do
    with :ok <- check_batch_shape(edits, 0) do
      {_line_starts, text} = snapshot = Lines.snapshot(doc)

      ordered =
        edits
        |> Enum.with_index()
        |> Enum.sort(fn {{from_a, _, _}, _}, {{from_b, _, _}, _} -> from_a >= from_b end)

      if Unicode.valid_utf8?(text) do
        replace_ordered(ordered, doc, snapshot, [])
      else
        [{_edit, index} | _rest] = ordered
        {:error, {:edit_failed, index, :invalid_utf8}}
      end
    end
  end

  @spec check_batch_shape([term()], non_neg_integer()) :: :ok | {:error, batch_error()}
  defp check_batch_shape([], _index), do: :ok

  defp check_batch_shape([edit | rest], index) do
    case check_edit_shape(edit) do
      :ok -> check_batch_shape(rest, index + 1)
      {:error, reason} -> {:error, {:edit_failed, index, reason}}
    end
  end

  # One edit gains nothing from a run, so it applies on its own.
  @spec replace_ordered(
          [RangeBatch.indexed_edit(), ...],
          Document.t(),
          Lines.snapshot(),
          [UndoPatch.t()]
        ) :: {:ok, Document.t(), [UndoPatch.t()]} | {:error, batch_error()}
  defp replace_ordered([_edit] = edits, doc, snapshot, patches),
    do: replace_next(edits, doc, snapshot, patches)

  defp replace_ordered(edits, doc, snapshot, patches) do
    case RangeBatch.apply_run(doc, snapshot, edits) do
      {:applied, new_doc, run_patches, remaining} ->
        continue_ordered(remaining, new_doc, run_patches ++ patches)

      :sequential ->
        replace_next(edits, doc, snapshot, patches)
    end
  end

  # Reuses the run's snapshot, so an edit applied on its own costs what it did before.
  @spec replace_next(
          [RangeBatch.indexed_edit(), ...],
          Document.t(),
          Lines.snapshot(),
          [UndoPatch.t()]
        ) :: {:ok, Document.t(), [UndoPatch.t()]} | {:error, batch_error()}
  defp replace_next([{edit, index} | rest], doc, snapshot, patches) do
    case replace_in_valid(doc, snapshot, edit) do
      {:edited, new_doc, delta} ->
        continue_ordered(rest, new_doc, [UndoPatch.from_delta(delta, doc) | patches])

      {:error, reason} ->
        {:error, {:edit_failed, index, reason}}
    end
  end

  @spec continue_ordered([RangeBatch.indexed_edit()], Document.t(), [UndoPatch.t()]) ::
          {:ok, Document.t(), [UndoPatch.t()]} | {:error, batch_error()}
  defp continue_ordered([], doc, patches), do: {:ok, doc, patches}

  defp continue_ordered(edits, doc, patches),
    do: replace_ordered(edits, doc, Lines.snapshot(doc), patches)

  # `text` is valid UTF-8, so everything before the code point holding `start` and everything
  # from the code point boundary at or after `stop` stays valid. The result is valid exactly when
  # the bytes between those two boundaries, with the replacement spliced in, are valid.
  @spec splice_keeps_valid_utf8?(String.t(), Span.t(), String.t()) :: boolean()
  defp splice_keeps_valid_utf8?(text, %Span{start: start, stop: stop}, replacement)
       when is_binary(replacement) do
    lead = start - code_point_start(text, start)
    trail = code_point_end(text, stop) - stop

    Unicode.valid_utf8?(
      binary_part(text, start - lead, lead) <> replacement <> binary_part(text, stop, trail)
    )
  end

  @spec code_point_start(String.t(), non_neg_integer()) :: non_neg_integer()
  defp code_point_start(text, point) do
    if continuation_byte?(text, point), do: code_point_start(text, point - 1), else: point
  end

  @spec code_point_end(String.t(), non_neg_integer()) :: non_neg_integer()
  defp code_point_end(text, point) do
    if continuation_byte?(text, point), do: code_point_end(text, point + 1), else: point
  end

  @spec continuation_byte?(String.t(), non_neg_integer()) :: boolean()
  defp continuation_byte?(text, point) when point > 0 and point < byte_size(text),
    do: Bitwise.band(:binary.at(text, point), 0xC0) == 0x80

  defp continuation_byte?(_text, _point), do: false

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
