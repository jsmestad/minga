defmodule Minga.Buffer.RangeBatch do
  @moduledoc """
  Applies a run of separated range replacements to one document in a single pass.

  `Minga.Buffer.Operation.replace_ranges_with_patches/2` defines batch semantics: it applies characterwise inclusive range replacements one at a time, from the highest start position to the lowest, and each edit resolves its positions against the document the previous edit produced. Each edit clamps its positions to existing text, deletes its span, and inserts its replacement where the span started. Applying each edit that way copies and re-indexes the whole document, so a batch of `k` edits costs `k` document traversals.

  This module takes the longest leading run of edits, in that application order, whose sequential result it can reproduce exactly from one snapshot of the input document. It then assembles the result in one pass. The snapshot text must be valid UTF-8, and each edit in the run must satisfy all of these conditions:

  * Its replacement is valid UTF-8, and its positions are well-formed.
  * Its resolved span ends strictly before the span of the edit applied before it. Then every byte the edit reads, including the line lengths its positions clamp against, is still original text.
  * Both of its positions name existing lines. An earlier edit can add lines, so a position past the final line could name a different line in the sequential operation.
  * Its span starts and ends on code point boundaries, so the result stays valid UTF-8.

  Positions resolve through `Minga.Buffer.Selection` and the resulting cursor through `Minga.Buffer.Document`, so this module adds no coordinate rules of its own. The first edit that fails a condition ends the run, and the caller applies it sequentially. A run therefore costs a constant number of document traversals, plus work proportional to its edits.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Lines
  alias Minga.Buffer.Selection
  alias Minga.Buffer.Span
  alias Minga.Buffer.UndoPatch
  alias Minga.Core.Unicode

  @typedoc "A range replacement using Buffer's characterwise inclusive range semantics."
  @type range_edit :: {Document.position(), Document.position(), String.t()}

  @typedoc "A range replacement paired with its index in the caller's batch, for error reports."
  @type indexed_edit :: {range_edit(), non_neg_integer()}

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
  @spec apply_run(Document.t(), Lines.snapshot(), [indexed_edit()]) ::
          {:applied, Document.t(), [UndoPatch.t()], [indexed_edit()]} | :sequential
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

  # Steps accumulate lowest-first because every accepted step lies below the previous one.
  @spec take_run([indexed_edit()], Lines.snapshot(), non_neg_integer() | nil, [step()]) ::
          {[step()], [indexed_edit()]}
  defp take_run([], _snapshot, _limit, steps), do: {steps, []}

  defp take_run([{edit, _index} | rest] = edits, snapshot, limit, steps) do
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
      Selection.clamped_characterwise_in(snapshot, from_pos, to_pos)

    if below?(stop, limit) and max(from_line, to_line) < tuple_size(line_starts) and
         code_point_boundary?(text, start) and code_point_boundary?(text, stop) and
         Unicode.valid_utf8?(replacement) do
      {:ok, %{start: start, stop: stop, caret: caret, replacement: replacement}}
    else
      :sequential
    end
  end

  @spec below?(non_neg_integer(), non_neg_integer() | nil) :: boolean()
  defp below?(_stop, nil), do: true
  defp below?(stop, limit), do: stop < limit

  @spec code_point_boundary?(String.t(), non_neg_integer()) :: boolean()
  defp code_point_boundary?(text, point) when point >= byte_size(text), do: true

  defp code_point_boundary?(text, point),
    do: Bitwise.band(:binary.at(text, point), 0xC0) != 0x80

  # Every replacement goes where its span started, and the cursor lands after the lowest one,
  # exactly where the sequential operation leaves it.
  @spec assemble([step(), ...], String.t(), Document.position()) ::
          {Document.t(), [UndoPatch.t()]}
  defp assemble([lowest | _higher] = ascending_steps, text, input_cursor) do
    {chunks, point} =
      Enum.reduce(ascending_steps, {[binary_part(text, 0, lowest.start)], lowest.start}, fn
        step, {chunks, point} ->
          {[step.replacement, binary_part(text, point, step.start - point) | chunks], step.stop}
      end)

    suffix = binary_part(text, point, byte_size(text) - point)

    new_doc =
      [suffix | chunks]
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> Document.new_at(Document.position_after_insert(lowest.caret, lowest.replacement))

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
