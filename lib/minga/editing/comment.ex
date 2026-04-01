defmodule Minga.Editing.Comment do
  @moduledoc """
  Pure comment toggling logic.

  Given lines of text and a comment prefix, computes which edits are needed
  to toggle comments. The toggle is "smart": if any non-empty line in the
  range lacks the comment prefix, all non-empty lines get commented. If every
  non-empty line is already commented, all get uncommented.

  Comments are indent-aware. The comment prefix is inserted at the column of
  the least-indented non-empty line, preserving relative indentation.

  This module is Layer 0 (pure functions). It does not call GenServers or
  registries. The caller is responsible for reading buffer content, resolving
  the comment prefix via `Language.get/1`, and applying the returned edits.
  """

  @typedoc "A single injection range from tree-sitter."
  @type injection_range :: Minga.Language.Highlight.InjectionRange.t()

  @typedoc "Direction the toggle should go."
  @type toggle_direction :: :comment | :uncomment

  @typedoc "An edit descriptor returned by `compute_toggle_edits/3`."
  @type edit ::
          {:insert, non_neg_integer(), non_neg_integer(), String.t()}
          | {:delete, non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc """
  Returns a comment prefix with a fallback default.

  When `comment_token` is a non-nil string, returns it as-is. Otherwise
  falls back to `"# "`. This is a convenience for callers that already
  resolved the token via `Language.get(filetype).comment_token`.

  ## Examples

      iex> Minga.Editing.Comment.comment_prefix("// ")
      "// "

      iex> Minga.Editing.Comment.comment_prefix(nil)
      "# "
  """
  @spec comment_prefix(String.t() | nil) :: String.t()
  def comment_prefix(nil), do: "# "
  def comment_prefix(token) when is_binary(token), do: token

  @doc """
  Resolves the comment prefix for a byte offset, accounting for tree-sitter
  injection regions (e.g., Elixir inside HEEx, JS inside HTML).

  The `token_for_lang` function is called with a language name atom and
  should return the comment token string (or nil for unknown languages).
  This lets the caller provide the lookup without this module depending on
  `Language.get/1`.
  """
  @spec comment_prefix_at(
          String.t() | nil,
          non_neg_integer(),
          [injection_range()],
          (atom() -> String.t() | nil)
        ) :: String.t()
  def comment_prefix_at(default_token, _byte_offset, [], _token_for_lang) do
    comment_prefix(default_token)
  end

  def comment_prefix_at(default_token, byte_offset, injection_ranges, token_for_lang) do
    case find_injection_language(injection_ranges, byte_offset) do
      nil ->
        comment_prefix(default_token)

      lang_name ->
        lang_atom =
          try do
            String.to_existing_atom(lang_name)
          rescue
            ArgumentError -> nil
          end

        if lang_atom do
          comment_prefix(token_for_lang.(lang_atom))
        else
          comment_prefix(default_token)
        end
    end
  end

  @doc """
  Computes the edits needed to toggle comments on a list of lines.

  Returns a list of edit descriptors (in reverse line order so positions
  stay valid when applied sequentially). Empty lines are left untouched.

  ## Parameters

    * `lines` - the text lines to toggle (already read from the buffer)
    * `prefix` - the comment prefix string (e.g., `"# "`, `"// "`)
    * `start_line` - the buffer line number of the first line in `lines`

  ## Examples

      iex> Minga.Editing.Comment.compute_toggle_edits(["hello", "world"], "# ", 0)
      [{:insert, 1, 0, "# "}, {:insert, 0, 0, "# "}]

      iex> Minga.Editing.Comment.compute_toggle_edits(["# hello", "# world"], "# ", 0)
      [{:delete, 1, 0, 2}, {:delete, 0, 0, 2}]
  """
  @spec compute_toggle_edits([String.t()], String.t(), non_neg_integer()) :: [edit()]
  def compute_toggle_edits(lines, prefix, start_line) do
    non_empty = Enum.reject(lines, &blank?/1)

    if non_empty == [] do
      []
    else
      min_indent = min_indentation(non_empty)
      direction = detect_direction(non_empty, prefix, min_indent)
      build_edits(start_line, lines, prefix, min_indent, direction)
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec find_injection_language([injection_range()], non_neg_integer()) :: String.t() | nil
  defp find_injection_language(ranges, byte_offset) do
    case Enum.find(ranges, fn r ->
           byte_offset >= r.start_byte and byte_offset < r.end_byte
         end) do
      nil -> nil
      %{language: lang_name} -> lang_name
    end
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

  @spec build_edits(
          non_neg_integer(),
          [String.t()],
          String.t(),
          non_neg_integer(),
          toggle_direction()
        ) :: [edit()]
  defp build_edits(start_line, lines, prefix, min_indent, direction) do
    prefix_len = String.length(prefix)

    lines
    |> Enum.with_index(start_line)
    |> Enum.reject(fn {line, _idx} -> blank?(line) end)
    |> Enum.map(fn {_line, idx} ->
      build_edit(idx, min_indent, prefix, prefix_len, direction)
    end)
    |> Enum.reverse()
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
