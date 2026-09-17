defmodule Minga.Buffer.ConflictIndex do
  @moduledoc """
  Incrementally maintained merge conflict coordinates for one buffer.

  The index stores marker lines and lightweight regions. An edit scans only the replaced lines, shifts later markers, and rebuilds region structure from the marker sequence. Conflict side text stays in the document and is read only when a resolution command needs it.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.EditDelta
  alias Minga.Buffer.Lines
  alias Minga.Git.MergeConflict.Entry

  @type marker_kind :: :start | :base | :separator | :end
  @type marker :: {line :: non_neg_integer(), marker_kind()}

  @enforce_keys [:markers, :entries]
  defstruct markers: [], entries: []

  @type t :: %__MODULE__{markers: [marker()], entries: [Entry.t()]}

  @doc "Builds the initial index from a document."
  @spec new(Document.t()) :: t()
  def new(%Document{} = document) do
    markers = document |> all_lines() |> marker_lines(0)
    %__MODULE__{markers: markers, entries: parse_entries(document, markers)}
  end

  @doc "Updates the index after one edit."
  @spec apply_edit(t(), Document.t(), EditDelta.t()) :: t()
  def apply_edit(%__MODULE__{} = index, %Document{} = document, %EditDelta{} = delta) do
    {start_line, _start_column} = delta.start_position
    {old_end_line, _old_end_column} = delta.old_end_position
    {new_end_line, _new_end_column} = delta.new_end_position
    line_shift = new_end_line - old_end_line

    markers =
      update_markers(index.markers, document, start_line, old_end_line, new_end_line, line_shift)

    %__MODULE__{markers: markers, entries: parse_entries(document, markers)}
  end

  @doc "Returns the indexed conflict entries."
  @spec entries(t()) :: [Entry.t()]
  def entries(%__MODULE__{entries: entries}), do: entries

  @doc "Returns the conflict count."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{entries: entries}), do: length(entries)

  @spec update_markers(
          [marker()],
          Document.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          integer()
        ) :: [marker()]
  defp update_markers(markers, document, start_line, old_end_line, new_end_line, line_shift) do
    prefix = Enum.take_while(markers, fn {line, _kind} -> line < start_line end)

    changed =
      document
      |> Lines.slice(start_line, new_end_line - start_line + 1)
      |> marker_lines(start_line)

    suffix =
      markers
      |> Enum.drop_while(fn {line, _kind} -> line <= old_end_line end)
      |> Enum.map(fn {line, kind} -> {line + line_shift, kind} end)

    prefix ++ changed ++ suffix
  end

  @spec parse_entries(Document.t(), [marker()]) :: [Entry.t()]
  defp parse_entries(document, markers),
    do: do_parse_entries(document, markers, []) |> Enum.reverse()

  @spec do_parse_entries(Document.t(), [marker()], [Entry.t()]) :: [Entry.t()]
  defp do_parse_entries(_document, [], acc), do: acc

  defp do_parse_entries(document, [{start_line, :start} | rest], acc) do
    case find_separator(rest, nil) do
      {:ok, base_line, separator_line, after_separator} ->
        finish_entry(document, start_line, base_line, separator_line, after_separator, rest, acc)

      :error ->
        acc
    end
  end

  defp do_parse_entries(document, [_marker | rest], acc),
    do: do_parse_entries(document, rest, acc)

  @spec find_separator([marker()], non_neg_integer() | nil) ::
          {:ok, non_neg_integer() | nil, non_neg_integer(), [marker()]} | :error
  defp find_separator([], _base_line), do: :error

  defp find_separator([{line, :separator} | rest], base_line),
    do: {:ok, base_line, line, rest}

  defp find_separator([{line, :base} | rest], nil), do: find_separator(rest, line)
  defp find_separator([_marker | rest], base_line), do: find_separator(rest, base_line)

  @spec finish_entry(
          Document.t(),
          non_neg_integer(),
          non_neg_integer() | nil,
          non_neg_integer(),
          [marker()],
          [marker()],
          [Entry.t()]
        ) :: [Entry.t()]
  defp finish_entry(document, start_line, base_line, separator_line, after_separator, rest, acc) do
    case Enum.find(after_separator, fn {_line, kind} -> kind == :end end) do
      {end_line, :end} ->
        entry =
          Entry.new(
            start_line,
            base_line,
            separator_line,
            end_line,
            marker_label(document, start_line, "<<<<<<<"),
            optional_marker_label(document, base_line, "|||||||"),
            marker_label(document, end_line, ">>>>>>>")
          )

        remaining = Enum.drop_while(rest, fn {line, _kind} -> line <= end_line end)
        do_parse_entries(document, remaining, [entry | acc])

      nil ->
        acc
    end
  end

  @spec all_lines(Document.t()) :: [String.t()]
  defp all_lines(document), do: Lines.slice(document, 0, Document.line_count(document))

  @spec marker_label(Document.t(), non_neg_integer(), String.t()) :: String.t()
  defp marker_label(document, line, prefix) do
    document
    |> Lines.fetch(line)
    |> String.replace_prefix(prefix, "")
    |> String.trim()
  end

  @spec optional_marker_label(Document.t(), non_neg_integer() | nil, String.t()) ::
          String.t() | nil
  defp optional_marker_label(_document, nil, _prefix), do: nil
  defp optional_marker_label(document, line, prefix), do: marker_label(document, line, prefix)

  @spec marker_lines([String.t()], non_neg_integer()) :: [marker()]
  defp marker_lines(lines, offset) do
    lines
    |> Enum.with_index(offset)
    |> Enum.flat_map(fn {line, index} ->
      case marker_kind(line) do
        nil -> []
        kind -> [{index, kind}]
      end
    end)
  end

  @spec marker_kind(String.t()) :: marker_kind() | nil
  defp marker_kind("<<<<<<<" <> _rest), do: :start
  defp marker_kind("|||||||" <> _rest), do: :base
  defp marker_kind("=======" <> _rest), do: :separator
  defp marker_kind(">>>>>>>" <> _rest), do: :end
  defp marker_kind(_line), do: nil
end
