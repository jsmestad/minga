defmodule Minga.Core.WrapMap do
  @moduledoc """
  Computes visual line breaks for soft word-wrapping.

  Given a list of logical lines and a content width, produces a wrap map
  that tells the renderer how to split each logical line across multiple
  screen rows. All computation is pure and stateless.

  ## Design

  - **Break at word boundaries.** Scans graphemes in the source binary and
    slices each row at its byte boundary. On overflow, breaks after the last
    fitting space or tab other than the first grapheme, or at the width limit
    if there is no eligible break.
  - **Breakindent.** Continuation rows preserve the logical line's leading
    whitespace, keeping indented code visually coherent.
  - **No buffer mutations.** Wrapping is a rendering concern. The buffer
    stores logical lines unchanged.
  """

  alias Minga.Core.WidthOracle
  alias Minga.Core.WidthOracle.Monospace

  @typedoc """
  A single visual row within a wrapped logical line.

  - `text` — the raw slice of the logical line for this visual row
  - `source_text` — the slice of the logical line for this visual row, excluding artificial indent
  - `byte_offset` — byte offset from the start of the logical line
  - `indent_width` — artificial display columns prefixed before `source_text`
  """
  @type visual_row :: %{
          required(:text) => String.t(),
          required(:source_text) => String.t(),
          required(:byte_offset) => non_neg_integer(),
          required(:indent_width) => non_neg_integer()
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
           required(:indent_width) => non_neg_integer(),
           required(:linebreak) => boolean(),
           required(:oracle) => WidthOracle.t(),
           required(:tab_width) => pos_integer()
         }

  @wrap_whitespace [" ", "\t"]

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
    tab_width = Keyword.get(opts, :tab_width, 2)

    Enum.map(lines, &wrap_line(&1, content_width, breakindent, linebreak, oracle, tab_width))
  end

  @doc """
  Returns the zero-based index and row for a byte offset in the wrapped text.

  Rows must be nonempty and ordered by byte offset. An exact continuation
  start selects that continuation, and a byte past the end selects the last row.
  """
  @spec row_at_byte(nonempty_list(visual_row()), non_neg_integer()) ::
          {non_neg_integer(), visual_row()}
  def row_at_byte(rows, byte), do: row_at_byte(rows, byte, 0)

  defp row_at_byte([_ | [%{byte_offset: start} | _] = rest], byte, index) when start <= byte,
    do: row_at_byte(rest, byte, index + 1)

  defp row_at_byte(rows, _byte, index), do: {index, hd(rows)}

  @doc """
  Returns the total number of visual rows across all entries in a wrap map.
  """
  @spec visual_row_count(t()) :: non_neg_integer()
  def visual_row_count(wrap_map) do
    Enum.reduce(wrap_map, 0, fn entry, acc -> acc + Enum.count(entry) end)
  end

  @doc """
  Converts a logical line index to the visual row offset from the start
  of the wrap map. Returns the screen row where the logical line begins.
  """
  @spec logical_to_visual(t(), non_neg_integer()) :: non_neg_integer()
  def logical_to_visual(wrap_map, logical_line) do
    wrap_map
    |> Enum.take(logical_line)
    |> Enum.reduce(0, fn entry, acc -> acc + Enum.count(entry) end)
  end

  # ── Line wrapping ──────────────────────────────────────────────────────────

  @spec wrap_line(String.t(), pos_integer(), boolean(), boolean(), WidthOracle.t(), pos_integer()) ::
          wrap_entry()
  defp wrap_line("", _width, _breakindent, _linebreak, _oracle, _tab_width) do
    [%{text: "", source_text: "", byte_offset: 0, indent_width: 0}]
  end

  defp wrap_line(text, width, breakindent, linebreak, oracle, tab_width) when width > 0 do
    indent_width =
      if breakindent, do: leading_whitespace_width(text, oracle, tab_width), else: 0

    # First row gets the full width; continuation rows lose indent columns.
    # Deep indentation must still leave a positive continuation width.
    continuation_width = max(width - indent_width, 1)

    config = %{
      continuation_width: continuation_width,
      indent_width: indent_width,
      linebreak: linebreak,
      oracle: oracle,
      tab_width: tab_width
    }

    do_wrap(text, width, 0, [], config)
  end

  @spec do_wrap(String.t(), pos_integer(), non_neg_integer(), wrap_entry(), wrap_config()) ::
          wrap_entry()
  defp do_wrap(text, row_width, byte_off, acc, config) do
    start_col = if byte_off == 0, do: 0, else: config.indent_width

    case rest_after_row(text, start_col, start_col + row_width, true, nil, config) do
      "" ->
        Enum.reverse([visual_row(text, byte_off, config.indent_width) | acc])

      rest ->
        bytes_consumed = byte_size(text) - byte_size(rest)
        source_text = binary_part(text, 0, bytes_consumed)
        entry = visual_row(source_text, byte_off, config.indent_width)
        do_wrap(rest, config.continuation_width, byte_off + bytes_consumed, [entry | acc], config)
    end
  end

  @spec visual_row(String.t(), non_neg_integer(), non_neg_integer()) :: visual_row()
  defp visual_row(source_text, 0, _indent_width) do
    %{text: source_text, source_text: source_text, byte_offset: 0, indent_width: 0}
  end

  defp visual_row(source_text, byte_off, indent_width) do
    %{
      text: source_text,
      source_text: source_text,
      byte_offset: byte_off,
      indent_width: indent_width
    }
  end

  @doc "Returns the display text for a visual row, including any breakindent prefix."
  @spec display_text(visual_row() | map()) :: String.t()
  def display_text(vrow) do
    text = Map.get(vrow, :source_text, Map.get(vrow, :text, ""))
    indent_width = Map.get(vrow, :indent_width, 0)

    if indent_width > 0 do
      String.duplicate(" ", indent_width) <> text
    else
      text
    end
  end

  # A saved word break is a suffix at the end of a fitting space or tab.
  # Use it only on overflow, never when the whole suffix fits.
  @spec rest_after_row(
          String.t(),
          non_neg_integer(),
          pos_integer(),
          boolean(),
          String.t() | nil,
          wrap_config()
        ) :: String.t()
  defp rest_after_row("", _col, _max_col, _first?, _last_break, _config), do: ""

  defp rest_after_row(text, col, max_col, first?, last_break, config) do
    {grapheme, rest} = String.next_grapheme(text)
    next_col = col + grapheme_advance(grapheme, config.oracle, col, config.tab_width)

    cond do
      next_col <= max_col ->
        last_break =
          if config.linebreak == true and not first? and grapheme in @wrap_whitespace,
            do: rest,
            else: last_break

        rest_after_row(rest, next_col, max_col, false, last_break, config)

      first? ->
        # An over-wide first grapheme still takes a row.
        rest

      true ->
        last_break || text
    end
  end

  @spec grapheme_advance(String.t(), WidthOracle.t(), non_neg_integer(), pos_integer()) ::
          non_neg_integer()
  defp grapheme_advance("\t", _oracle, col, tab_width), do: tab_stop_width(col, tab_width)

  defp grapheme_advance(grapheme, oracle, _col, _tab_width),
    do: WidthOracle.grapheme_width(oracle, grapheme)

  @spec leading_whitespace_width(String.t(), WidthOracle.t(), pos_integer()) ::
          non_neg_integer()
  defp leading_whitespace_width(text, oracle, tab_width),
    do: leading_whitespace_width(text, oracle, tab_width, 0)

  @spec leading_whitespace_width(String.t(), WidthOracle.t(), pos_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp leading_whitespace_width(text, oracle, tab_width, col) do
    case String.next_grapheme(text) do
      {grapheme, rest} when grapheme in @wrap_whitespace ->
        advance = grapheme_advance(grapheme, oracle, col, tab_width)
        leading_whitespace_width(rest, oracle, tab_width, col + advance)

      _ ->
        col
    end
  end

  @spec tab_stop_width(non_neg_integer(), pos_integer()) :: pos_integer()
  defp tab_stop_width(col, tab_width) do
    tab_width - rem(col, tab_width)
  end
end
