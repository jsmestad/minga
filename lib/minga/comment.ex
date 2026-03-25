defmodule Minga.Comment do
  @moduledoc """
  Line comment toggling per filetype.

  Provides a static mapping of filetype atoms to their line comment prefix
  and logic for toggling comments on a range of buffer lines. The toggle is
  "smart": if any non-empty line in the range lacks the comment prefix, all
  non-empty lines get commented. If every non-empty line is already commented,
  all get uncommented.

  Comments are indent-aware. The comment prefix is inserted at the column of
  the least-indented non-empty line, preserving relative indentation.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Language.Registry, as: LangRegistry

  @typedoc "A single injection range from tree-sitter."
  @type injection_range :: Minga.Highlight.InjectionRange.t()

  @typedoc "Direction the toggle should go."
  @type toggle_direction :: :comment | :uncomment

  @doc """
  Returns the line comment prefix for a given filetype atom.

  Falls back to `"# "` for unknown filetypes.

  ## Examples

      iex> Minga.Comment.comment_string(:elixir)
      "# "

      iex> Minga.Comment.comment_string(:zig)
      "// "

      iex> Minga.Comment.comment_string(:unknown_language)
      "# "
  """
  @spec comment_string(atom()) :: String.t()
  def comment_string(filetype) do
    case LangRegistry.get(filetype) do
      %{comment_token: token} when is_binary(token) -> token
      _ -> "# "
    end
  end

  @doc """
  Returns the comment string for a position in a buffer, accounting for
  tree-sitter injection regions (e.g., Elixir inside HEEx, JS inside HTML).

  Checks the injection ranges first. If the byte offset falls inside an
  injection region, uses that region's language. Otherwise falls back to the
  buffer's filetype.
  """
  @spec comment_string_at(atom(), non_neg_integer(), [injection_range()]) :: String.t()
  def comment_string_at(filetype, _byte_offset, []) do
    comment_string(filetype)
  end

  def comment_string_at(filetype, byte_offset, injection_ranges) do
    case find_injection_language(injection_ranges, byte_offset) do
      nil -> comment_string(filetype)
      lang_name -> comment_string_for_name(lang_name, filetype)
    end
  end

  @spec find_injection_language([injection_range()], non_neg_integer()) :: String.t() | nil
  defp find_injection_language(ranges, byte_offset) do
    case Enum.find(ranges, fn r ->
           byte_offset >= r.start_byte and byte_offset < r.end_byte
         end) do
      nil -> nil
      %{language: lang_name} -> lang_name
    end
  end

  @spec comment_string_for_name(String.t(), atom()) :: String.t()
  defp comment_string_for_name(lang_name, fallback_filetype) do
    String.to_existing_atom(lang_name)
    |> comment_string()
  rescue
    ArgumentError -> comment_string(fallback_filetype)
  end

  @doc """
  Toggles line comments on a range of buffer lines.

  Reads lines `start_line..end_line` from the buffer, determines whether to
  comment or uncomment, and applies the edits. Empty lines are left untouched.
  The comment prefix is placed at the indentation level of the least-indented
  non-empty line in the range.
  """
  @spec toggle_lines(pid(), non_neg_integer(), non_neg_integer(), atom(), [injection_range()]) ::
          :ok
  def toggle_lines(buf, start_line, end_line, filetype, injection_ranges \\ []) do
    prefix = resolve_comment_prefix(buf, start_line, filetype, injection_ranges)
    raw = BufferServer.get_lines_content(buf, start_line, end_line)
    lines = String.split(raw, "\n")

    non_empty = Enum.reject(lines, &blank?/1)

    if non_empty == [] do
      :ok
    else
      min_indent = min_indentation(non_empty)
      direction = detect_direction(non_empty, prefix, min_indent)
      apply_toggle(buf, start_line, lines, prefix, min_indent, direction)
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec resolve_comment_prefix(pid(), non_neg_integer(), atom(), [injection_range()]) ::
          String.t()
  defp resolve_comment_prefix(_buf, _start_line, filetype, []) do
    comment_string(filetype)
  end

  defp resolve_comment_prefix(buf, start_line, filetype, injection_ranges) do
    # Get byte offset of the start line to determine which language context we're in
    byte_offset = BufferServer.byte_offset_for_line(buf, start_line)
    comment_string_at(filetype, byte_offset, injection_ranges)
  end

  @spec detect_direction([String.t()], String.t(), non_neg_integer()) :: toggle_direction()
  defp detect_direction(non_empty_lines, prefix, min_indent) do
    all_commented =
      Enum.all?(non_empty_lines, fn line ->
        trimmed = String.slice(line, min_indent, String.length(line))
        String.starts_with?(trimmed, prefix)
      end)

    if all_commented, do: :uncomment, else: :comment
  end

  @spec apply_toggle(
          pid(),
          non_neg_integer(),
          [String.t()],
          String.t(),
          non_neg_integer(),
          toggle_direction()
        ) :: :ok
  defp apply_toggle(buf, start_line, lines, prefix, min_indent, direction) do
    prefix_len = String.length(prefix)

    edits =
      lines
      |> Enum.with_index(start_line)
      |> Enum.reject(fn {line, _idx} -> blank?(line) end)
      |> Enum.map(fn {_line, idx} ->
        build_edit(idx, min_indent, prefix, prefix_len, direction)
      end)

    # Apply edits in reverse order so line positions stay valid
    edits
    |> Enum.reverse()
    |> Enum.each(fn edit -> apply_edit(buf, edit) end)

    :ok
  end

  @spec build_edit(
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          non_neg_integer(),
          toggle_direction()
        ) ::
          {:insert, non_neg_integer(), non_neg_integer(), String.t()}
          | {:delete, non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp build_edit(line_idx, col, prefix, _prefix_len, :comment) do
    {:insert, line_idx, col, prefix}
  end

  defp build_edit(line_idx, col, _prefix, prefix_len, :uncomment) do
    {:delete, line_idx, col, prefix_len}
  end

  @spec apply_edit(
          pid(),
          {:insert, non_neg_integer(), non_neg_integer(), String.t()}
          | {:delete, non_neg_integer(), non_neg_integer(), non_neg_integer()}
        ) :: :ok
  defp apply_edit(buf, {:insert, line, col, text}) do
    BufferServer.move_to(buf, {line, col})
    BufferServer.insert_text(buf, text)
  end

  defp apply_edit(buf, {:delete, line, col, len}) do
    # delete_range is inclusive on both ends, so end col is col + len - 1
    BufferServer.apply_text_edit(buf, line, col, line, col + len - 1, "")
  end

  @spec blank?(String.t()) :: boolean()
  defp blank?(line), do: String.trim(line) == ""

  @spec min_indentation([String.t()]) :: non_neg_integer()
  defp min_indentation(non_empty_lines) do
    non_empty_lines
    |> Enum.map(&leading_whitespace_count/1)
    |> Enum.min()
  end

  @spec leading_whitespace_count(String.t()) :: non_neg_integer()
  defp leading_whitespace_count(line) do
    line
    |> String.graphemes()
    |> Enum.take_while(&(&1 == " " or &1 == "\t"))
    |> length()
  end
end
