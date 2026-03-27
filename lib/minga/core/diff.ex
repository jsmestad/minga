defmodule Minga.Core.Diff do
  @moduledoc """
  In-memory line diffing and hunk operations.

  Uses `List.myers_difference/2` to compute line-level diffs between
  two versions of text. Produces hunk structs consumed by git gutter
  rendering, hunk navigation, AI diff review, and patch generation.

  Pure computation with no side effects.
  """

  @typedoc """
  A contiguous region of change.

  * `:added` — new lines not in the base
  * `:modified` — lines that differ from the base
  * `:deleted` — lines removed from the base (rendered on the line above)
  """
  @type hunk_type :: :added | :modified | :deleted

  @typedoc """
  A hunk represents a contiguous group of changed lines.

  * `type` — the kind of change
  * `start_line` — first buffer line affected (0-indexed)
  * `count` — number of buffer lines in this hunk (0 for pure deletions)
  * `old_start` — first line in the base content (0-indexed)
  * `old_count` — number of base lines replaced/deleted
  * `old_lines` — the original lines from base (for revert and preview)
  """
  @type hunk :: %{
          type: hunk_type(),
          start_line: non_neg_integer(),
          count: non_neg_integer(),
          old_start: non_neg_integer(),
          old_count: non_neg_integer(),
          old_lines: [String.t()]
        }

  @doc """
  Diffs base lines against current lines and returns a list of hunks.

  Both inputs should be lists of strings (one per line, without trailing newlines).
  """
  @spec diff_lines([String.t()], [String.t()]) :: [hunk()]
  def diff_lines(base_lines, current_lines) do
    List.myers_difference(base_lines, current_lines)
    |> build_hunks(0, 0, [])
    |> Enum.reverse()
  end

  @doc """
  Converts hunks to a per-line sign map for the gutter renderer.

  Returns `%{line_number => :added | :modified | :deleted}`.
  Deleted hunks are placed on the line above the deletion point
  (or line 0 if deleted at the start).
  """
  @spec signs_for_hunks([hunk()]) :: %{non_neg_integer() => hunk_type()}
  def signs_for_hunks(hunks) do
    Enum.reduce(hunks, %{}, &add_hunk_signs/2)
  end

  @spec add_hunk_signs(hunk(), %{non_neg_integer() => hunk_type()}) ::
          %{non_neg_integer() => hunk_type()}
  defp add_hunk_signs(%{type: :deleted, start_line: start}, acc) do
    sign_line = max(0, start - 1)
    Map.put_new(acc, sign_line, :deleted)
  end

  defp add_hunk_signs(%{type: type, start_line: start, count: count}, acc) do
    Enum.reduce(0..(count - 1)//1, acc, fn offset, inner_acc ->
      Map.put(inner_acc, start + offset, type)
    end)
  end

  @doc """
  Finds the hunk containing or nearest to the given buffer line.
  """
  @spec hunk_at_line([hunk()], non_neg_integer()) :: hunk() | nil
  def hunk_at_line([], _line), do: nil

  def hunk_at_line(hunks, line) do
    Enum.find(hunks, fn hunk ->
      case hunk.type do
        :deleted ->
          hunk.start_line == line or hunk.start_line - 1 == line

        _ ->
          line >= hunk.start_line and line < hunk.start_line + hunk.count
      end
    end)
  end

  @doc """
  Finds the start line of the next hunk after the given line.
  Returns `nil` if no hunk follows.
  """
  @spec next_hunk_line([hunk()], non_neg_integer()) :: non_neg_integer() | nil
  def next_hunk_line(hunks, line) do
    hunks
    |> Enum.filter(fn h -> h.start_line > line end)
    |> case do
      [] -> nil
      [first | _] -> first.start_line
    end
  end

  @doc """
  Finds the start line of the previous hunk before the given line.
  Returns `nil` if no hunk precedes.
  """
  @spec prev_hunk_line([hunk()], non_neg_integer()) :: non_neg_integer() | nil
  def prev_hunk_line(hunks, line) do
    hunks
    |> Enum.filter(fn h -> h.start_line < line end)
    |> List.last()
    |> case do
      nil -> nil
      hunk -> hunk.start_line
    end
  end

  @doc """
  Returns buffer lines with the given hunk reverted to base content.

  For added hunks: removes the added lines.
  For modified hunks: replaces with the old lines.
  For deleted hunks: re-inserts the old lines at the deletion point.
  """
  @spec revert_hunk([String.t()], hunk()) :: [String.t()]
  def revert_hunk(current_lines, %{type: :added, start_line: start, count: count}) do
    {before, rest} = Enum.split(current_lines, start)
    {_removed, after_} = Enum.split(rest, count)
    before ++ after_
  end

  def revert_hunk(current_lines, %{type: :modified, start_line: start, count: count} = hunk) do
    {before, rest} = Enum.split(current_lines, start)
    {_removed, after_} = Enum.split(rest, count)
    before ++ hunk.old_lines ++ after_
  end

  def revert_hunk(current_lines, %{type: :deleted, start_line: start} = hunk) do
    {before, after_} = Enum.split(current_lines, start)
    before ++ hunk.old_lines ++ after_
  end

  @doc """
  Generates a unified diff patch for a single hunk.

  The patch can be fed to `git apply --cached` to stage just this hunk.
  Uses the standard unified diff format with `a/` and `b/` path prefixes.
  """
  @spec generate_patch(String.t(), [String.t()], [String.t()], hunk()) :: String.t()
  def generate_patch(relative_path, base_lines, current_lines, hunk) do
    # Context lines around the hunk (standard 3 lines)
    ctx = 3

    {old_start, old_end} = base_range(hunk, length(base_lines), ctx)
    {new_start, new_end} = current_range(hunk, length(current_lines), ctx)

    old_context_lines = Enum.slice(base_lines, old_start..(old_end - 1)//1)
    new_context_lines = Enum.slice(current_lines, new_start..(new_end - 1)//1)

    # Build unified diff body
    diff_body = unified_diff_body(old_context_lines, new_context_lines)

    old_count = old_end - old_start
    new_count = new_end - new_start

    header = [
      "--- a/#{relative_path}\n",
      "+++ b/#{relative_path}\n",
      "@@ -#{old_start + 1},#{old_count} +#{new_start + 1},#{new_count} @@\n"
    ]

    IO.iodata_to_binary([header | diff_body])
  end

  # ── Private: hunk building ─────────────────────────────────────────────────

  @spec build_hunks([{atom(), [String.t()]}], non_neg_integer(), non_neg_integer(), [hunk()]) ::
          [hunk()]
  defp build_hunks([], _cur, _base, acc), do: acc

  defp build_hunks([{:eq, lines} | rest], cur, base, acc) do
    len = length(lines)
    build_hunks(rest, cur + len, base + len, acc)
  end

  # Delete followed by insert = modification
  defp build_hunks([{:del, del_lines}, {:ins, ins_lines} | rest], cur, base, acc) do
    hunk = %{
      type: :modified,
      start_line: cur,
      count: length(ins_lines),
      old_start: base,
      old_count: length(del_lines),
      old_lines: del_lines
    }

    build_hunks(rest, cur + length(ins_lines), base + length(del_lines), [hunk | acc])
  end

  # Pure deletion
  defp build_hunks([{:del, del_lines} | rest], cur, base, acc) do
    hunk = %{
      type: :deleted,
      start_line: cur,
      count: 0,
      old_start: base,
      old_count: length(del_lines),
      old_lines: del_lines
    }

    build_hunks(rest, cur, base + length(del_lines), [hunk | acc])
  end

  # Pure insertion
  defp build_hunks([{:ins, ins_lines} | rest], cur, base, acc) do
    hunk = %{
      type: :added,
      start_line: cur,
      count: length(ins_lines),
      old_start: base,
      old_count: 0,
      old_lines: []
    }

    build_hunks(rest, cur + length(ins_lines), base, [hunk | acc])
  end

  # ── Private: patch generation ──────────────────────────────────────────────

  @spec base_range(hunk(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp base_range(hunk, base_len, ctx) do
    start = max(0, hunk.old_start - ctx)
    end_ = min(base_len, hunk.old_start + hunk.old_count + ctx)
    {start, end_}
  end

  @spec current_range(hunk(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  defp current_range(hunk, cur_len, ctx) do
    start = max(0, hunk.start_line - ctx)
    end_ = min(cur_len, hunk.start_line + hunk.count + ctx)
    {start, end_}
  end

  @spec unified_diff_body([String.t()], [String.t()]) :: iodata()
  defp unified_diff_body(old_lines, new_lines) do
    List.myers_difference(old_lines, new_lines)
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &" #{&1}\n")
      {:del, lines} -> Enum.map(lines, &"-#{&1}\n")
      {:ins, lines} -> Enum.map(lines, &"+#{&1}\n")
    end)
  end
end
