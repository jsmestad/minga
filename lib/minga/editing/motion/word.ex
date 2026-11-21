defmodule Minga.Editing.Motion.Word do
  @moduledoc """
  Word and WORD cursor motion functions.

  Implements Vim's `w`/`b`/`e` (word-boundary) and `W`/`B`/`E`
  (whitespace-only boundary) motions.

  Motions fetch lines on demand through `Readable.line_at/2` without
  materializing the full document. `w` and `W` scan graphemes only as far
  as the next word start or the end of the document.
  """

  alias Minga.Editing.Motion.Helpers
  alias Minga.Editing.Text.Readable

  @typedoc "A zero-indexed {line, byte_col} cursor position."
  @type position :: {non_neg_integer(), non_neg_integer()}

  @typep forward_policy :: :word | :big_word
  @typep forward_class :: :word | :punctuation | :whitespace
  @typep forward_scan :: {:found, non_neg_integer()} | {:line_end, non_neg_integer()}

  # ── Line-level grapheme helpers ──────────────────────────────────────────

  @spec line_graphemes(String.t()) :: {tuple(), tuple()}
  defp line_graphemes(line_text), do: Helpers.graphemes_with_byte_offsets(line_text)

  @spec byte_col_to_gidx(tuple(), non_neg_integer()) :: non_neg_integer()
  defp byte_col_to_gidx(bos, byte_col), do: Helpers.byte_offset_to_grapheme_index(bos, byte_col)

  @spec gidx_to_byte_col(tuple(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp gidx_to_byte_col(bos, gidx, lbs), do: Helpers.grapheme_index_to_byte_offset(bos, gidx, lbs)

  # Position at a grapheme index within a known line.
  @spec pos_at(non_neg_integer(), tuple(), non_neg_integer(), non_neg_integer()) :: position()
  defp pos_at(line_num, bos, gidx, lbs), do: {line_num, gidx_to_byte_col(bos, gidx, lbs)}

  # Clamp byte_col to valid grapheme index for a line with `total` graphemes.
  @spec clamped_gidx(tuple(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp clamped_gidx(bos, col, total), do: min(byte_col_to_gidx(bos, col), total - 1)

  # ── Scanning primitives (line-local, returns index up to `total`) ────────

  @spec skip_ws(tuple(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp skip_ws(_gs, idx, total) when idx >= total, do: total

  defp skip_ws(gs, idx, total) do
    if Helpers.whitespace?(elem(gs, idx)),
      do: skip_ws(gs, idx + 1, total),
      else: idx
  end

  @spec run_end(tuple(), non_neg_integer(), non_neg_integer(), :word | :punctuation) ::
          non_neg_integer()
  defp run_end(gs, idx, max, :word) do
    next = idx + 1

    if next <= max and Helpers.word_char?(elem(gs, next)),
      do: run_end(gs, next, max, :word),
      else: idx
  end

  defp run_end(gs, idx, max, :punctuation) do
    next = idx + 1

    if next <= max do
      g = elem(gs, next)

      if not Helpers.word_char?(g) and not Helpers.whitespace?(g),
        do: run_end(gs, next, max, :punctuation),
        else: idx
    else
      idx
    end
  end

  @spec backward_non_ws(tuple(), integer()) :: integer()
  defp backward_non_ws(_gs, idx) when idx < 0, do: -1

  defp backward_non_ws(gs, idx) do
    if Helpers.whitespace?(elem(gs, idx)),
      do: backward_non_ws(gs, idx - 1),
      else: idx
  end

  @spec run_start_at(tuple(), non_neg_integer()) :: non_neg_integer()
  defp run_start_at(gs, idx) do
    run_start(gs, idx, Helpers.classify_char(elem(gs, idx)))
  end

  @spec run_start(tuple(), non_neg_integer(), :word | :punctuation | :whitespace) ::
          non_neg_integer()
  defp run_start(gs, idx, :word) do
    if idx > 0 and Helpers.word_char?(elem(gs, idx - 1)),
      do: run_start(gs, idx - 1, :word),
      else: idx
  end

  defp run_start(gs, idx, :punctuation) do
    prev = idx - 1

    if prev >= 0 do
      g = elem(gs, prev)

      if not Helpers.word_char?(g) and not Helpers.whitespace?(g),
        do: run_start(gs, prev, :punctuation),
        else: idx
    else
      idx
    end
  end

  defp run_start(_gs, idx, :whitespace), do: idx

  @spec big_run_start(tuple(), non_neg_integer()) :: non_neg_integer()
  defp big_run_start(gs, idx) do
    if idx > 0 and not Helpers.whitespace?(elem(gs, idx - 1)),
      do: big_run_start(gs, idx - 1),
      else: idx
  end

  @spec big_run_end(tuple(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp big_run_end(gs, idx, max) do
    next = idx + 1

    if next <= max and not Helpers.whitespace?(elem(gs, next)),
      do: big_run_end(gs, next, max),
      else: idx
  end

  # ── Forward word starts ──────────────────────────────────────────────────

  @spec move_forward(Readable.t(), position(), forward_policy()) :: position()
  defp move_forward(buf, {line, col} = pos, policy) do
    case Readable.line_at(buf, line) do
      nil ->
        pos

      "" ->
        # An empty starting line stays put if there is no following word.
        scan_next_lines(buf, line + 1, nil, 0) || pos

      text ->
        target = min(col, byte_size(text) - 1)

        case scan_from_cursor(text, 0, target, policy) do
          {:found, next_col} -> {line, next_col}
          {:line_end, last_col} -> scan_next_lines(buf, line + 1, line, last_col)
        end
    end
  end

  # Walk from the start so a byte inside a grapheme still uses that whole grapheme.
  @spec scan_from_cursor(String.t(), non_neg_integer(), non_neg_integer(), forward_policy()) ::
          forward_scan()
  defp scan_from_cursor(text, col, target, policy) do
    {grapheme, rest} = String.next_grapheme(text)
    next_col = col + byte_size(grapheme)

    if next_col <= target do
      scan_from_cursor(rest, next_col, target, policy)
    else
      scan_forward_line(rest, next_col, col, policy, forward_class(grapheme, policy))
    end
  end

  @spec scan_forward_line(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          forward_policy(),
          forward_class()
        ) :: forward_scan()
  defp scan_forward_line("", _col, last_col, _policy, _run), do: {:line_end, last_col}

  defp scan_forward_line(text, col, _last_col, policy, run) do
    {grapheme, rest} = String.next_grapheme(text)
    class = forward_class(grapheme, policy)

    if class == run or class == :whitespace do
      scan_forward_line(rest, col + byte_size(grapheme), col, policy, class)
    else
      {:found, col}
    end
  end

  @spec forward_class(String.t(), forward_policy()) :: forward_class()
  defp forward_class(grapheme, :word), do: Helpers.classify_char(grapheme)

  defp forward_class(grapheme, :big_word) do
    if Helpers.whitespace?(grapheme), do: :whitespace, else: :word
  end

  # A nonempty starting line falls back to the last grapheme seen, even whitespace.
  @spec scan_next_lines(
          Readable.t(),
          non_neg_integer(),
          non_neg_integer() | nil,
          non_neg_integer()
        ) :: position() | nil
  defp scan_next_lines(buf, line, last_line, last_col) do
    case Readable.line_at(buf, line) do
      nil when is_nil(last_line) ->
        nil

      nil ->
        {last_line, last_col}

      "" ->
        scan_next_lines(buf, line + 1, last_line, last_col)

      text ->
        case scan_forward_line(text, 0, 0, :big_word, :whitespace) do
          {:found, col} -> {line, col}
          {:line_end, _col} when is_nil(last_line) -> scan_next_lines(buf, line + 1, nil, 0)
          {:line_end, col} -> scan_next_lines(buf, line + 1, line, col)
        end
    end
  end

  # ── Cross-line helpers ───────────────────────────────────────────────────

  @spec find_prev_word_start(Readable.t(), integer()) :: position()
  defp find_prev_word_start(_buf, line_num) when line_num < 0, do: {0, 0}

  defp find_prev_word_start(buf, line_num) do
    case Readable.line_at(buf, line_num) do
      nil -> {0, 0}
      line_text -> last_word_start_on_line(buf, line_num, line_text, &find_prev_word_start/2)
    end
  end

  @spec last_word_start_on_line(
          Readable.t(),
          integer(),
          String.t(),
          (Readable.t(), integer() -> position())
        ) :: position()
  defp last_word_start_on_line(buf, line_num, line_text, fallback_fn) do
    {gs, bos} = line_graphemes(line_text)
    total = tuple_size(gs)
    non_ws = if total > 0, do: backward_non_ws(gs, total - 1), else: -1

    if non_ws < 0 do
      fallback_fn.(buf, line_num - 1)
    else
      pos_at(line_num, bos, run_start_at(gs, non_ws), byte_size(line_text))
    end
  end

  @spec find_prev_big_word_start(Readable.t(), integer()) :: position()
  defp find_prev_big_word_start(_buf, line_num) when line_num < 0, do: {0, 0}

  defp find_prev_big_word_start(buf, line_num) do
    case Readable.line_at(buf, line_num) do
      nil -> {0, 0}
      line_text -> last_big_word_start_on_line(buf, line_num, line_text)
    end
  end

  @spec last_big_word_start_on_line(Readable.t(), integer(), String.t()) :: position()
  defp last_big_word_start_on_line(buf, line_num, line_text) do
    {gs, bos} = line_graphemes(line_text)
    total = tuple_size(gs)
    non_ws = if total > 0, do: backward_non_ws(gs, total - 1), else: -1

    if non_ws < 0 do
      find_prev_big_word_start(buf, line_num - 1)
    else
      pos_at(line_num, bos, big_run_start(gs, non_ws), byte_size(line_text))
    end
  end

  @spec find_word_end_from(Readable.t(), non_neg_integer(), position()) :: position()
  defp find_word_end_from(buf, line_num, fallback) do
    case Readable.line_at(buf, line_num) do
      nil -> fallback
      line_text -> word_end_on_line(buf, line_num, line_text, fallback)
    end
  end

  @spec word_end_on_line(Readable.t(), non_neg_integer(), String.t(), position()) :: position()
  defp word_end_on_line(buf, line_num, line_text, fallback) do
    {gs, bos} = line_graphemes(line_text)
    total = tuple_size(gs)
    first = skip_ws(gs, 0, total)

    if first >= total do
      find_word_end_from(buf, line_num + 1, fallback)
    else
      class = Helpers.classify_char(elem(gs, first))
      pos_at(line_num, bos, run_end(gs, first, total - 1, class), byte_size(line_text))
    end
  end

  @spec find_big_word_end_from(Readable.t(), non_neg_integer(), position()) :: position()
  defp find_big_word_end_from(buf, line_num, fallback) do
    case Readable.line_at(buf, line_num) do
      nil -> fallback
      line_text -> big_word_end_on_line(buf, line_num, line_text, fallback)
    end
  end

  @spec big_word_end_on_line(Readable.t(), non_neg_integer(), String.t(), position()) ::
          position()
  defp big_word_end_on_line(buf, line_num, line_text, fallback) do
    {gs, bos} = line_graphemes(line_text)
    total = tuple_size(gs)
    first = skip_ws(gs, 0, total)

    if first >= total do
      find_big_word_end_from(buf, line_num + 1, fallback)
    else
      pos_at(line_num, bos, big_run_end(gs, first, total - 1), byte_size(line_text))
    end
  end

  # ── Public API ───────────────────────────────────────────────────────────

  # ── word_forward (w) ──────────────────────────────────────────────────────

  @doc """
  Move forward to the start of the next word (Vim's `w`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Editing.Motion.Word.word_forward(buf, {0, 0})
      {0, 6}
  """
  @spec word_forward(Readable.t(), position()) :: position()
  def word_forward(buf, pos), do: move_forward(buf, pos, :word)

  # ── word_backward (b) ─────────────────────────────────────────────────────

  @doc """
  Move backward to the start of the previous word (Vim's `b`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Editing.Motion.Word.word_backward(buf, {0, 6})
      {0, 0}
  """
  @spec word_backward(Readable.t(), position()) :: position()
  def word_backward(_buf, {0, 0}), do: {0, 0}

  def word_backward(buf, {line, col} = pos) do
    case Readable.line_at(buf, line) do
      nil -> pos
      line_text -> do_word_backward(buf, line, col, line_text)
    end
  end

  @spec do_word_backward(Readable.t(), non_neg_integer(), non_neg_integer(), String.t()) ::
          position()
  defp do_word_backward(buf, line, col, line_text) do
    {gs, bos} = line_graphemes(line_text)
    total = tuple_size(gs)
    g_idx = if total > 0, do: clamped_gidx(bos, col, total), else: 0

    if total == 0 or g_idx == 0 do
      find_prev_word_start(buf, line - 1)
    else
      backward_word_on_line(buf, line, gs, bos, g_idx, byte_size(line_text))
    end
  end

  @spec backward_word_on_line(
          Readable.t(),
          non_neg_integer(),
          tuple(),
          tuple(),
          non_neg_integer(),
          non_neg_integer()
        ) :: position()
  defp backward_word_on_line(buf, line, gs, bos, g_idx, lbs) do
    non_ws = backward_non_ws(gs, g_idx - 1)

    if non_ws < 0,
      do: find_prev_word_start(buf, line - 1),
      else: pos_at(line, bos, run_start_at(gs, non_ws), lbs)
  end

  # ── word_end (e) ──────────────────────────────────────────────────────────

  @doc """
  Move to the end of the current or next word (Vim's `e`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("hello world")
      iex> Minga.Editing.Motion.Word.word_end(buf, {0, 0})
      {0, 4}
  """
  @spec word_end(Readable.t(), position()) :: position()
  def word_end(buf, {line, col} = pos) do
    case Readable.line_at(buf, line) do
      nil -> pos
      line_text -> do_word_end(buf, line, col, pos, line_text)
    end
  end

  @spec do_word_end(
          Readable.t(),
          non_neg_integer(),
          non_neg_integer(),
          position(),
          String.t()
        ) :: position()
  defp do_word_end(buf, line, col, pos, line_text) do
    {gs, bos} = line_graphemes(line_text)
    total = tuple_size(gs)

    if total == 0 do
      find_word_end_from(buf, line + 1, pos)
    else
      start = clamped_gidx(bos, col, total) + 1
      find_end_after(buf, line, gs, bos, start, total, pos, byte_size(line_text))
    end
  end

  @spec find_end_after(
          Readable.t(),
          non_neg_integer(),
          tuple(),
          tuple(),
          non_neg_integer(),
          non_neg_integer(),
          position(),
          non_neg_integer()
        ) :: position()
  defp find_end_after(buf, line, _gs, _bos, start, total, pos, _lbs) when start >= total do
    find_word_end_from(buf, line + 1, pos)
  end

  defp find_end_after(buf, line, gs, bos, start, total, pos, lbs) do
    after_ws = skip_ws(gs, start, total)

    if after_ws >= total do
      find_word_end_from(buf, line + 1, pos)
    else
      class = Helpers.classify_char(elem(gs, after_ws))
      pos_at(line, bos, run_end(gs, after_ws, total - 1, class), lbs)
    end
  end

  # ── word_forward_big (W) ──────────────────────────────────────────────────

  @doc """
  Move forward to the start of the next WORD (Vim's `W`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("foo.bar baz")
      iex> Minga.Editing.Motion.Word.word_forward_big(buf, {0, 0})
      {0, 8}
  """
  @spec word_forward_big(Readable.t(), position()) :: position()
  def word_forward_big(buf, pos), do: move_forward(buf, pos, :big_word)

  # ── word_backward_big (B) ─────────────────────────────────────────────────

  @doc """
  Move backward to the start of the previous WORD (Vim's `B`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("foo.bar baz")
      iex> Minga.Editing.Motion.Word.word_backward_big(buf, {0, 8})
      {0, 0}
  """
  @spec word_backward_big(Readable.t(), position()) :: position()
  def word_backward_big(_buf, {0, 0}), do: {0, 0}

  def word_backward_big(buf, {line, col} = pos) do
    case Readable.line_at(buf, line) do
      nil -> pos
      line_text -> do_word_backward_big(buf, line, col, line_text)
    end
  end

  @spec do_word_backward_big(Readable.t(), non_neg_integer(), non_neg_integer(), String.t()) ::
          position()
  defp do_word_backward_big(buf, line, col, line_text) do
    {gs, bos} = line_graphemes(line_text)
    total = tuple_size(gs)
    g_idx = if total > 0, do: clamped_gidx(bos, col, total), else: 0

    if total == 0 or g_idx == 0 do
      find_prev_big_word_start(buf, line - 1)
    else
      backward_big_word_on_line(buf, line, gs, bos, g_idx, byte_size(line_text))
    end
  end

  @spec backward_big_word_on_line(
          Readable.t(),
          non_neg_integer(),
          tuple(),
          tuple(),
          non_neg_integer(),
          non_neg_integer()
        ) :: position()
  defp backward_big_word_on_line(buf, line, gs, bos, g_idx, lbs) do
    non_ws = backward_non_ws(gs, g_idx - 1)

    if non_ws < 0,
      do: find_prev_big_word_start(buf, line - 1),
      else: pos_at(line, bos, big_run_start(gs, non_ws), lbs)
  end

  # ── word_end_big (E) ──────────────────────────────────────────────────────

  @doc """
  Move to the end of the current or next WORD (Vim's `E`).

  ## Examples

      iex> buf = Minga.Buffer.Document.new("foo.bar baz")
      iex> Minga.Editing.Motion.Word.word_end_big(buf, {0, 0})
      {0, 6}
  """
  @spec word_end_big(Readable.t(), position()) :: position()
  def word_end_big(buf, {line, col} = pos) do
    case Readable.line_at(buf, line) do
      nil -> pos
      line_text -> do_word_end_big(buf, line, col, pos, line_text)
    end
  end

  @spec do_word_end_big(
          Readable.t(),
          non_neg_integer(),
          non_neg_integer(),
          position(),
          String.t()
        ) :: position()
  defp do_word_end_big(buf, line, col, pos, line_text) do
    {gs, bos} = line_graphemes(line_text)
    total = tuple_size(gs)

    if total == 0 do
      find_big_word_end_from(buf, line + 1, pos)
    else
      start = clamped_gidx(bos, col, total) + 1
      find_big_end_after(buf, line, gs, bos, start, total, pos, byte_size(line_text))
    end
  end

  @spec find_big_end_after(
          Readable.t(),
          non_neg_integer(),
          tuple(),
          tuple(),
          non_neg_integer(),
          non_neg_integer(),
          position(),
          non_neg_integer()
        ) :: position()
  defp find_big_end_after(buf, line, _gs, _bos, start, total, pos, _lbs) when start >= total do
    find_big_word_end_from(buf, line + 1, pos)
  end

  defp find_big_end_after(buf, line, gs, bos, start, total, pos, lbs) do
    after_ws = skip_ws(gs, start, total)

    if after_ws >= total do
      find_big_word_end_from(buf, line + 1, pos)
    else
      pos_at(line, bos, big_run_end(gs, after_ws, total - 1), lbs)
    end
  end
end
