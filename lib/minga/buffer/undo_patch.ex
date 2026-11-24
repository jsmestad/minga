defmodule Minga.Buffer.UndoPatch do
  @moduledoc """
  Reversible byte-range edit for undo and redo history.

  A patch records the bytes removed and inserted by one atomic edit, plus the cursor position to restore when that patch is applied. Undo history stores patches instead of full document snapshots so memory usage follows edit size rather than file size.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.EditDelta
  alias Minga.Core.Diff
  alias Minga.Core.Unicode

  @enforce_keys [:start_byte, :old_text, :new_text, :cursor]
  defstruct [:start_byte, :old_text, :new_text, :cursor]

  @affix_chunk_bytes 4096

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
      Document.slice_byte_range(
        old_document,
        delta.start_byte,
        delta.old_end_byte - delta.start_byte
      )

    replacement(delta.start_byte, old_text, delta.inserted_text, Document.cursor(old_document))
  end

  @doc """
  Builds a patch for replacing `old_text` at `start_byte` with `new_text`.

  `cursor` is the position to restore when undo applies the patch, normally the cursor of the document before the edit. Both fragments are copied so the patch never keeps a larger document binary alive.
  """
  @spec replacement(non_neg_integer(), byte_fragment(), byte_fragment(), Document.position()) ::
          t()
  def replacement(start_byte, old_text, new_text, cursor)
      when is_integer(start_byte) and start_byte >= 0 and is_binary(old_text) and
             is_binary(new_text) do
    %__MODULE__{
      start_byte: start_byte,
      old_text: own_binary(old_text),
      new_text: own_binary(new_text),
      cursor: cursor
    }
  end

  @doc """
  Builds a minimal byte-range patch from two document versions.

  The common suffix is measured only on the bytes after the common prefix, so the two never overlap. Boundaries are byte offsets and may fall inside a UTF-8 codepoint. Documents are compared in bounded chunks without materializing their full content; only the changed fragments are retained.
  """
  @spec from_documents(Document.t(), Document.t()) :: t()
  def from_documents(%Document{} = old_document, %Document{} = new_document) do
    old_size = Document.content_byte_size(old_document)
    new_size = Document.content_byte_size(new_document)
    shared_limit = min(old_size, new_size)
    start_byte = common_prefix_size(old_document, new_document, 0, shared_limit)

    suffix_size =
      common_suffix_size(old_document, new_document, 0, shared_limit - start_byte)

    %__MODULE__{
      start_byte: start_byte,
      old_text: changed_fragment(old_document, start_byte, old_size - start_byte - suffix_size),
      new_text: changed_fragment(new_document, start_byte, new_size - start_byte - suffix_size),
      cursor: Document.cursor(old_document)
    }
  end

  @doc """
  Builds one patch per changed region between two document versions, ordered for one batch history entry.

  Regions come from `Minga.Core.Diff.diff_lines/2` over lines that keep their newline, so every patch covers whole lines, the unchanged lines between two regions stay out of every patch, and the patches rebuild the content of `new_document` exactly. Each patch restores the cursor of `old_document`, as `from_documents/2` does.

  The region nearest the start of the document comes first, the order `Minga.Buffer.UndoHistory.record_edit_batch/5` expects for a batch whose regions were applied from the end of the document to its start. Returns `[]` when both documents hold the same content.

  The cost stays bounded. Leading and trailing lines the documents share are skipped before diffing. The line diff costs time proportional to the remaining line count times the number of differing lines, so when that product would exceed a fixed budget, as in a rewrite, reindent, or reorder of a large file, the remaining span becomes one region instead. `Minga.Core.Diff.diff_lines_within/3` measures the differing lines and stops at the budget, so the check itself stays bounded even when every line still occurs on both sides. A few distant edits in a large file stay separate regions.
  """
  @spec changes(Document.t(), Document.t()) :: [t()]
  def changes(%Document{} = old_document, %Document{} = new_document) do
    old_content = Document.content(old_document)
    new_content = Document.content(new_document)
    {old_lines, old_offsets} = line_index(old_content)
    {new_lines, new_offsets} = line_index(new_content)
    cursor = Document.cursor(old_document)

    {prefix, old_middle, new_middle} = trim_shared_lines(old_lines, new_lines)

    old_middle
    |> middle_regions(new_middle)
    |> Enum.map(fn {old_start, old_count, new_start, new_count} ->
      replacement(
        elem(old_offsets, prefix + old_start),
        line_range(old_content, old_offsets, prefix + old_start, old_count),
        line_range(new_content, new_offsets, prefix + new_start, new_count),
        cursor
      )
    end)
  end

  # Upper bound on (remaining lines) x (differing lines) for one line diff, about a tenth of a
  # second of `List.myers_difference/2` work.
  @diff_budget 1_000_000

  # Regions as `{old_start, old_count, new_start, new_count}` line ranges within the middles.
  @spec middle_regions([binary()], [binary()]) :: [
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
        ]
  defp middle_regions([], []), do: []

  defp middle_regions(old_middle, new_middle) do
    old_count = length(old_middle)
    new_count = length(new_middle)

    max_edits = div(@diff_budget, old_count + new_count)

    # The line-count bound rejects a rewrite in linear time; a reorder passes it and reaches the capped search.
    diff =
      if unmatched_lines(old_middle, new_middle) > max_edits,
        do: :over_budget,
        else: Diff.diff_lines_within(old_middle, new_middle, max_edits)

    case diff do
      {:ok, hunks} -> Enum.map(hunks, &{&1.old_start, &1.old_count, &1.start_line, &1.count})
      :over_budget -> [{0, old_count, 0, new_count}]
    end
  end

  # Drops the leading and trailing lines both sides share, returning how many leading lines were
  # dropped and the two remaining middles.
  @spec trim_shared_lines([binary()], [binary()]) :: {non_neg_integer(), [binary()], [binary()]}
  defp trim_shared_lines(old_lines, new_lines) do
    {prefix, old_rest, new_rest} = drop_shared(old_lines, new_lines, 0)

    {_suffix, old_middle, new_middle} =
      drop_shared(Enum.reverse(old_rest), Enum.reverse(new_rest), 0)

    {prefix, Enum.reverse(old_middle), Enum.reverse(new_middle)}
  end

  @spec drop_shared([binary()], [binary()], non_neg_integer()) ::
          {non_neg_integer(), [binary()], [binary()]}
  defp drop_shared([line | old_rest], [line | new_rest], count),
    do: drop_shared(old_rest, new_rest, count + 1)

  defp drop_shared(old_lines, new_lines, count), do: {count, old_lines, new_lines}

  # Lines one side holds more often than the other. Every such line is deleted or inserted by any
  # line diff, so the count is a lower bound on the number of differing lines.
  @spec unmatched_lines([binary()], [binary()]) :: non_neg_integer()
  defp unmatched_lines(old_middle, new_middle) do
    counts = Enum.frequencies(old_middle)

    counts =
      Enum.reduce(new_middle, counts, fn line, acc -> Map.update(acc, line, -1, &(&1 - 1)) end)

    Enum.reduce(counts, 0, fn {_line, count}, sum -> sum + abs(count) end)
  end

  # Splits content into lines that keep their newline, as sub-binaries of `content`, and returns
  # the byte offset of every line start followed by the content size, so line `i` spans
  # `elem(offsets, i)` up to `elem(offsets, i + 1)`.
  @spec line_index(binary()) :: {[binary()], tuple()}
  defp line_index(content) do
    size = byte_size(content)
    line_ends = for {position, 1} <- :binary.matches(content, "\n"), do: position + 1

    boundaries =
      case List.last(line_ends, 0) do
        ^size -> [0 | line_ends]
        _last -> [0 | line_ends] ++ [size]
      end

    lines =
      boundaries
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> binary_part(content, from, to - from) end)

    {lines, List.to_tuple(boundaries)}
  end

  @spec line_range(binary(), tuple(), non_neg_integer(), non_neg_integer()) :: binary()
  defp line_range(content, offsets, first_line, line_count) do
    from = elem(offsets, first_line)
    binary_part(content, from, elem(offsets, first_line + line_count) - from)
  end

  @spec changed_fragment(Document.t(), non_neg_integer(), non_neg_integer()) :: byte_fragment()
  defp changed_fragment(document, start_byte, byte_count),
    do: document |> Document.slice_byte_range(start_byte, byte_count) |> own_binary()

  # Each chunk is a sub-binary of one gap half, or at most a chunk-sized copy when it straddles the gap.
  @spec common_prefix_size(Document.t(), Document.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp common_prefix_size(_old, _new, offset, limit) when offset == limit, do: offset

  defp common_prefix_size(old, new, offset, limit) do
    count = min(@affix_chunk_bytes, limit - offset)

    matched =
      :binary.longest_common_prefix([
        Document.slice_byte_range(old, offset, count),
        Document.slice_byte_range(new, offset, count)
      ])

    if matched == count,
      do: common_prefix_size(old, new, offset + count, limit),
      else: offset + matched
  end

  @spec common_suffix_size(Document.t(), Document.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp common_suffix_size(_old, _new, matched, limit) when matched == limit, do: matched

  defp common_suffix_size(old, new, matched, limit) do
    count = min(@affix_chunk_bytes, limit - matched)

    chunk_matched =
      :binary.longest_common_suffix([
        suffix_chunk(old, matched, count),
        suffix_chunk(new, matched, count)
      ])

    if chunk_matched == count,
      do: common_suffix_size(old, new, matched + count, limit),
      else: matched + chunk_matched
  end

  @spec suffix_chunk(Document.t(), non_neg_integer(), non_neg_integer()) :: binary()
  defp suffix_chunk(document, matched, count) do
    end_byte = Document.content_byte_size(document) - matched
    Document.slice_byte_range(document, end_byte - count, count)
  end

  @doc """
  Returns the smallest byte changes a forward patch makes, in document order, as `{start, removed, inserted}`.

  When the old and new text have the same number of lines, each pair of lines is compared on its own; otherwise the whole text is one pair. Each pair loses the bytes both sides share at the start and the end, on code point boundaries, and what remains is compared word by word, so a line that changes two words records two changes and the text between them stays out. The word comparison runs only when the trimmed pair holds at most 512 words in all, which bounds its cost whatever the words are; past that, the trimmed pair is one change. Everything else is linear in the patch's bytes. Offsets are in the document the patch applies to, so applying the changes from the last to the first gives the patch's result.

  `Minga.Buffer.UndoHistory` records changes this precise, so an edit that rewrites whole lines only takes authorship of the bytes it changed.
  """
  @spec precise_changes(t()) :: [{non_neg_integer(), byte_fragment(), byte_fragment()}]
  def precise_changes(%__MODULE__{start_byte: start, old_text: removed, new_text: inserted}) do
    removed_lines = lines_with_newlines(removed)
    inserted_lines = lines_with_newlines(inserted)

    case line_pairs(removed_lines, inserted_lines) do
      [] ->
        precise_pair(start, removed, inserted)

      pairs ->
        pairs
        |> Enum.flat_map_reduce(start, fn {old_line, new_line}, offset ->
          {precise_pair(offset, old_line, new_line), offset + byte_size(old_line)}
        end)
        |> elem(0)
    end
  end

  # Trims a pair, then splits what remains into its changed words.
  @spec precise_pair(non_neg_integer(), binary(), binary()) :: [
          {non_neg_integer(), byte_fragment(), byte_fragment()}
        ]
  defp precise_pair(start, old, new) do
    case trimmed_change(start, old, new) do
      [{at, old_middle, new_middle}] -> word_changes(at, old_middle, new_middle)
      [] -> []
    end
  end

  # A word diff costs at most (words on both sides) squared, so this bound caps it at a few milliseconds whatever the
  # words are, including the same words reordered.
  @max_words 512

  @spec word_changes(non_neg_integer(), binary(), binary()) :: [
          {non_neg_integer(), byte_fragment(), byte_fragment()}
        ]
  defp word_changes(at, old, new) do
    if String.valid?(old) and String.valid?(new),
      do: diff_words(at, old, new, words(old), words(new)),
      else: [{at, old, new}]
  end

  @spec diff_words(non_neg_integer(), String.t(), String.t(), [String.t()], [String.t()]) :: [
          {non_neg_integer(), byte_fragment(), byte_fragment()}
        ]
  defp diff_words(at, old, new, old_words, new_words) do
    if within_word_budget?(old_words, new_words) do
      old_words
      |> List.myers_difference(new_words)
      |> script_changes(at)
      |> Enum.flat_map(fn {change_at, removed, inserted} ->
        trimmed_change(change_at, removed, inserted)
      end)
    else
      [{at, old, new}]
    end
  end

  @spec words(String.t()) :: [String.t()]
  defp words(text), do: ~r/\w+|\s+|[^\w\s]/u |> Regex.scan(text) |> List.flatten()

  @spec within_word_budget?([String.t()], [String.t()]) :: boolean()
  defp within_word_budget?(old_words, new_words),
    do: length(old_words) + length(new_words) <= @max_words

  # Turns an edit script over words into changes located in the old text, in document order.
  @spec script_changes([{:eq | :del | :ins, [String.t()]}], non_neg_integer()) :: [
          {non_neg_integer(), binary(), binary()}
        ]
  defp script_changes(script, at) do
    {changes, _offset, pending} =
      Enum.reduce(script, {[], at, nil}, fn
        {:eq, words}, {changes, offset, pending} ->
          {flush(changes, pending), offset + :erlang.iolist_size(words), nil}

        {:del, words}, {changes, offset, pending} ->
          {start, removed, inserted} = pending || {offset, [], []}
          {changes, offset + :erlang.iolist_size(words), {start, [removed, words], inserted}}

        {:ins, words}, {changes, offset, pending} ->
          {start, removed, inserted} = pending || {offset, [], []}
          {changes, offset, {start, removed, [inserted, words]}}
      end)

    changes |> flush(pending) |> Enum.reverse()
  end

  @spec flush(
          [{non_neg_integer(), binary(), binary()}],
          {non_neg_integer(), iodata(), iodata()} | nil
        ) ::
          [{non_neg_integer(), binary(), binary()}]
  defp flush(changes, nil), do: changes

  defp flush(changes, {start, removed, inserted}),
    do: [{start, :erlang.iolist_to_binary(removed), :erlang.iolist_to_binary(inserted)} | changes]

  # Lines pair one to one only when both sides have the same number of lines, more than one.
  @spec line_pairs([binary()], [binary()]) :: [{binary(), binary()}]
  defp line_pairs([_, _ | _] = removed_lines, inserted_lines) do
    if length(removed_lines) == length(inserted_lines),
      do: Enum.zip(removed_lines, inserted_lines),
      else: []
  end

  defp line_pairs(_removed_lines, _inserted_lines), do: []

  @spec lines_with_newlines(binary()) :: [binary()]
  defp lines_with_newlines(""), do: []

  defp lines_with_newlines(text) do
    {lines, from} =
      text
      |> :binary.matches("\n")
      |> Enum.reduce({[], 0}, fn {position, 1}, {lines, from} ->
        {[binary_part(text, from, position + 1 - from) | lines], position + 1}
      end)

    lines =
      if from < byte_size(text),
        do: [binary_part(text, from, byte_size(text) - from) | lines],
        else: lines

    Enum.reverse(lines)
  end

  # Drops the bytes both sides share at the start and at the end, keeping whole code points.
  @spec trimmed_change(non_neg_integer(), binary(), binary()) :: [
          {non_neg_integer(), byte_fragment(), byte_fragment()}
        ]
  defp trimmed_change(_start, same, same), do: []

  defp trimmed_change(start, old, new) do
    prefix = shared_prefix(old, new, :binary.longest_common_prefix([old, new]))
    old_rest = binary_part(old, prefix, byte_size(old) - prefix)
    new_rest = binary_part(new, prefix, byte_size(new) - prefix)

    suffix =
      shared_suffix(old_rest, new_rest, :binary.longest_common_suffix([old_rest, new_rest]))

    [
      {start + prefix, binary_part(old_rest, 0, byte_size(old_rest) - suffix),
       binary_part(new_rest, 0, byte_size(new_rest) - suffix)}
    ]
  end

  @spec shared_prefix(binary(), binary(), non_neg_integer()) :: non_neg_integer()
  defp shared_prefix(old, new, length) do
    if length == 0 or (code_point_start?(old, length) and code_point_start?(new, length)),
      do: length,
      else: shared_prefix(old, new, length - 1)
  end

  @spec shared_suffix(binary(), binary(), non_neg_integer()) :: non_neg_integer()
  defp shared_suffix(old, new, length) do
    if length == 0 or
         (code_point_start?(old, byte_size(old) - length) and
            code_point_start?(new, byte_size(new) - length)),
       do: length,
       else: shared_suffix(old, new, length - 1)
  end

  @spec code_point_start?(binary(), non_neg_integer()) :: boolean()
  defp code_point_start?(text, position) do
    position >= byte_size(text) or Bitwise.band(:binary.at(text, position), 0xC0) != 0x80
  end

  @doc "Returns the cursor the patch restores when applied."
  @spec cursor(t()) :: Document.position()
  def cursor(%__MODULE__{cursor: cursor}), do: cursor

  @doc "Returns the inverse patch for the current document state."
  @spec invert(t(), Document.t()) :: t()
  def invert(%__MODULE__{} = patch, %Document{} = current_document),
    do: inverse(patch, Document.cursor(current_document))

  @spec inverse(t(), Document.position()) :: t()
  defp inverse(patch, cursor) do
    %__MODULE__{
      start_byte: patch.start_byte,
      old_text: patch.new_text,
      new_text: patch.old_text,
      cursor: cursor
    }
  end

  @typedoc """
  Why a patch does not apply to a document.

  `:patch_mismatch` means the document does not hold the patch's `new_text` at its start byte, `:invalid_range` means the range is outside the content, and `:invalid_utf8` means the result would not be valid UTF-8.
  """
  @type apply_error :: :patch_mismatch | :invalid_range | :invalid_utf8

  @doc """
  Applies the patch to a document, returning the previous document state for undo or the next state for redo.

  The document must hold the patch's replaced bytes at its start byte. A patch that does not fit returns an error instead of raising or restoring the wrong text, so a damaged history cannot crash or corrupt the buffer that replays it.
  """
  @spec apply(t(), Document.t()) :: {:ok, Document.t()} | {:error, apply_error()}
  def apply(%__MODULE__{} = patch, %Document{} = document) do
    removed = byte_size(patch.new_text)

    if fits?(document, patch.start_byte, patch.new_text) do
      Document.splice_byte_range(
        document,
        patch.start_byte,
        removed,
        patch.old_text,
        patch.cursor
      )
    else
      {:error, :patch_mismatch}
    end
  end

  @doc """
  Applies `patches` in order and returns the final document with the inverse of every patch, the inverse of the last applied patch first.

  The content, the final cursor, and every error equal those of calling `apply/2` once per patch and `invert/2` before each call. A patch that does not fit returns its error, and no partial result escapes.

  Repeated `apply/2` calls rebuild the whole document once per patch. Instead, this function takes the longest leading run of patches whose ranges it can locate in the document the run starts from, and assembles that run in one pass. The patches of one batch edit form such a run in both directions: a later patch in the run either ends at or before the start of the patch applied before it, or starts at or after the end of the text that patch inserted. Each patch in the run must also fit, start and end on code point boundaries of that document, and insert valid UTF-8, and the document must be valid UTF-8. Every intermediate document is then valid UTF-8, so the sequential calls could not fail. A patch outside a run is applied on its own with `apply/2`, and the next run starts after it. When the document is not valid UTF-8, every patch of the run is applied with `apply/2` instead, because a patch may repair the content. A single patch takes `apply/2` directly.

  The cursor of an inverse patch is the cursor to restore when that inverse is applied. Inside a run, that is the cursor recorded on the previously applied patch, which `apply/2` would also have placed. Applying a patch always places its cursor in the resulting document, so the stored value only differs from `invert/2` when a recorded cursor was not already a caret position, and the restored cursor is the same.
  """
  @spec apply_all(nonempty_list(t()), Document.t()) ::
          {:ok, Document.t(), nonempty_list(t())} | {:error, apply_error()}
  def apply_all([_ | _] = patches, %Document{} = document), do: apply_all(patches, document, [])

  @spec apply_all([t()], Document.t(), [t()]) ::
          {:ok, Document.t(), [t()]} | {:error, apply_error()}
  defp apply_all([], document, inverses), do: {:ok, document, inverses}

  defp apply_all([_patch] = patches, document, inverses),
    do: apply_each(patches, [], document, inverses)

  defp apply_all([patch | rest] = patches, document, inverses) do
    case take_run(patches, document) do
      {[_, _ | _] = steps, applied, remaining} ->
        text = Document.content(document)

        # A document that is not valid UTF-8 can still accept the run one patch at a time. The
        # whole located run takes that path, so the run is not located again from each patch.
        if Unicode.valid_utf8?(text) do
          next_document = assemble(steps, text, applied)
          apply_all(remaining, next_document, run_inverses(applied, document) ++ inverses)
        else
          apply_each(Enum.reverse(applied), remaining, document, inverses)
        end

      _no_run ->
        apply_each([patch], rest, document, inverses)
    end
  end

  # Applies `patches` one `apply/2` call at a time, then continues with `rest`.
  @spec apply_each([t()], [t()], Document.t(), [t()]) ::
          {:ok, Document.t(), [t()]} | {:error, apply_error()}
  defp apply_each([], rest, document, inverses), do: apply_all(rest, document, inverses)

  defp apply_each([patch | patches], rest, document, inverses) do
    with {:ok, next_document} <- __MODULE__.apply(patch, document) do
      apply_each(patches, rest, next_document, [invert(patch, document) | inverses])
    end
  end

  # A patch located in the document its run starts from: the byte range it replaces there, and
  # the text it inserts.
  @typep step :: {start :: non_neg_integer(), stop :: non_neg_integer(), byte_fragment()}
  @typep direction :: :descending | :ascending | nil

  # Returns the run's steps in ascending document order, its patches with the last applied first,
  # and the patches after the run.
  @spec take_run(nonempty_list(t()), Document.t()) :: {[step()], [t()], [t()]}
  defp take_run([first | rest] = patches, document) do
    case locate(first, first.start_byte, document) do
      {:ok, step} -> extend_run(rest, document, {nil, first, size_change(first)}, [step], [first])
      :stop -> {[], [], patches}
    end
  end

  # `shift` is how far the run has moved every byte after its last applied patch, so a patch
  # after that one sits `shift` bytes later than in the run's starting document.
  @spec extend_run(
          [t()],
          Document.t(),
          {direction(), t(), integer()},
          nonempty_list(step()),
          nonempty_list(t())
        ) :: {[step()], [t()], [t()]}
  defp extend_run(
         [patch | rest] = patches,
         document,
         {direction, previous, shift},
         steps,
         applied
       ) do
    with {:ok, next_direction, start} <- follow(patch, previous, direction, shift),
         {:ok, step} <- locate(patch, start, document) do
      state = {next_direction, patch, shift + size_change(patch)}
      extend_run(rest, document, state, [step | steps], [patch | applied])
    else
      :stop -> finish_run(direction, steps, applied, patches)
    end
  end

  defp extend_run([], _document, {direction, _previous, _shift}, steps, applied),
    do: finish_run(direction, steps, applied, [])

  # Descending runs accumulate their steps lowest first already.
  @spec finish_run(direction(), [step()], [t()], [t()]) :: {[step()], [t()], [t()]}
  defp finish_run(:ascending, steps, applied, rest), do: {Enum.reverse(steps), applied, rest}
  defp finish_run(_direction, steps, applied, rest), do: {steps, applied, rest}

  # Returns where `patch` starts in the run's starting document when every byte it replaces is
  # still original text there. Equal boundaries keep application order: a later descending patch
  # inserts before the earlier one's text, and a later ascending patch after it.
  @spec follow(t(), t(), direction(), integer()) ::
          {:ok, :descending | :ascending, non_neg_integer()} | :stop
  defp follow(patch, previous, direction, shift) do
    cond do
      direction != :ascending and
          patch.start_byte + byte_size(patch.new_text) <= previous.start_byte ->
        {:ok, :descending, patch.start_byte}

      direction != :descending and
          patch.start_byte >= previous.start_byte + byte_size(previous.old_text) ->
        {:ok, :ascending, patch.start_byte - shift}

      true ->
        :stop
    end
  end

  @spec locate(t(), non_neg_integer(), Document.t()) :: {:ok, step()} | :stop
  defp locate(patch, start, document) do
    stop = start + byte_size(patch.new_text)

    if fits?(document, start, patch.new_text) and code_point_boundary?(document, start) and
         code_point_boundary?(document, stop) and Unicode.valid_utf8?(patch.old_text),
       do: {:ok, {start, stop, patch.old_text}},
       else: :stop
  end

  @spec code_point_boundary?(Document.t(), non_neg_integer()) :: boolean()
  defp code_point_boundary?(document, point) do
    point >= Document.content_byte_size(document) or
      Bitwise.band(Document.byte_at(document, point), 0xC0) != 0x80
  end

  @spec size_change(t()) :: integer()
  defp size_change(patch), do: byte_size(patch.old_text) - byte_size(patch.new_text)

  # The cursor lands where `apply/2` would place the last applied patch's cursor.
  @spec assemble(nonempty_list(step()), String.t(), nonempty_list(t())) :: Document.t()
  defp assemble([{lowest_start, _stop, _text} | _higher] = steps, text, [last | _earlier]) do
    {chunks, point} =
      Enum.reduce(steps, {[binary_part(text, 0, lowest_start)], lowest_start}, fn
        {start, stop, inserted}, {chunks, point} ->
          {[inserted, binary_part(text, point, start - point) | chunks], stop}
      end)

    [binary_part(text, point, byte_size(text) - point) | chunks]
    |> Enum.reverse()
    |> :erlang.iolist_to_binary()
    |> Document.new()
    |> Document.move_to(last.cursor)
  end

  # Each inverse restores the cursor of the document before its patch: the run's starting cursor
  # for the first patch, otherwise the cursor recorded on the patch applied before it.
  @spec run_inverses(nonempty_list(t()), Document.t()) :: nonempty_list(t())
  defp run_inverses([first], document), do: [inverse(first, Document.cursor(document))]

  defp run_inverses([patch, previous | _] = applied, document),
    do: [inverse(patch, previous.cursor) | run_inverses(tl(applied), document)]

  @spec fits?(Document.t(), non_neg_integer(), byte_fragment()) :: boolean()
  defp fits?(document, start_byte, expected) do
    start_byte + byte_size(expected) <= Document.content_byte_size(document) and
      Document.slice_byte_range(document, start_byte, byte_size(expected)) == expected
  end

  @spec own_binary(binary()) :: binary()
  defp own_binary(binary), do: :binary.copy(binary)
end
