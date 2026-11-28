defmodule MingaEditor.HoverPopup.Terminal do
  @moduledoc "Indexes terminal hover rows by source position and materializes only the visible page."

  alias Minga.Core.WidthOracle
  alias Minga.Core.WidthOracle.Terminal, as: TerminalWidth
  alias MingaAgent.Markdown

  @enforce_keys [:columns, :width, :rows]
  defstruct [:columns, :width, :rows]

  @type position :: {non_neg_integer(), non_neg_integer()}
  @typep style :: Markdown.style() | {:hover_link, pos_integer()}
  @type line :: {[{String.t(), style()}], Markdown.line_type()}
  @typep indexed_run :: {non_neg_integer(), String.t(), style()}
  @typep row_bounds :: {non_neg_integer(), non_neg_integer()}
  @typep row_scan ::
           {start :: non_neg_integer(), cells :: non_neg_integer(),
            space_break :: {non_neg_integer(), non_neg_integer()} | nil,
            reverse :: [row_bounds()]}
  @type t :: %__MODULE__{columns: pos_integer(), width: pos_integer(), rows: tuple()}

  @oracle %TerminalWidth{}

  @doc "Builds an index for the current document variant and terminal width."
  @spec prepare(t() | nil, [Markdown.parsed_line()], pos_integer(), non_neg_integer()) ::
          t() | nil
  def prepare(_previous, _lines, cols, _link_count) when cols < 6, do: nil

  def prepare(previous, lines, cols, link_count) do
    columns = min(cols, 72)

    case previous do
      %__MODULE__{columns: ^columns} -> previous
      _ -> index(lines, columns, link_count + 1)
    end
  end

  @doc "Returns at most one page of styled rows anchored to the source document."
  @spec page(t(), position(), pos_integer()) :: [line()]
  def page(%__MODULE__{rows: rows}, position, height) do
    {first, size} = viewport(rows, position, height)
    last = min(first + size, tuple_size(rows))

    for index <- first..(last - 1)//1 do
      {{_line, start}, stop, kind, runs} = elem(rows, index)
      {slice(runs, start, stop), kind}
    end
  end

  @doc "Resolves terminal scrolling without copying or restyling the document."
  @spec scroll(t(), position(), pos_integer(), -1 | 1) :: position() | nil
  def scroll(%__MODULE__{rows: {}}, _position, _height, _direction), do: nil

  def scroll(%__MODULE__{rows: rows}, position, height, direction) do
    {first, size} = viewport(rows, position, height)
    index = clamp(first + direction * min(3, size), tuple_size(rows), size)
    elem(elem(rows, index), 0)
  end

  @spec index([Markdown.parsed_line()], pos_integer(), pos_integer()) :: t()
  defp index(lines, columns, last_link) do
    width = measure(lines, max(min(columns, 30) - 4, 2), columns - 4)

    {rows, _next_link} =
      Enum.flat_map_reduce(lines, {0, 2}, fn {segments, kind}, {line, next_link} ->
        {runs, next_link} = index_runs(segments, next_link, last_link)
        indexed = List.to_tuple(runs)

        rows =
          for {start, stop} <- wrap_runs(runs, width) do
            {{line, start}, stop, kind, indexed}
          end

        {rows, {line + 1, next_link}}
      end)

    %__MODULE__{columns: columns, width: width + 4, rows: List.to_tuple(rows)}
  end

  @spec measure([Markdown.parsed_line()], pos_integer(), pos_integer()) :: pos_integer()
  defp measure(_lines, limit, limit), do: limit

  defp measure(lines, minimum, limit) do
    Enum.reduce_while(lines, minimum, fn {segments, _kind}, widest ->
      width = segments_width_at_most(segments, 0, limit)

      if width >= limit, do: {:halt, limit}, else: {:cont, max(widest, width)}
    end)
  end

  @spec segments_width_at_most([Markdown.segment()], non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp segments_width_at_most([], width, _limit), do: width
  defp segments_width_at_most(_segments, width, limit) when width >= limit, do: limit

  defp segments_width_at_most([{text, _style} | rest], width, limit) do
    segments_width_at_most(rest, width_at_most(text, width, limit), limit)
  end

  @spec width_at_most(String.t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp width_at_most("", width, _limit), do: width
  defp width_at_most(_text, width, limit) when width >= limit, do: limit

  defp width_at_most(text, width, limit) do
    {grapheme, rest} = String.next_grapheme(text)
    advance = if grapheme == "\t", do: 1, else: WidthOracle.grapheme_width(@oracle, grapheme)
    width_at_most(rest, width + advance, limit)
  end

  @spec index_runs([Markdown.segment()], pos_integer(), pos_integer()) ::
          {[indexed_run()], pos_integer()}
  defp index_runs(segments, next_link, last_link) do
    {runs, _byte, next_link} =
      Enum.reduce(segments, {[], 0, next_link}, fn {text, style}, {runs, byte, id} ->
        {style, id} = indexed_style(style, id, last_link)

        if text == "" do
          {runs, byte, id}
        else
          # Tabs are one display cell here. Their replacement keeps the source byte offsets.
          text = :binary.replace(text, "\t", " ", [:global])
          {[{byte, text, style} | runs], byte + byte_size(text), id}
        end
      end)

    {Enum.reverse(runs), next_link}
  end

  @spec indexed_style(Markdown.style(), pos_integer(), pos_integer()) :: {style(), pos_integer()}
  defp indexed_style({:link, _url}, id, last) when id <= last, do: {{:hover_link, id}, id + 1}
  defp indexed_style(style, id, _last), do: {style, id}

  # Match Go's run-local graphemes without losing the row's last fitting word break.
  @spec wrap_runs([indexed_run()], pos_integer()) :: nonempty_list(row_bounds())
  defp wrap_runs(runs, width) do
    {{start, _cells, _space_break, rows}, stop} =
      Enum.reduce(runs, {{0, 0, nil, []}, 0}, fn {byte, text, _style}, {scan, _stop} ->
        {wrap_run(text, byte, scan, width), byte + byte_size(text)}
      end)

    Enum.reverse([{start, stop} | rows])
  end

  @spec wrap_run(String.t(), non_neg_integer(), row_scan(), pos_integer()) :: row_scan()
  defp wrap_run("", _byte, scan, _width), do: scan

  defp wrap_run(text, byte, scan, width) do
    {grapheme, rest} = String.next_grapheme(text)
    stop = byte + byte_size(grapheme)
    advance = WidthOracle.grapheme_width(@oracle, grapheme)
    scan = fit_grapheme(scan, byte, stop, advance, grapheme == " ", width)
    wrap_run(rest, stop, scan, width)
  end

  @spec fit_grapheme(
          row_scan(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          boolean(),
          pos_integer()
        ) :: row_scan()
  defp fit_grapheme({start, cells, space_break, rows}, byte, stop, advance, space?, width)
       when cells + advance <= width do
    cells = cells + advance
    space_break = if space? and byte > start, do: {stop, cells}, else: space_break
    {start, cells, space_break, rows}
  end

  defp fit_grapheme(
         {start, cells, {after_space, prefix_cells}, rows},
         byte,
         stop,
         advance,
         space?,
         width
       ) do
    # Carry the already-measured suffix into the next row instead of scanning that word again.
    next = {after_space, cells - prefix_cells, nil, [{start, after_space} | rows]}
    fit_grapheme(next, byte, stop, advance, space?, width)
  end

  defp fit_grapheme({start, _cells, nil, rows}, byte, _stop, advance, _space?, _width),
    do: {byte, advance, nil, [{start, byte} | rows]}

  @spec viewport(tuple(), position(), pos_integer()) :: {non_neg_integer(), pos_integer()}
  defp viewport(rows, position, height) do
    size = max(height - 2, 1)
    index = at_or_before(rows, position, 0, max(tuple_size(rows) - 1, 0))
    {clamp(index, tuple_size(rows), size), size}
  end

  @spec clamp(integer(), non_neg_integer(), pos_integer()) :: non_neg_integer()
  defp clamp(index, count, size), do: index |> min(count - size) |> max(0)

  # Both rows and runs are ordered by the source position in their first field.
  @spec at_or_before(
          tuple(),
          position() | non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          non_neg_integer()
  defp at_or_before(_entries, _position, index, index), do: index

  defp at_or_before(entries, position, first, last) do
    middle = div(first + last + 1, 2)

    if elem(elem(entries, middle), 0) <= position,
      do: at_or_before(entries, position, middle, last),
      else: at_or_before(entries, position, first, middle - 1)
  end

  @spec slice(tuple(), non_neg_integer(), non_neg_integer()) :: [{String.t(), style()}]
  defp slice(_runs, start, start), do: []

  defp slice(runs, start, stop) do
    index = at_or_before(runs, start, 0, tuple_size(runs) - 1)
    slice(runs, index, start, stop, [])
  end

  @spec slice(tuple(), non_neg_integer(), non_neg_integer(), non_neg_integer(), [
          {String.t(), style()}
        ]) :: [{String.t(), style()}]
  defp slice(runs, index, start, stop, acc) do
    {offset, text, style} = elem(runs, index)
    last = min(stop, offset + byte_size(text))
    acc = [{binary_part(text, start - offset, last - start), style} | acc]

    if last == stop,
      do: Enum.reverse(acc),
      else: slice(runs, index + 1, last, stop, acc)
  end
end
