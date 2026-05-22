defmodule Minga.Git.MergeConflict do
  @moduledoc """
  Pure parsing and replacement helpers for Git merge conflict markers.

  The parser recognizes standard two-way conflicts and diff3 conflicts with a `|||||||` base section. It returns complete regions only, so callers never render an action row for a malformed or partially typed conflict block.
  """

  alias Minga.Git.MergeConflict.Region

  @type choice :: :current | :incoming | :both

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
    |> Enum.with_index()
    |> do_parse_lines(lines, [])
    |> Enum.reverse()
  end

  @doc "Returns the conflict region containing `line`, if any."
  @spec at_line([Region.t()], non_neg_integer()) :: Region.t() | nil
  def at_line(regions, line) when is_list(regions) and is_integer(line) do
    Enum.find(regions, fn region -> line >= region.start_line and line <= region.end_line end)
  end

  @doc "Returns the next conflict after `line`, wrapping to the first conflict."
  @spec next_after([Region.t()], non_neg_integer()) :: Region.t() | nil
  def next_after([], _line), do: nil

  def next_after(regions, line) when is_list(regions) and is_integer(line) do
    Enum.find(regions, fn region -> region.start_line > line end) || List.first(regions)
  end

  @doc "Returns the previous conflict before `line`, wrapping to the last conflict."
  @spec prev_before([Region.t()], non_neg_integer()) :: Region.t() | nil
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

  @doc "Returns marker-free replacement text for the selected side."
  @spec replacement(Region.t(), choice()) :: String.t()
  def replacement(%Region{} = region, choice),
    do: region |> replacement_lines(choice) |> Enum.join("\n")

  @doc "Replaces the given region in `content` with the selected side."
  @spec replace_region(String.t(), Region.t(), choice()) :: String.t()
  def replace_region(content, %Region{} = region, choice) when is_binary(content) do
    content
    |> String.split("\n", trim: false)
    |> replace_region_lines(region, choice)
    |> Enum.join("\n")
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

  @spec do_parse_lines([{String.t(), non_neg_integer()}], [String.t()], [Region.t()]) :: [
          Region.t()
        ]
  defp do_parse_lines([], _lines, acc), do: acc

  defp do_parse_lines([{line, idx} | rest], lines, acc) do
    if marker?(line, "<<<<<<<") do
      parse_conflict_at(lines, idx, line)
      |> continue_after_conflict(rest, lines, acc)
    else
      do_parse_lines(rest, lines, acc)
    end
  end

  @spec continue_after_conflict(
          {:ok, Region.t()} | :error,
          [{String.t(), non_neg_integer()}],
          [String.t()],
          [Region.t()]
        ) :: [Region.t()]
  defp continue_after_conflict({:ok, %Region{} = region}, rest, lines, acc) do
    remaining = Enum.drop_while(rest, fn {_line, idx} -> idx <= region.end_line end)
    do_parse_lines(remaining, lines, [region | acc])
  end

  defp continue_after_conflict(:error, rest, lines, acc), do: do_parse_lines(rest, lines, acc)

  @spec parse_conflict_at([String.t()], non_neg_integer(), String.t()) ::
          {:ok, Region.t()} | :error
  defp parse_conflict_at(lines, start_idx, start_marker) do
    tail = Enum.drop(lines, start_idx + 1)

    with {:ok, separator_idx, base_marker_idx, base_marker} <-
           find_separator(tail, start_idx + 1, nil, nil),
         {:ok, end_idx, end_marker} <- find_end_marker(lines, separator_idx + 1) do
      {:ok,
       build_region(
         lines,
         start_idx,
         start_marker,
         base_marker_idx,
         base_marker,
         separator_idx,
         end_idx,
         end_marker
       )}
    else
      :error -> :error
    end
  end

  @spec find_separator([String.t()], non_neg_integer(), non_neg_integer() | nil, String.t() | nil) ::
          {:ok, non_neg_integer(), non_neg_integer() | nil, String.t() | nil} | :error
  defp find_separator([], _idx, _base_idx, _base_marker), do: :error

  defp find_separator([line | rest], idx, base_idx, base_marker) do
    parse_separator_line(line, rest, idx, base_idx, base_marker)
  end

  @spec parse_separator_line(
          String.t(),
          [String.t()],
          non_neg_integer(),
          non_neg_integer() | nil,
          String.t() | nil
        ) ::
          {:ok, non_neg_integer(), non_neg_integer() | nil, String.t() | nil} | :error
  defp parse_separator_line(line, rest, idx, base_idx, base_marker) do
    if marker?(line, "=======") do
      {:ok, idx, base_idx, base_marker}
    else
      parse_base_line(line, rest, idx, base_idx, base_marker)
    end
  end

  @spec parse_base_line(
          String.t(),
          [String.t()],
          non_neg_integer(),
          non_neg_integer() | nil,
          String.t() | nil
        ) ::
          {:ok, non_neg_integer(), non_neg_integer() | nil, String.t() | nil} | :error
  defp parse_base_line(line, rest, idx, nil, _base_marker) do
    if marker?(line, "|||||||") do
      find_separator(rest, idx + 1, idx, marker_label(line, "|||||||"))
    else
      find_separator(rest, idx + 1, nil, nil)
    end
  end

  defp parse_base_line(_line, rest, idx, base_idx, base_marker) do
    find_separator(rest, idx + 1, base_idx, base_marker)
  end

  @spec find_end_marker([String.t()], non_neg_integer()) ::
          {:ok, non_neg_integer(), String.t()} | :error
  defp find_end_marker(lines, start_idx) do
    lines
    |> Enum.drop(start_idx)
    |> Enum.with_index(start_idx)
    |> Enum.find(fn {line, _idx} -> marker?(line, ">>>>>>>") end)
    |> end_marker_result()
  end

  @spec end_marker_result({String.t(), non_neg_integer()} | nil) ::
          {:ok, non_neg_integer(), String.t()} | :error
  defp end_marker_result(nil), do: :error
  defp end_marker_result({line, idx}), do: {:ok, idx, line}

  @spec build_region(
          [String.t()],
          non_neg_integer(),
          String.t(),
          non_neg_integer() | nil,
          String.t() | nil,
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: Region.t()
  defp build_region(lines, start_idx, start_marker, nil, nil, separator_idx, end_idx, end_marker) do
    %Region{
      start_line: start_idx,
      current_range: {start_idx + 1, separator_idx - 1},
      separator_line: separator_idx,
      incoming_range: {separator_idx + 1, end_idx - 1},
      end_line: end_idx,
      current_label: marker_label(start_marker, "<<<<<<<"),
      incoming_label: marker_label(end_marker, ">>>>>>>"),
      current_lines: slice_lines(lines, start_idx + 1, separator_idx - 1),
      incoming_lines: slice_lines(lines, separator_idx + 1, end_idx - 1),
      base_lines: nil
    }
  end

  defp build_region(
         lines,
         start_idx,
         start_marker,
         base_idx,
         base_marker,
         separator_idx,
         end_idx,
         end_marker
       ) do
    %Region{
      start_line: start_idx,
      current_range: {start_idx + 1, base_idx - 1},
      base_marker_line: base_idx,
      base_range: {base_idx + 1, separator_idx - 1},
      separator_line: separator_idx,
      incoming_range: {separator_idx + 1, end_idx - 1},
      end_line: end_idx,
      current_label: marker_label(start_marker, "<<<<<<<"),
      base_label: base_marker,
      incoming_label: marker_label(end_marker, ">>>>>>>"),
      current_lines: slice_lines(lines, start_idx + 1, base_idx - 1),
      base_lines: slice_lines(lines, base_idx + 1, separator_idx - 1),
      incoming_lines: slice_lines(lines, separator_idx + 1, end_idx - 1)
    }
  end

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

  @spec marker?(String.t(), String.t()) :: boolean()
  defp marker?(line, prefix), do: String.starts_with?(line, prefix)

  @spec marker_label(String.t(), String.t()) :: String.t()
  defp marker_label(line, prefix) do
    line
    |> String.replace_prefix(prefix, "")
    |> String.trim()
  end

  @spec previous_or_last(Region.t() | nil, [Region.t()]) :: Region.t() | nil
  defp previous_or_last(nil, regions), do: List.last(regions)
  defp previous_or_last(region, _regions), do: region
end
