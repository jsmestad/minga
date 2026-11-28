defmodule Minga.Buffer.EditDelta do
  @moduledoc """
  Describes a single edit applied to a buffer's content.

  Edit deltas are used for incremental content sync with the tree-sitter
  parser process. Instead of sending the entire file content after each
  change, the BEAM sends compact deltas that describe what changed and
  where. The parser applies these to its stored copy of the source and
  performs an incremental reparse.

  ## Fields

  - `start_byte` — byte offset where the edit begins
  - `old_end_byte` — byte offset where the old (removed) text ends
  - `new_end_byte` — byte offset where the new (inserted) text ends
  - `start_position` — `{line, col}` at `start_byte`
  - `old_end_position` — `{line, col}` at `old_end_byte`
  - `new_end_position` — `{line, col}` at `new_end_byte`
  - `inserted_text` — the text that was inserted (empty for pure deletions)
  """

  @enforce_keys [
    :start_byte,
    :old_end_byte,
    :new_end_byte,
    :start_position,
    :old_end_position,
    :new_end_position,
    :inserted_text
  ]
  defstruct [
    :start_byte,
    :old_end_byte,
    :new_end_byte,
    :start_position,
    :old_end_position,
    :new_end_position,
    :inserted_text
  ]

  @type line_range :: {non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          start_byte: non_neg_integer(),
          old_end_byte: non_neg_integer(),
          new_end_byte: non_neg_integer(),
          start_position: {non_neg_integer(), non_neg_integer()},
          old_end_position: {non_neg_integer(), non_neg_integer()},
          new_end_position: {non_neg_integer(), non_neg_integer()},
          inserted_text: String.t()
        }

  @doc "Returns the current-coordinate line range affected by ordered deltas."
  @spec affected_line_range([t()], line_range() | nil) :: line_range() | nil
  def affected_line_range(deltas, prior_range \\ nil) when is_list(deltas) do
    Enum.reduce(deltas, prior_range, fn delta, range ->
      range
      |> transform_line_range(delta)
      |> union_line_range(delta_range(delta))
    end)
  end

  @typedoc """
  One replaced run of lines, in the coordinates of the document before any of the deltas:
  `delete_count` lines starting at `base_start` become `insert_count` lines.
  """
  @type line_splice ::
          {base_start :: non_neg_integer(), delete_count :: non_neg_integer(),
           insert_count :: pos_integer()}

  # A changed run of lines in current coordinates, with the net number of lines the edits added to it.
  @typep hunk :: {first :: non_neg_integer(), last :: non_neg_integer(), net :: integer()}

  @max_line_hunks 16

  @doc """
  Returns the disjoint line ranges, in current coordinates and ascending, that ordered deltas changed.

  Unlike `affected_line_range/2` this keeps edits in different places apart, so a caller reads only the
  lines each edit touched. `prior_ranges` are ranges that were already pending before the deltas; each is
  carried through the deltas. Ranges that touch are merged, and no more than #{@max_line_hunks} are returned:
  past that, the closest neighbours are merged.
  """
  @spec affected_line_ranges([t()], [line_range()]) :: [line_range()]
  def affected_line_ranges(deltas, prior_ranges \\ [])
      when is_list(deltas) and is_list(prior_ranges) do
    prior_ranges
    |> Enum.map(fn {first, last} -> {first, last, 0} end)
    |> Enum.sort()
    |> merge_touching()
    |> apply_to_hunks(deltas)
    |> limit_hunks()
    |> Enum.map(fn {first, last, _net} -> {first, last} end)
  end

  @doc """
  Returns the line splices that turn the document before ordered deltas into the document after them.

  The splices are ascending, disjoint, and all address the document before the deltas, so they can be
  applied in order with a running shift. The lines a splice inserts start at `base_start` plus the net
  lines added by the splices before it.
  """
  @spec line_splices([t()]) :: [line_splice()]
  def line_splices(deltas) when is_list(deltas) do
    {splices, _shift} =
      []
      |> apply_to_hunks(deltas)
      |> limit_hunks()
      |> Enum.map_reduce(0, fn {first, last, net}, shift ->
        insert_count = last - first + 1
        {{first - shift, insert_count - net, insert_count}, shift + net}
      end)

    splices
  end

  @doc "Returns the current-coordinate line ranges that ascending line splices insert."
  @spec inserted_line_ranges([line_splice()]) :: [line_range()]
  def inserted_line_ranges(splices) when is_list(splices) do
    {ranges, _shift} =
      Enum.map_reduce(splices, 0, fn {base_start, delete_count, insert_count}, shift ->
        first = base_start + shift
        {{first, first + insert_count - 1}, shift + insert_count - delete_count}
      end)

    ranges
  end

  @doc """
  Clamps ascending line ranges to a document of `line_count` lines and merges the ones that now touch.

  A range that starts past the end (the edit removed the last lines) becomes the last line.
  """
  @spec clamp_line_ranges([line_range()], non_neg_integer()) :: [line_range()]
  def clamp_line_ranges(ranges, line_count) when is_list(ranges) and is_integer(line_count) do
    last_line = max(line_count - 1, 0)

    ranges
    |> Enum.map(fn {first, last} ->
      bounded_first = min(first, last_line)
      {bounded_first, max(min(last, last_line), bounded_first), 0}
    end)
    |> merge_touching()
    |> Enum.map(fn {first, last, _net} -> {first, last} end)
  end

  @spec apply_to_hunks([hunk()], [t()]) :: [hunk()]
  defp apply_to_hunks(hunks, deltas) do
    # Merging only widens ranges, so limiting as we go is safe, and it keeps a long run of edits from
    # costing the number of edits times the number of hunks.
    Enum.reduce(deltas, hunks, fn delta, hunks ->
      hunks = apply_to_hunks_once(delta, hunks)

      if Enum.count_until(hunks, 2 * @max_line_hunks + 1) > 2 * @max_line_hunks,
        do: limit_hunks(hunks),
        else: hunks
    end)
  end

  @spec apply_to_hunks_once(t(), [hunk()]) :: [hunk()]
  defp apply_to_hunks_once(
         %__MODULE__{
           start_position: {start, _},
           old_end_position: {old_end, _},
           new_end_position: {new_end, _}
         } = delta,
         hunks
       ) do
    shift = new_end - old_end
    {delta_first, delta_last} = delta_range(delta)

    {before, rest} = Enum.split_while(hunks, fn {_first, last, _net} -> last < start end)

    {overlapping, following} =
      Enum.split_while(rest, fn {first, _last, _net} -> first <= old_end end)

    merged =
      Enum.reduce(overlapping, {delta_first, delta_last, shift}, fn {first, last, net},
                                                                    {acc_first, acc_last, acc_net} ->
        {moved_first, moved_last} = transform_range({first, last}, start, old_end, new_end)
        {min(acc_first, moved_first), max(acc_last, moved_last), acc_net + net}
      end)

    shifted = Enum.map(following, fn {first, last, net} -> {first + shift, last + shift, net} end)
    merge_touching(before ++ [merged | shifted])
  end

  @spec merge_touching([hunk()]) :: [hunk()]
  defp merge_touching(hunks) do
    hunks
    |> Enum.reduce([], fn
      {first, last, net}, [{prev_first, prev_last, prev_net} | done]
      when first <= prev_last + 1 ->
        [{prev_first, max(prev_last, last), prev_net + net} | done]

      hunk, done ->
        [hunk | done]
    end)
    |> Enum.reverse()
  end

  # Past the limit, merge the two neighbours with the fewest unchanged lines between them, repeatedly.
  @spec limit_hunks([hunk()]) :: [hunk()]
  defp limit_hunks(hunks) do
    if Enum.count_until(hunks, @max_line_hunks + 1) > @max_line_hunks,
      do: hunks |> merge_closest_pair() |> limit_hunks(),
      else: hunks
  end

  @spec merge_closest_pair([hunk()]) :: [hunk()]
  defp merge_closest_pair(hunks) do
    {_gap, index} =
      hunks
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index()
      |> Enum.map(fn {[{_first, last, _net}, {next_first, _next_last, _next_net}], index} ->
        {next_first - last, index}
      end)
      |> Enum.min()

    {head, [{first, _last, net}, {_next_first, next_last, next_net} | tail]} =
      Enum.split(hunks, index)

    head ++ [{first, next_last, net + next_net} | tail]
  end

  @doc "Creates a delta for an insertion at a position (no text removed)."
  @spec insertion(
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()},
          String.t(),
          {non_neg_integer(), non_neg_integer()}
        ) :: t()
  def insertion(byte_offset, {line, col}, text, {new_line, new_col}) do
    %__MODULE__{
      start_byte: byte_offset,
      old_end_byte: byte_offset,
      new_end_byte: byte_offset + byte_size(text),
      start_position: {line, col},
      old_end_position: {line, col},
      new_end_position: {new_line, new_col},
      inserted_text: text
    }
  end

  @doc "Creates a delta for a deletion at a position (no text inserted)."
  @spec deletion(
          non_neg_integer(),
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()},
          {non_neg_integer(), non_neg_integer()}
        ) :: t()
  def deletion(start_byte, old_end_byte, start_position, old_end_position) do
    %__MODULE__{
      start_byte: start_byte,
      old_end_byte: old_end_byte,
      new_end_byte: start_byte,
      start_position: start_position,
      old_end_position: old_end_position,
      new_end_position: start_position,
      inserted_text: ""
    }
  end

  @doc "Maps an inclusive line range through one edit without including an unrelated edit boundary."
  @spec transform_line_range(line_range() | nil, t()) :: line_range() | nil
  def transform_line_range(
        range,
        %__MODULE__{
          start_position: {start, _},
          old_end_position: {old_end, _},
          new_end_position: {new_end, _}
        }
      ),
      do: transform_range(range, start, old_end, new_end)

  @doc "Maps an inclusive byte range through one edit without including an unrelated edit boundary."
  @spec transform_byte_range(line_range(), t()) :: line_range()
  def transform_byte_range(range, %__MODULE__{} = delta),
    do: transform_range(range, delta.start_byte, delta.old_end_byte, delta.new_end_byte)

  @spec transform_range(
          line_range() | nil,
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          line_range() | nil
  defp transform_range(nil, _start, _old_end, _new_end), do: nil

  defp transform_range({_first, last} = range, start, _old_end, _new_end) when last < start,
    do: range

  defp transform_range({first, last}, _start, old_end, new_end) when first > old_end do
    shift = new_end - old_end
    {first + shift, last + shift}
  end

  defp transform_range({first, last}, start, old_end, new_end) do
    shifted_last = if last > old_end, do: last + new_end - old_end, else: new_end
    {min(first, start), max(new_end, shifted_last)}
  end

  @spec delta_range(t()) :: line_range()
  defp delta_range(%__MODULE__{
         start_position: {start, _},
         new_end_position: {new_end, _}
       }),
       do: {start, max(start, new_end)}

  @spec union_line_range(line_range() | nil, line_range()) :: line_range()
  defp union_line_range(nil, range), do: range

  defp union_line_range({first, last}, {new_first, new_last}),
    do: {min(first, new_first), max(last, new_last)}

  @doc "Creates a delta for a replacement (text removed and text inserted)."
  @spec replacement(
          non_neg_integer(),
          non_neg_integer(),
          {non_neg_integer(), non_neg_integer()},
          {non_neg_integer(), non_neg_integer()},
          String.t(),
          {non_neg_integer(), non_neg_integer()}
        ) :: t()
  def replacement(
        start_byte,
        old_end_byte,
        start_position,
        old_end_position,
        new_text,
        new_end_position
      ) do
    %__MODULE__{
      start_byte: start_byte,
      old_end_byte: old_end_byte,
      new_end_byte: start_byte + byte_size(new_text),
      start_position: start_position,
      old_end_position: old_end_position,
      new_end_position: new_end_position,
      inserted_text: new_text
    }
  end
end
