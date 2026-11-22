defmodule Minga.Git.Change do
  @moduledoc false

  alias Minga.Core.Diff

  @stale_index "The Git index changed at the selected hunk; refresh the diff and try again."

  @spec lines(binary() | nil) :: [binary()]
  def lines(content) when content in [nil, ""], do: []
  def lines(content), do: :binary.split(content, "\n", [:global])

  @spec validate_path(binary()) :: :ok | {:error, String.t()}
  def validate_path(path) do
    if :binary.match(path, <<0>>) == :nomatch and
         Enum.all?(:binary.split(path, "/", [:global]), &(&1 not in ["", ".", ".."])) do
      :ok
    else
      {:error, "Expected a repository-relative Git file path."}
    end
  end

  @spec stale_index() :: {:error, String.t()}
  defp stale_index, do: {:error, @stale_index}

  @spec stage_result(binary() | nil, binary() | nil, Diff.hunk(), binary() | nil) ::
          {:ok, binary() | nil} | {:error, String.t()}
  def stage_result(base, _revised, _change, index) when is_nil(base) != is_nil(index),
    do: stale_index()

  def stage_result(base, revised, change, index) do
    %{old_start: start, old_count: old_count, old_lines: old_lines} = change

    with {:ok, new_lines} <- revised_lines(revised, change),
         index_lines = lines(index),
         {:ok, offset} <- index_offset(base, index, index_lines, change) do
      {before, from_change} = Enum.split(index_lines, start + offset)
      {removed, after_change} = Enum.split(from_change, old_count)

      if removed == old_lines and length(removed) == old_count do
        result = Enum.join(before ++ new_lines ++ after_change, "\n")
        {:ok, postimage(result, revised)}
      else
        stale_index()
      end
    end
  end

  @spec revised_lines(binary() | nil, Diff.hunk()) :: {:ok, [binary()]} | {:error, String.t()}
  defp revised_lines(revised, %{start_line: start, count: count}) do
    selected = Enum.slice(lines(revised), start, count)

    if length(selected) == count do
      {:ok, selected}
    else
      {:error, "The selected change does not match the revised text."}
    end
  end

  @spec postimage(binary(), binary() | nil) :: binary() | nil
  defp postimage("", nil), do: nil
  defp postimage(result, _revised), do: result

  @spec index_offset(binary() | nil, binary() | nil, [binary()], Diff.hunk()) ::
          {:ok, integer()} | {:error, String.t()}
  defp index_offset(base, base, _index_lines, _change), do: {:ok, 0}

  defp index_offset(base, _index, index_lines, change) do
    %{old_start: start, old_count: count, old_lines: old_lines} = change
    base_lines = lines(base)

    if Enum.slice(base_lines, start, count) == old_lines do
      base_lines |> Diff.diff_lines(index_lines) |> staged_offset(start, count)
    else
      stale_index()
    end
  end

  @spec staged_offset([Diff.hunk()], non_neg_integer(), non_neg_integer()) ::
          {:ok, integer()} | {:error, String.t()}
  defp staged_offset(changes, start, count) do
    Enum.reduce_while(changes, {:ok, 0}, fn staged, {:ok, offset} ->
      staged_start = staged.old_start
      staged_end = staged_start + staged.old_count

      cond do
        staged_start == start -> {:halt, stale_index()}
        staged_end <= start -> {:cont, {:ok, offset + staged.count - staged.old_count}}
        start + count <= staged_start -> {:halt, {:ok, offset}}
        true -> {:halt, stale_index()}
      end
    end)
  end

  @spec patch(binary(), binary() | nil, binary() | nil, binary() | nil) :: iodata()
  def patch(path, index, result, mode) do
    old_path = quote_path("a/" <> path)
    new_path = quote_path("b/" <> path)

    headers =
      case {index, result} do
        {nil, _} ->
          ["new file mode 100644\n", "--- /dev/null\n", "+++ ", new_path, "\n"]

        {_, nil} when is_binary(mode) ->
          ["deleted file mode ", mode, "\n--- ", old_path, "\n+++ /dev/null\n"]

        _ when is_binary(mode) ->
          ["old mode ", mode, "\n--- ", old_path, "\n+++ ", new_path, "\n"]
      end

    {old_count, old_lines} = patch_lines(index || "", ?-)
    {new_count, new_lines} = patch_lines(result || "", ?+)

    # One full-range hunk, without trailing context or --unidiff-zero, makes
    # Git match *both* ends of the index preimage while holding its index lock.
    # It cannot relocate a repeated line or overwrite a concurrent index edit.
    # The postimage differs by only the selected change, based on the live index.
    [
      "diff --git ",
      old_path,
      " ",
      new_path,
      "\n",
      headers,
      "@@ -",
      range(old_count),
      " +",
      range(new_count),
      " @@\n",
      old_lines,
      new_lines
    ]
  end

  @spec range(non_neg_integer()) :: iodata()
  defp range(0), do: "0,0"
  defp range(count), do: ["1,", Integer.to_string(count)]

  @spec patch_lines(binary(), byte()) :: {non_neg_integer(), iodata()}
  defp patch_lines(content, prefix) do
    content
    |> :binary.split("\n", [:global])
    |> patch_lines(prefix, 0, [])
  end

  @spec patch_lines([binary()], byte(), non_neg_integer(), [iodata()]) ::
          {non_neg_integer(), iodata()}
  defp patch_lines([""], _prefix, count, acc), do: {count, Enum.reverse(acc)}

  defp patch_lines([line], prefix, count, acc) do
    final = [prefix, line, "\n\\ No newline at end of file\n"]
    {count + 1, Enum.reverse(acc, [final])}
  end

  defp patch_lines([line | rest], prefix, count, acc) do
    patch_lines(rest, prefix, count + 1, [[prefix, line, ?\n] | acc])
  end

  @spec quote_path(binary()) :: iodata()
  defp quote_path(path) do
    quoted =
      for <<byte <- path>> do
        case byte do
          byte when byte in [?", ?\\] -> [?\\, byte]
          byte when byte in 32..126 -> byte
          byte -> [?\\, ?0 + div(byte, 64), ?0 + rem(div(byte, 8), 8), ?0 + rem(byte, 8)]
        end
      end

    [?", quoted, ?"]
  end
end
