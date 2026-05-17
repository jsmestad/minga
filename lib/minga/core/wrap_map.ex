defmodule Minga.Core.WrapMap do
  @moduledoc """
  Computes visual line breaks for soft word-wrapping.

  Given a list of logical lines and a content width, produces a wrap map
  that tells the renderer how to split each logical line across multiple
  screen rows. All computation is pure and stateless; the wrap map is
  recomputed per frame for visible lines only (typically 30-50 lines),
  so performance is not a concern.

  ## Design

  - **Break at word boundaries.** Scans graphemes left to right, tracking
    display width. When the next grapheme would exceed the content width,
    breaks at the last whitespace position. If no whitespace exists in
    the line (a single long token), breaks at the content width exactly.
  - **Breakindent.** Continuation rows preserve the logical line's leading
    whitespace, keeping indented code visually coherent.
  - **No buffer mutations.** Wrapping is a rendering concern. The buffer
    stores logical lines unchanged.
  """

  alias Minga.Core.WidthOracle
  alias Minga.Core.WidthOracle.Monospace

  @typedoc """
  A single visual row within a wrapped logical line.

  - `text` — the display text for this visual row, including any breakindent prefix
  - `source_text` — the slice of the logical line for this visual row, excluding artificial indent
  - `byte_offset` — byte offset from the start of the logical line
  - `indent_width` — artificial display columns prefixed before `source_text`
  """
  @type visual_row :: %{
          required(:text) => String.t(),
          required(:byte_offset) => non_neg_integer(),
          optional(:source_text) => String.t(),
          optional(:indent_width) => non_neg_integer()
        }

  @typedoc """
  Wrap entry for one logical line: a list of visual rows it expands to.
  A non-wrapping line produces a single-element list.
  """
  @type wrap_entry :: [visual_row()]

  @typedoc "A wrap map: one entry per logical line in the visible range."
  @type t :: [wrap_entry()]

  @typep wrap_config :: %{
           required(:continuation_width) => pos_integer(),
           required(:indent) => String.t(),
           required(:indent_width) => non_neg_integer(),
           required(:linebreak) => boolean(),
           required(:oracle) => WidthOracle.t()
         }

  @doc """
  Computes the wrap map for a list of logical lines.

  `content_width` is the number of display columns available for text
  (viewport cols minus gutter width). When `breakindent` is true,
  continuation rows are indented to match the logical line's leading
  whitespace.

  Returns a list with one `wrap_entry` per input line. Each entry is a
  list of `visual_row` maps, one per screen row the line occupies.
  """
  @spec compute([String.t()], pos_integer(), keyword()) :: t()
  def compute(lines, content_width, opts \\ []) do
    breakindent = Keyword.get(opts, :breakindent, true)
    linebreak = Keyword.get(opts, :linebreak, true)
    oracle = Keyword.get(opts, :oracle, %Monospace{})
    Enum.map(lines, &wrap_line(&1, content_width, breakindent, linebreak, oracle))
  end

  @doc """
  Returns the total number of visual rows across all entries in a wrap map.
  """
  @spec visual_row_count(t()) :: non_neg_integer()
  def visual_row_count(wrap_map) do
    Enum.reduce(wrap_map, 0, fn entry, acc -> acc + length(entry) end)
  end

  @doc """
  Converts a logical line index to the visual row offset from the start
  of the wrap map. Returns the screen row where the logical line begins.
  """
  @spec logical_to_visual(t(), non_neg_integer()) :: non_neg_integer()
  def logical_to_visual(wrap_map, logical_line) do
    wrap_map
    |> Enum.take(logical_line)
    |> Enum.reduce(0, fn entry, acc -> acc + length(entry) end)
  end

  # ── Line wrapping ──────────────────────────────────────────────────────────

  @spec wrap_line(String.t(), pos_integer(), boolean(), boolean(), WidthOracle.t()) ::
          wrap_entry()
  defp wrap_line("", _width, _breakindent, _linebreak, _oracle) do
    [%{text: "", byte_offset: 0}]
  end

  defp wrap_line(text, width, breakindent, linebreak, oracle) when width > 0 do
    indent_width = if breakindent, do: leading_whitespace_width(text, oracle), else: 0
    # First row gets the full width; continuation rows lose indent columns.
    # Ensure continuation width is at least 4 to avoid infinite loops on
    # deeply indented lines wider than the viewport.
    continuation_width = max(width - indent_width, 4)
    indent_prefix = if indent_width > 0, do: String.duplicate(" ", indent_width), else: ""

    graphemes = String.graphemes(text)

    config = %{
      continuation_width: continuation_width,
      indent: indent_prefix,
      indent_width: indent_width,
      linebreak: linebreak,
      oracle: oracle
    }

    do_wrap(graphemes, width, 0, [], config)
  end

  @spec do_wrap([String.t()], pos_integer(), non_neg_integer(), wrap_entry(), wrap_config()) ::
          wrap_entry()
  defp do_wrap([], _row_width, _byte_off, acc, _config) do
    Enum.reverse(acc)
  end

  defp do_wrap(graphemes, row_width, byte_off, acc, config) do
    {source_text, rest, bytes_consumed} =
      take_row(graphemes, row_width, config.linebreak, config.oracle)

    entry = visual_row(source_text, byte_off, config.indent, config.indent_width)
    next_byte_off = byte_off + bytes_consumed

    case rest do
      [] ->
        Enum.reverse([entry | acc])

      _ ->
        do_wrap(rest, config.continuation_width, next_byte_off, [entry | acc], config)
    end
  end

  @spec visual_row(String.t(), non_neg_integer(), String.t(), non_neg_integer()) :: visual_row()
  defp visual_row(source_text, 0, _indent, _indent_width) do
    %{text: source_text, source_text: source_text, byte_offset: 0, indent_width: 0}
  end

  defp visual_row(source_text, byte_off, "", _indent_width) do
    %{text: source_text, source_text: source_text, byte_offset: byte_off, indent_width: 0}
  end

  defp visual_row(source_text, byte_off, indent, indent_width) do
    %{
      text: indent <> source_text,
      source_text: source_text,
      byte_offset: byte_off,
      indent_width: indent_width
    }
  end

  # Takes graphemes for one visual row, breaking at word boundaries.
  # Returns {row_text, remaining_graphemes, bytes_consumed}.
  @spec take_row([String.t()], pos_integer(), boolean(), WidthOracle.t()) ::
          {String.t(), [String.t()], non_neg_integer()}
  defp take_row(graphemes, max_width, linebreak, oracle) do
    {taken, rest} = scan_row(graphemes, max_width, oracle, 0, [])

    case rest do
      [] ->
        bytes = taken |> Enum.map(&byte_size/1) |> Enum.sum()
        {Enum.join(taken), [], bytes}

      _ when linebreak ->
        break_at_word(taken, rest)

      _ ->
        bytes = taken |> Enum.map(&byte_size/1) |> Enum.sum()
        {Enum.join(taken), rest, bytes}
    end
  end

  # Scans graphemes until the next one would exceed max_width.
  @spec scan_row([String.t()], pos_integer(), WidthOracle.t(), non_neg_integer(), [String.t()]) ::
          {[String.t()], [String.t()]}
  defp scan_row([], _max, _oracle, _col, acc), do: {Enum.reverse(acc), []}

  defp scan_row([g | rest] = remaining, max, oracle, col, acc) do
    w = WidthOracle.grapheme_width(oracle, g)

    if col + w > max do
      finish_overflow_row(g, rest, remaining, acc)
    else
      scan_row(rest, max, oracle, col + w, [g | acc])
    end
  end

  @spec finish_overflow_row(String.t(), [String.t()], [String.t()], [String.t()]) ::
          {[String.t()], [String.t()]}
  defp finish_overflow_row(g, rest, _remaining, []) do
    {[g], rest}
  end

  defp finish_overflow_row(_g, _rest, remaining, acc) do
    {Enum.reverse(acc), remaining}
  end

  # Finds the last whitespace in `taken` and breaks there.
  # Returns {row_text, remaining_graphemes, bytes_consumed}.
  @spec break_at_word([String.t()], [String.t()]) ::
          {String.t(), [String.t()], non_neg_integer()}
  defp break_at_word(taken, overflow_rest) do
    last_space =
      taken
      |> Enum.with_index()
      |> Enum.filter(fn {g, _i} -> whitespace?(g) end)
      |> List.last()

    case last_space do
      {_g, idx} when idx > 0 ->
        {before, after_space} = Enum.split(taken, idx + 1)
        bytes = before |> Enum.map(&byte_size/1) |> Enum.sum()
        remaining = strip_leading_spaces(after_space) ++ overflow_rest
        {Enum.join(before), remaining, bytes}

      _ ->
        # No word boundary: hard break
        bytes = taken |> Enum.map(&byte_size/1) |> Enum.sum()
        {Enum.join(taken), overflow_rest, bytes}
    end
  end

  @spec strip_leading_spaces([String.t()]) :: [String.t()]
  defp strip_leading_spaces([" " | rest]), do: strip_leading_spaces(rest)
  defp strip_leading_spaces(other), do: other

  @spec whitespace?(String.t()) :: boolean()
  defp whitespace?(" "), do: true
  defp whitespace?("\t"), do: true
  defp whitespace?(_), do: false

  @spec leading_whitespace_width(String.t(), WidthOracle.t()) :: non_neg_integer()
  defp leading_whitespace_width(text, oracle) do
    text
    |> String.graphemes()
    |> Enum.reduce_while(0, fn g, acc ->
      case g do
        " " -> {:cont, acc + WidthOracle.grapheme_width(oracle, " ")}
        "\t" -> {:cont, acc + WidthOracle.grapheme_width(oracle, "\t")}
        _ -> {:halt, acc}
      end
    end)
  end
end
