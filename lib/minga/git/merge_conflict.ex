defmodule Minga.Git.MergeConflict do
  @moduledoc """
  Pure parsing and replacement helpers for Git merge conflict markers.

  The parser recognizes standard two-way conflicts and diff3 conflicts with a `|||||||` base section. It returns complete regions only, so callers never render an action row for a malformed or partially typed conflict block.
  """

  alias Minga.Buffer.Conflict
  alias Minga.Git.MergeConflict.Region
  alias Minga.Git.MergeConflict.Entry

  @type choice :: Conflict.choice()

  @typep marker_position :: {non_neg_integer(), String.t()}
  @typep side :: {marker_position(), [String.t()]}
  @typep phase ::
           :outside
           | {:current, marker_position()}
           | {:base, side(), marker_position()}
           | {:incoming, side(), side() | nil, non_neg_integer()}

  @doc "Parses merge conflict regions from full buffer content."
  @spec parse(String.t()) :: [Region.t()]
  def parse(content) when is_binary(content) do
    content
    |> String.split("\n", trim: false)
    |> parse_lines()
  end

  @doc "Parses merge conflict regions from buffer lines."
  @spec parse_lines([String.t()]) :: [Region.t()]
  def parse_lines(lines) when is_list(lines) do
    lines
    |> scan(0, :outside, [], [])
    |> Enum.reverse()
  end

  @doc "Returns the conflict region containing `line`, if any."
  @spec at_line([Region.t() | Entry.t()], non_neg_integer()) :: Region.t() | Entry.t() | nil
  def at_line(regions, line) when is_list(regions) and is_integer(line) do
    Enum.find(regions, fn region -> line >= region.start_line and line <= region.end_line end)
  end

  @doc "Returns the next conflict after `line`, wrapping to the first conflict."
  @spec next_after([Region.t() | Entry.t()], non_neg_integer()) :: Region.t() | Entry.t() | nil
  def next_after([], _line), do: nil

  def next_after(regions, line) when is_list(regions) and is_integer(line) do
    Enum.find(regions, fn region -> region.start_line > line end) || List.first(regions)
  end

  @doc "Returns the previous conflict before `line`, wrapping to the last conflict."
  @spec prev_before([Region.t() | Entry.t()], non_neg_integer()) :: Region.t() | Entry.t() | nil
  def prev_before([], _line), do: nil

  def prev_before(regions, line) when is_list(regions) and is_integer(line) do
    regions
    |> Enum.reverse()
    |> Enum.find(fn region -> region.start_line < line end)
    |> previous_or_last(regions)
  end

  @doc "Returns marker-free replacement lines for the selected side."
  @spec replacement_lines(Region.t(), choice()) :: [String.t()]
  def replacement_lines(%Region{} = region, :current), do: region.current_lines
  def replacement_lines(%Region{} = region, :incoming), do: region.incoming_lines

  def replacement_lines(%Region{} = region, :both),
    do: region.current_lines ++ region.incoming_lines

  @doc "Materializes a full conflict region from a retained lightweight entry."
  @spec region_from_entry(String.t(), Entry.t()) :: Region.t()
  def region_from_entry(content, %Entry{} = entry) when is_binary(content) do
    lines = String.split(content, "\n", trim: false)

    region_with_lines(
      entry,
      slice_range(lines, entry.current_range),
      optional_slice_range(lines, entry.base_range),
      slice_range(lines, entry.incoming_range)
    )
  end

  @spec region_with_lines(Entry.t(), [String.t()], [String.t()] | nil, [String.t()]) :: Region.t()
  defp region_with_lines(entry, current, base, incoming) do
    %Region{
      start_line: entry.start_line,
      separator_line: entry.separator_line,
      end_line: entry.end_line,
      base_marker_line: entry.base_marker_line,
      current_range: entry.current_range,
      base_range: entry.base_range,
      incoming_range: entry.incoming_range,
      current_label: entry.current_label,
      base_label: entry.base_label,
      incoming_label: entry.incoming_label,
      current_lines: current,
      base_lines: base,
      incoming_lines: incoming
    }
  end

  @doc "Returns marker-free replacement text for the selected side."
  @spec replacement(Region.t(), choice()) :: String.t()
  def replacement(%Region{} = region, choice),
    do: region |> replacement_lines(choice) |> Enum.join("\n")

  @doc "Replaces a materialized region or a lightweight entry from the given content snapshot."
  @spec replace_region(String.t(), Region.t() | Entry.t(), choice()) :: String.t()
  def replace_region(content, %Region{} = region, choice) when is_binary(content) do
    content
    |> String.split("\n", trim: false)
    |> replace_region_lines(region, choice)
    |> Enum.join("\n")
  end

  def replace_region(content, %Entry{} = entry, choice) when is_binary(content) do
    lines = String.split(content, "\n", trim: false)
    {prefix, conflict_and_suffix} = Enum.split(lines, entry.start_line)
    replacement = entry_replacement(conflict_and_suffix, entry, choice)
    suffix = Enum.drop(conflict_and_suffix, entry.end_line - entry.start_line + 1)

    Enum.join(prefix ++ replacement ++ suffix, "\n")
  end

  @doc "Replaces the conflict containing `line` in `content` with the selected side."
  @spec replace_at_line(String.t(), non_neg_integer(), choice()) :: {:ok, String.t()} | :not_found
  def replace_at_line(content, line, choice) when is_binary(content) and is_integer(line) do
    lines = String.split(content, "\n", trim: false)
    regions = parse_lines(lines)

    case at_line(regions, line) do
      nil -> :not_found
      %Region{} = region -> {:ok, replace_region_lines(lines, region, choice) |> Enum.join("\n")}
    end
  end

  @spec scan([String.t()], non_neg_integer(), phase(), [String.t()], [Region.t()]) :: [Region.t()]
  defp scan([], _line, _phase, _side, regions), do: regions

  defp scan(["<<<<<<<" <> label | rest], line, :outside, [], regions) do
    scan(rest, line + 1, {:current, {line, label}}, [], regions)
  end

  defp scan([_ | rest], line, :outside, [], regions),
    do: scan(rest, line + 1, :outside, [], regions)

  defp scan(["|||||||" <> label | rest], line, {:current, start}, current, regions) do
    scan(rest, line + 1, {:base, {start, current}, {line, label}}, [], regions)
  end

  defp scan(["=======" <> _ | rest], line, {:current, start}, current, regions) do
    scan(rest, line + 1, {:incoming, {start, current}, nil, line}, [], regions)
  end

  defp scan(["=======" <> _ | rest], line, {:base, current, marker}, base, regions) do
    scan(rest, line + 1, {:incoming, current, {marker, base}, line}, [], regions)
  end

  defp scan(
         [">>>>>>>" <> label | rest],
         line,
         {:incoming, current, base, separator},
         incoming,
         regions
       ) do
    region = complete_region(current, base, separator, {{line, label}, incoming})
    scan(rest, line + 1, :outside, [], [region | regions])
  end

  # A prefix that does not end the active section is ordinary body text.
  defp scan([text | rest], line, phase, side, regions) do
    scan(rest, line + 1, phase, [text | side], regions)
  end

  @spec complete_region(side(), side() | nil, non_neg_integer(), side()) :: Region.t()
  defp complete_region({{start, current_label}, current}, base, separator, incoming) do
    {{ending, label}, lines} = incoming
    {base_line, base_label, base_lines} = complete_base(base)

    entry =
      Entry.new(
        start,
        base_line,
        separator,
        ending,
        String.trim(current_label),
        base_label,
        String.trim(label)
      )

    region_with_lines(entry, Enum.reverse(current), base_lines, Enum.reverse(lines))
  end

  @spec complete_base(side() | nil) ::
          {non_neg_integer() | nil, String.t() | nil, [String.t()] | nil}
  defp complete_base(nil), do: {nil, nil, nil}

  defp complete_base({{line, label}, reversed}),
    do: {line, String.trim(label), Enum.reverse(reversed)}

  @spec entry_replacement([String.t()], Entry.t(), choice()) :: [String.t()]
  defp entry_replacement(lines, %Entry{start_line: start, current_range: range}, :current),
    do: slice_relative_range(lines, range, start)

  defp entry_replacement(lines, %Entry{start_line: start, incoming_range: range}, :incoming),
    do: slice_relative_range(lines, range, start)

  defp entry_replacement(lines, entry, :both),
    do: entry_replacement(lines, entry, :current) ++ entry_replacement(lines, entry, :incoming)

  @spec slice_relative_range([String.t()], Entry.line_range(), non_neg_integer()) :: [String.t()]
  defp slice_relative_range(lines, {first, last}, start),
    do: slice_lines(lines, first - start, last - start)

  @spec replace_region_lines([String.t()], Region.t(), choice()) :: [String.t()]
  defp replace_region_lines(lines, %Region{} = region, choice) do
    prefix = Enum.take(lines, region.start_line)
    suffix = Enum.drop(lines, region.end_line + 1)
    prefix ++ replacement_lines(region, choice) ++ suffix
  end

  @spec slice_lines([String.t()], non_neg_integer(), integer()) :: [String.t()]
  defp slice_lines(_lines, start_idx, end_idx) when end_idx < start_idx, do: []

  defp slice_lines(lines, start_idx, end_idx),
    do: lines |> Enum.slice(start_idx, end_idx - start_idx + 1)

  @spec slice_range([String.t()], Entry.line_range()) :: [String.t()]
  defp slice_range(lines, {start_idx, end_idx}), do: slice_lines(lines, start_idx, end_idx)

  @spec optional_slice_range([String.t()], Entry.line_range() | nil) :: [String.t()] | nil
  defp optional_slice_range(_lines, nil), do: nil
  defp optional_slice_range(lines, range), do: slice_range(lines, range)

  @spec previous_or_last(Region.t() | Entry.t() | nil, [Region.t() | Entry.t()]) ::
          Region.t() | Entry.t() | nil
  defp previous_or_last(nil, regions), do: Enum.at(regions, -1)
  defp previous_or_last(region, _regions), do: region
end
