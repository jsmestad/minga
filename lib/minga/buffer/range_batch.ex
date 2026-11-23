defmodule Minga.Buffer.RangeBatch do
  @moduledoc """
  Applies a run of separated range replacements to one document in a single pass.

  `Minga.Buffer.Operation.replace_ranges_with_patches/2` defines batch semantics: it applies characterwise inclusive range replacements one at a time, from the highest start position to the lowest, and each edit resolves its positions against the document the previous edit produced. Applying each edit that way copies and re-indexes the whole document, so a batch of `k` edits costs `k` document traversals.

  This module takes the longest leading run of edits, in that application order, whose sequential result it can reproduce exactly from one snapshot of the input document. It then assembles the result in one pass. The snapshot text must be valid UTF-8, and each edit in the run must satisfy all of these conditions:

  * Its replacement is valid UTF-8, and its positions are well-formed.
  * Its resolved span ends strictly before the span of the edit applied before it. Then every byte the edit reads, including the code point after its span, is still original text.
  * Both of its positions name existing lines. An earlier edit can add lines, so a position past the final line could name a different line in the sequential operation.
  * Its caret position, the earlier endpoint, has a column within its line. Then `Minga.Buffer.Cursor.place/2` keeps the same line and column after the deletion.
  * Its span starts and ends on code point boundaries.
  * After its span is deleted, its column is still a caret boundary. The sequential operation then inserts at the span start rather than at a snapped caret.

  Positions resolve through `Minga.Buffer.Selection`, carets through `Minga.Buffer.Cursor`, and the resulting cursor through `Minga.Buffer.Document`, so this module adds no coordinate rules of its own. The first edit that fails a condition ends the run, and the caller applies it sequentially. A run therefore costs a constant number of document traversals, plus work proportional to its edits and to the caret lines that need a grapheme check.
  """

  alias Minga.Buffer.Cursor
  alias Minga.Buffer.Document
  alias Minga.Buffer.Lines
  alias Minga.Buffer.Selection
  alias Minga.Buffer.Span
  alias Minga.Buffer.UndoPatch
  alias Minga.Core.Unicode

  @typedoc "A range replacement using Buffer's characterwise inclusive range semantics."
  @type range_edit :: {Document.position(), Document.position(), String.t()}

  # One edit resolved against the input snapshot.
  @typep step :: %{
           start: non_neg_integer(),
           stop: non_neg_integer(),
           caret: Document.position(),
           replacement: String.t()
         }

  @doc """
  Applies the longest leading run of `edits` that one pass can apply exactly.

  `snapshot` is `Minga.Buffer.Lines.snapshot/1` of `doc`, its text must be valid UTF-8, and `edits` must already be in application order. The result has the document after the run, the run's undo patches in newest-first recording order, and the edits after the run. Returns `:sequential` when the first edit must be applied on its own.
  """
  @spec apply_run(Document.t(), Lines.snapshot(), [range_edit()]) ::
          {:applied, Document.t(), [UndoPatch.t()], [range_edit()]} | :sequential
  def apply_run(%Document{} = doc, {line_starts, text} = snapshot, edits)
      when is_tuple(line_starts) and is_binary(text) and is_list(edits) do
    case take_run(edits, snapshot, nil, []) do
      {[], _rest} ->
        :sequential

      {ascending_steps, rest} ->
        {new_doc, patches} = assemble(ascending_steps, text, Document.cursor(doc))
        {:applied, new_doc, patches, rest}
    end
  end

  @doc """
  Returns whether replacing `span` of valid UTF-8 `text` with `replacement` keeps the text valid.

  It is true when the replacement is valid and the span starts and ends on code point boundaries. The sequential operation may insert at a caret other than the span start, but a caret in valid text is also a code point boundary.
  """
  @spec keeps_valid_utf8?(String.t(), Span.t(), String.t()) :: boolean()
  def keeps_valid_utf8?(text, %Span{start: start, stop: stop}, replacement)
      when is_binary(text) and is_binary(replacement) do
    code_point_boundary?(text, start) and code_point_boundary?(text, stop) and
      Unicode.valid_utf8?(replacement)
  end

  # Steps accumulate lowest-first because every accepted step lies below the previous one.
  @spec take_run([range_edit()], Lines.snapshot(), non_neg_integer() | nil, [step()]) ::
          {[step()], [range_edit()]}
  defp take_run([], _snapshot, _limit, steps), do: {steps, []}

  defp take_run([edit | rest] = edits, snapshot, limit, steps) do
    case resolve(edit, snapshot, limit) do
      {:ok, step} -> take_run(rest, snapshot, step.start, [step | steps])
      :sequential -> {steps, edits}
    end
  end

  @spec resolve(term(), Lines.snapshot(), non_neg_integer() | nil) :: {:ok, step()} | :sequential
  defp resolve({from_pos, to_pos, replacement}, snapshot, limit) when is_binary(replacement) do
    if well_formed?(from_pos) and well_formed?(to_pos),
      do: resolve_positions(from_pos, to_pos, replacement, snapshot, limit),
      else: :sequential
  end

  defp resolve(_edit, _snapshot, _limit), do: :sequential

  @spec well_formed?(term()) :: boolean()
  defp well_formed?({line, col}),
    do: is_integer(line) and line >= 0 and is_integer(col) and col >= 0

  defp well_formed?(_position), do: false

  @spec resolve_positions(
          Document.position(),
          Document.position(),
          String.t(),
          Lines.snapshot(),
          non_neg_integer() | nil
        ) :: {:ok, step()} | :sequential
  defp resolve_positions(
         {from_line, _} = from_pos,
         {to_line, _} = to_pos,
         replacement,
         snapshot,
         limit
       ) do
    {line_starts, text} = snapshot

    %Selection{span: %Span{start: start, stop: stop}, cursor: caret} =
      Selection.characterwise_in(snapshot, from_pos, to_pos)

    step = %{start: start, stop: stop, caret: caret, replacement: replacement}

    if below?(stop, limit) and max(from_line, to_line) < tuple_size(line_starts) and
         caret_in_line?(line_starts, text, caret) and code_point_boundary?(text, start) and
         code_point_boundary?(text, stop) and Unicode.valid_utf8?(replacement) and
         insertion_at_start?(text, step) do
      {:ok, step}
    else
      :sequential
    end
  end

  @spec below?(non_neg_integer(), non_neg_integer() | nil) :: boolean()
  defp below?(_stop, nil), do: true
  defp below?(stop, limit), do: stop < limit

  @spec caret_in_line?(Lines.line_starts(), String.t(), Document.position()) :: boolean()
  defp caret_in_line?(line_starts, text, {line, col}) do
    case Lines.span(line_starts, line, byte_size(text)) do
      {_line_start, line_length} -> col <= line_length
      nil -> false
    end
  end

  @spec code_point_boundary?(String.t(), non_neg_integer()) :: boolean()
  defp code_point_boundary?(text, point) when point >= byte_size(text), do: true

  defp code_point_boundary?(text, point),
    do: Bitwise.band(:binary.at(text, point), 0xC0) != 0x80

  # `Cursor.place/2` decides where the deleted span's replacement goes. Before a line end it
  # reads nothing. Otherwise it segments the caret's line through the code point after the
  # caret. Because the span ends below every earlier edit, that is the original code point
  # after the span, followed by a code point boundary. ASCII on both sides of the caret is
  # always a grapheme boundary; anything else asks Cursor about exactly the text it would read.
  @spec insertion_at_start?(String.t(), step()) :: boolean()
  defp insertion_at_start?(_text, %{caret: {_line, 0}}), do: true
  defp insertion_at_start?(text, %{stop: stop}) when stop == byte_size(text), do: true

  defp insertion_at_start?(text, %{start: start, stop: stop, caret: {_line, col}}) do
    case binary_part(text, stop, byte_size(text) - stop) do
      <<?\n, _rest::binary>> ->
        true

      <<following, _rest::binary>> when following < 0x80 ->
        :binary.at(text, start - 1) < 0x80 or caret_boundary?(text, start, col, <<following>>)

      <<code_point::utf8, _rest::binary>> ->
        caret_boundary?(text, start, col, <<code_point::utf8>>)
    end
  end

  @spec caret_boundary?(String.t(), non_neg_integer(), non_neg_integer(), String.t()) ::
          boolean()
  defp caret_boundary?(text, start, col, following),
    do: Cursor.caret_boundary?(binary_part(text, start - col, col) <> following, col)

  # The lowest step is applied last, so the result ends with its insertion exactly as the
  # sequential operation leaves it: the caret placed after deleting the span, then the text
  # inserted there.
  @spec assemble([step(), ...], String.t(), Document.position()) ::
          {Document.t(), [UndoPatch.t()]}
  defp assemble([lowest | higher] = ascending_steps, text, input_cursor) do
    {chunks, point} =
      Enum.reduce(higher, {[], lowest.stop}, fn step, {chunks, point} ->
        {[step.replacement, binary_part(text, point, step.start - point) | chunks], step.stop}
      end)

    suffix = binary_part(text, point, byte_size(text) - point)

    without_lowest =
      IO.iodata_to_binary([
        binary_part(text, 0, lowest.start) | Enum.reverse([suffix | chunks])
      ])

    new_doc =
      without_lowest
      |> Document.new()
      |> Document.move_to(lowest.caret)
      |> Document.insert_text(lowest.replacement)

    {new_doc, patches(ascending_steps, text, input_cursor)}
  end

  # Each patch restores the cursor of the document before its edit: the input cursor for the
  # highest step, otherwise the cursor the next higher step's insertion left behind.
  @spec patches([step()], String.t(), Document.position()) :: [UndoPatch.t()]
  defp patches([step], text, input_cursor), do: [patch(step, text, input_cursor)]

  defp patches([step, next_higher | _] = ascending_steps, text, input_cursor) do
    cursor = Document.position_after_insert(next_higher.caret, next_higher.replacement)
    [patch(step, text, cursor) | patches(tl(ascending_steps), text, input_cursor)]
  end

  @spec patch(step(), String.t(), Document.position()) :: UndoPatch.t()
  defp patch(step, text, cursor) do
    old_text = binary_part(text, step.start, step.stop - step.start)
    UndoPatch.replacement(step.start, old_text, step.replacement, cursor)
  end
end
