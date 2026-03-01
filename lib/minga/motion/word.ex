defmodule Minga.Motion.Word do
  @moduledoc """
  Word and WORD cursor motion functions.

  Implements Vim's `w`/`b`/`e` (word-boundary) and `W`/`B`/`E`
  (whitespace-only boundary) motions.
  """

  alias Minga.Buffer.GapBuffer
  alias Minga.Motion.Helpers

  @typedoc "A zero-indexed {line, col} cursor position."
  @type position :: GapBuffer.position()

  # ── word motions (w / b / e) ──────────────────────────────────────────────

  @doc """
  Move forward to the start of the next word (Vim's `w`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello world")
      iex> Minga.Motion.Word.word_forward(buf, {0, 0})
      {0, 6}
  """
  @spec word_forward(GapBuffer.t(), position()) :: position()
  def word_forward(%GapBuffer{} = buf, {line, col} = pos) do
    text = GapBuffer.content(buf)
    graphemes = text |> String.graphemes() |> List.to_tuple()
    total = tuple_size(graphemes)

    if total == 0 do
      pos
    else
      all_lines = String.split(text, "\n")
      offset = Helpers.offset_for(all_lines, line, col)
      new_offset = do_word_forward(graphemes, offset, total - 1)
      GapBuffer.offset_to_position(buf, new_offset)
    end
  end

  @doc """
  Move backward to the start of the previous word (Vim's `b`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello world")
      iex> Minga.Motion.Word.word_backward(buf, {0, 6})
      {0, 0}
  """
  @spec word_backward(GapBuffer.t(), position()) :: position()
  def word_backward(%GapBuffer{} = buf, {line, col} = pos) do
    text = GapBuffer.content(buf)
    graphemes = text |> String.graphemes() |> List.to_tuple()

    if tuple_size(graphemes) == 0 do
      pos
    else
      all_lines = String.split(text, "\n")
      offset = Helpers.offset_for(all_lines, line, col)

      if offset == 0 do
        {0, 0}
      else
        new_offset = do_word_backward(graphemes, offset - 1)
        GapBuffer.offset_to_position(buf, new_offset)
      end
    end
  end

  @doc """
  Move to the end of the current or next word (Vim's `e`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("hello world")
      iex> Minga.Motion.Word.word_end(buf, {0, 0})
      {0, 4}
  """
  @spec word_end(GapBuffer.t(), position()) :: position()
  def word_end(%GapBuffer{} = buf, {line, col} = pos) do
    text = GapBuffer.content(buf)
    graphemes = text |> String.graphemes() |> List.to_tuple()
    total = tuple_size(graphemes)

    if total == 0 do
      pos
    else
      all_lines = String.split(text, "\n")
      offset = Helpers.offset_for(all_lines, line, col)
      new_offset = do_word_end(graphemes, offset, total - 1)
      GapBuffer.offset_to_position(buf, new_offset)
    end
  end

  # ── WORD motions (W / B / E) ──────────────────────────────────────────────

  @doc """
  Move forward to the start of the next WORD (Vim's `W`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("foo.bar baz")
      iex> Minga.Motion.Word.word_forward_big(buf, {0, 0})
      {0, 8}
  """
  @spec word_forward_big(GapBuffer.t(), position()) :: position()
  def word_forward_big(%GapBuffer{} = buf, {line, col} = pos) do
    text = GapBuffer.content(buf)
    graphemes = text |> String.graphemes() |> List.to_tuple()
    total = tuple_size(graphemes)

    if total == 0 do
      pos
    else
      all_lines = String.split(text, "\n")
      offset = Helpers.offset_for(all_lines, line, col)
      new_offset = do_word_forward_big(graphemes, offset, total - 1)
      GapBuffer.offset_to_position(buf, new_offset)
    end
  end

  @doc """
  Move backward to the start of the previous WORD (Vim's `B`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("foo.bar baz")
      iex> Minga.Motion.Word.word_backward_big(buf, {0, 8})
      {0, 0}
  """
  @spec word_backward_big(GapBuffer.t(), position()) :: position()
  def word_backward_big(%GapBuffer{} = buf, {line, col} = pos) do
    text = GapBuffer.content(buf)
    graphemes = text |> String.graphemes() |> List.to_tuple()

    if tuple_size(graphemes) == 0 do
      pos
    else
      all_lines = String.split(text, "\n")
      offset = Helpers.offset_for(all_lines, line, col)

      if offset == 0 do
        {0, 0}
      else
        new_offset = do_word_backward_big(graphemes, offset - 1)
        GapBuffer.offset_to_position(buf, new_offset)
      end
    end
  end

  @doc """
  Move to the end of the current or next WORD (Vim's `E`).

  ## Examples

      iex> buf = Minga.Buffer.GapBuffer.new("foo.bar baz")
      iex> Minga.Motion.Word.word_end_big(buf, {0, 0})
      {0, 6}
  """
  @spec word_end_big(GapBuffer.t(), position()) :: position()
  def word_end_big(%GapBuffer{} = buf, {line, col} = pos) do
    text = GapBuffer.content(buf)
    graphemes = text |> String.graphemes() |> List.to_tuple()
    total = tuple_size(graphemes)

    if total == 0 do
      pos
    else
      all_lines = String.split(text, "\n")
      offset = Helpers.offset_for(all_lines, line, col)
      new_offset = do_word_end_big(graphemes, offset, total - 1)
      GapBuffer.offset_to_position(buf, new_offset)
    end
  end

  # ── Private: `b` motion ───────────────────────────────────────────────────

  @spec do_word_backward(tuple(), non_neg_integer()) :: non_neg_integer()
  defp do_word_backward(graphemes, offset) do
    non_ws = Helpers.backward_find(graphemes, offset, fn g -> not Helpers.whitespace?(g) end)

    if non_ws < 0 do
      0
    else
      Helpers.find_run_start_at(graphemes, non_ws)
    end
  end

  # ── Private: `w` motion ───────────────────────────────────────────────────

  @spec do_word_forward(tuple(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp do_word_forward(_graphemes, offset, max) when offset >= max, do: max

  defp do_word_forward(graphemes, offset, max) do
    current = elem(graphemes, offset)
    advance_word_forward(graphemes, offset, max, Helpers.classify_char(current))
  end

  @spec advance_word_forward(
          tuple(),
          non_neg_integer(),
          non_neg_integer(),
          :word | :whitespace | :punctuation
        ) :: non_neg_integer()
  defp advance_word_forward(graphemes, offset, max, :whitespace) do
    Helpers.skip_while(graphemes, offset + 1, max, &Helpers.whitespace?/1)
  end

  defp advance_word_forward(graphemes, offset, max, :word) do
    after_word = Helpers.skip_while(graphemes, offset + 1, max, &Helpers.word_char?/1)
    Helpers.skip_while(graphemes, after_word, max, &Helpers.whitespace?/1)
  end

  defp advance_word_forward(graphemes, offset, max, :punctuation) do
    after_punct =
      Helpers.skip_while(graphemes, offset + 1, max, fn g ->
        not Helpers.word_char?(g) and not Helpers.whitespace?(g)
      end)

    Helpers.skip_while(graphemes, after_punct, max, &Helpers.whitespace?/1)
  end

  # ── Private: `e` motion ───────────────────────────────────────────────────

  @spec do_word_end(tuple(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp do_word_end(_graphemes, offset, max) when offset >= max, do: max

  defp do_word_end(graphemes, offset, max) do
    start = min(offset + 1, max)
    current = elem(graphemes, start)

    run_start =
      if Helpers.whitespace?(current),
        do: Helpers.skip_while(graphemes, start, max, &Helpers.whitespace?/1),
        else: start

    run_char = elem(graphemes, run_start)
    advance_word_end(graphemes, run_start, max, Helpers.classify_char(run_char))
  end

  @spec advance_word_end(
          tuple(),
          non_neg_integer(),
          non_neg_integer(),
          :word | :whitespace | :punctuation
        ) :: non_neg_integer()
  defp advance_word_end(graphemes, run_start, max, :word) do
    Helpers.last_in_run(graphemes, run_start, max, &Helpers.word_char?/1)
  end

  defp advance_word_end(graphemes, run_start, max, :punctuation) do
    Helpers.last_in_run(graphemes, run_start, max, fn g ->
      not Helpers.word_char?(g) and not Helpers.whitespace?(g)
    end)
  end

  defp advance_word_end(_graphemes, run_start, _max, :whitespace), do: run_start

  # ── Private: `B` motion ───────────────────────────────────────────────────

  @spec do_word_backward_big(tuple(), non_neg_integer()) :: non_neg_integer()
  defp do_word_backward_big(graphemes, offset) do
    non_ws = Helpers.backward_find(graphemes, offset, fn g -> not Helpers.whitespace?(g) end)

    if non_ws < 0 do
      0
    else
      Helpers.find_run_start(graphemes, non_ws, fn g -> not Helpers.whitespace?(g) end)
    end
  end

  # ── Private: `W` motion ───────────────────────────────────────────────────

  @spec do_word_forward_big(tuple(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_word_forward_big(_graphemes, offset, max) when offset >= max, do: max

  defp do_word_forward_big(graphemes, offset, max) do
    current = elem(graphemes, offset)

    if Helpers.whitespace?(current) do
      Helpers.skip_while(graphemes, offset + 1, max, &Helpers.whitespace?/1)
    else
      after_word =
        Helpers.skip_while(graphemes, offset + 1, max, fn g -> not Helpers.whitespace?(g) end)

      Helpers.skip_while(graphemes, after_word, max, &Helpers.whitespace?/1)
    end
  end

  # ── Private: `E` motion ───────────────────────────────────────────────────

  @spec do_word_end_big(tuple(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp do_word_end_big(_graphemes, offset, max) when offset >= max, do: max

  defp do_word_end_big(graphemes, offset, max) do
    start = min(offset + 1, max)
    current = elem(graphemes, start)

    run_start =
      if Helpers.whitespace?(current),
        do: Helpers.skip_while(graphemes, start, max, &Helpers.whitespace?/1),
        else: start

    Helpers.last_in_run(graphemes, run_start, max, fn g -> not Helpers.whitespace?(g) end)
  end
end
