defmodule Minga.Core.IndentGuide do
  @moduledoc """
  Pure computation of indent guide positions from visible line content.

  Computes the character columns where vertical indent guide lines should
  appear, given a list of visible lines and the tab width. Also identifies
  the "active" guide: the deepest guide at or to the left of the cursor
  column, which the frontend highlights in a brighter color.

  Blank lines do not break guide continuity. A guide spans through blank
  lines if indented code resumes below, matching VS Code behavior.

  This is a Layer 0 module: no GenServer calls, no state, no side effects.
  """

  @typedoc "A single indent guide with its column position and active state."
  @type guide :: %{col: non_neg_integer(), active: boolean()}

  @doc """
  Computes indent guide columns for a list of visible lines.

  Returns a list of `%{col, active}` maps, one per guide column that should
  be drawn. Guide columns are in character units from the content start
  (not screen left), at each `tab_width` boundary where at least one line
  in the range has indentation at or beyond that level.

  `cursor_col` is used to determine the active guide. The active guide is
  the deepest guide column <= `cursor_col`. Pass `0` to disable active
  guide highlighting.

  ## Examples

      iex> lines = ["def foo do", "  bar()", "    baz()", "  end", "end"]
      iex> Minga.Core.IndentGuide.compute(lines, 2, 4)
      [%{col: 2, active: false}, %{col: 4, active: true}]

      iex> Minga.Core.IndentGuide.compute(["no indent"], 2, 0)
      []

  """
  @spec compute(
          lines :: [String.t()],
          tab_width :: pos_integer(),
          cursor_col :: non_neg_integer()
        ) ::
          [guide()]
  def compute(lines, tab_width, cursor_col)
      when is_list(lines) and is_integer(tab_width) and tab_width > 0 and
             is_integer(cursor_col) and cursor_col >= 0 do
    # Compute the effective indentation level of each line, propagating
    # through blank lines by looking ahead to the next non-blank line.
    indent_levels = effective_indent_levels(lines, tab_width)

    # Find the maximum indentation level across all visible lines.
    max_level =
      case indent_levels do
        [] -> 0
        levels -> Enum.max(levels)
      end

    build_guides(indent_levels, max_level, tab_width, cursor_col)
  end

  @doc """
  Computes the effective indentation level of each line.

  Blank lines inherit the indentation of the next non-blank line below
  them (look-ahead), so guides don't break through blank lines.
  """
  @spec effective_indent_levels([String.t()], pos_integer()) :: [non_neg_integer()]
  def effective_indent_levels(lines, tab_width) do
    # First pass: compute raw indent levels.
    raw_levels = Enum.map(lines, &indent_level(&1, tab_width))

    # Second pass (reverse): propagate non-blank indent through blank lines.
    # We walk backward, carrying the "next non-blank indent" upward.
    {resolved, _} =
      raw_levels
      |> Enum.zip(lines)
      |> Enum.reverse()
      |> Enum.map_reduce(0, fn {level, line}, next_nonblank ->
        if blank?(line) do
          # Blank line: use the min of surrounding indent levels.
          # The "next non-blank below" is carried in the accumulator.
          {next_nonblank, next_nonblank}
        else
          {level, level}
        end
      end)

    Enum.reverse(resolved)
  end

  @doc """
  Computes the indentation level of a single line.

  Counts leading whitespace characters (spaces and tabs), then divides
  by `tab_width`. Tabs count as `tab_width` spaces each.
  """
  @spec indent_level(String.t(), pos_integer()) :: non_neg_integer()
  def indent_level(line, tab_width) do
    spaces = count_leading_whitespace(line, tab_width)
    div(spaces, tab_width)
  end

  @spec build_guides([non_neg_integer()], non_neg_integer(), pos_integer(), non_neg_integer()) ::
          [guide()]
  defp build_guides(_indent_levels, 0, _tab_width, _cursor_col), do: []

  defp build_guides(indent_levels, max_level, tab_width, cursor_col) do
    active_col = active_guide_col(max_level, tab_width, cursor_col)

    for level <- 1..max_level,
        col = level * tab_width,
        Enum.any?(indent_levels, fn l -> l >= level end) do
      %{col: col, active: col == active_col}
    end
  end

  # ── Private helpers ──

  @spec count_leading_whitespace(String.t(), pos_integer()) :: non_neg_integer()
  defp count_leading_whitespace(line, tab_width) do
    count_ws(line, tab_width, 0)
  end

  @spec count_ws(String.t(), pos_integer(), non_neg_integer()) :: non_neg_integer()
  defp count_ws(<<?\s, rest::binary>>, tw, acc), do: count_ws(rest, tw, acc + 1)
  defp count_ws(<<?\t, rest::binary>>, tw, acc), do: count_ws(rest, tw, acc + tw)
  defp count_ws(_, _tw, acc), do: acc

  @spec blank?(String.t()) :: boolean()
  defp blank?(""), do: true
  defp blank?(line), do: String.trim(line) == ""

  @spec active_guide_col(non_neg_integer(), pos_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp active_guide_col(max_level, tab_width, cursor_col) do
    # Find the deepest guide column that is <= cursor_col.
    # Guide columns are at tab_width, 2*tab_width, ..., max_level*tab_width.
    active_level = min(div(cursor_col, tab_width), max_level)

    if active_level > 0 do
      active_level * tab_width
    else
      0
    end
  end
end
