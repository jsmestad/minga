defmodule Minga.Git.System do
  @moduledoc """
  Git backend that shells out to the `git` CLI.

  This is the default (production) implementation of `Minga.Git.Backend`.
  Every function spawns a short-lived OS process via `System.cmd/3`.
  """

  @behaviour Minga.Git.Backend

  @cmd_timeout 5_000

  @impl true
  @spec root_for(String.t()) :: {:ok, String.t()} | :not_git
  def root_for(path) when is_binary(path) do
    dir = if File.dir?(path), do: path, else: Path.dirname(path)

    case System.cmd("git", ["rev-parse", "--show-toplevel"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> :not_git
    end
  rescue
    _ -> :not_git
  end

  @impl true
  @spec show_head(String.t(), String.t()) :: {:ok, String.t()} | :error
  def show_head(git_root, relative_path) when is_binary(git_root) and is_binary(relative_path) do
    case System.cmd("git", ["show", "HEAD:#{relative_path}"],
           cd: git_root,
           stderr_to_stdout: true
         ) do
      {content, 0} -> {:ok, content}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @impl true
  @spec stage_patch(String.t(), String.t()) :: :ok | {:error, String.t()}
  def stage_patch(git_root, patch) when is_binary(git_root) and is_binary(patch) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable("git") |> String.to_charlist()},
        [
          {:args, ~w[apply --cached -]},
          {:cd, String.to_charlist(git_root)},
          :binary,
          :exit_status,
          :use_stdio
        ]
      )

    Port.command(port, patch)
    Port.command(port, "")
    send(port, {self(), :close})

    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, _code}} -> {:error, "git apply failed"}
    after
      @cmd_timeout -> {:error, "git apply timed out"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  @spec blame_line(String.t(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | :error
  def blame_line(git_root, relative_path, line_number)
      when is_binary(git_root) and is_binary(relative_path) and is_integer(line_number) do
    line_1 = line_number + 1

    case System.cmd(
           "git",
           ["blame", "-L", "#{line_1},#{line_1}", "--porcelain", relative_path],
           cd: git_root,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, parse_porcelain_blame(output)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @impl true
  @spec status(String.t()) :: {:ok, [Minga.Git.status_entry()]} | {:error, String.t()}
  def status(git_root) when is_binary(git_root) do
    case System.cmd("git", ["status", "--porcelain=v1", "-uall"],
           cd: git_root,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        entries =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_status_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {output, _} ->
        {:error, "git status failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git status error: #{Exception.message(e)}"}
  end

  @impl true
  @spec diff(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(git_root, opts \\ []) when is_binary(git_root) do
    path = Keyword.get(opts, :path)
    staged = Keyword.get(opts, :staged, false)

    args = ["diff"]
    args = if staged, do: args ++ ["--cached"], else: args
    args = if path, do: args ++ ["--", path], else: args

    case System.cmd("git", args, cd: git_root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, "git diff failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git diff error: #{Exception.message(e)}"}
  end

  @impl true
  @spec log(String.t(), keyword()) :: {:ok, [Minga.Git.log_entry()]} | {:error, String.t()}
  def log(git_root, opts \\ []) when is_binary(git_root) do
    count = Keyword.get(opts, :count, 10)
    path = Keyword.get(opts, :path)

    format = "%H%x1f%h%x1f%an%x1f%ai%x1f%s"
    args = ["log", "--format=#{format}", "-n", "#{count}"]
    args = if path, do: args ++ ["--", path], else: args

    case System.cmd("git", args, cd: git_root, stderr_to_stdout: true) do
      {output, 0} ->
        entries =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_log_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {output, _} ->
        {:error, "git log failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git log error: #{Exception.message(e)}"}
  end

  @impl true
  @spec stage(String.t(), String.t() | [String.t()]) :: :ok | {:error, String.t()}
  def stage(git_root, path) when is_binary(git_root) and is_binary(path) do
    stage(git_root, [path])
  end

  def stage(git_root, paths) when is_binary(git_root) and is_list(paths) do
    args = ["add", "--"] ++ paths

    case System.cmd("git", args, cd: git_root, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git add failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git add error: #{Exception.message(e)}"}
  end

  @impl true
  @spec commit(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def commit(git_root, message) when is_binary(git_root) and is_binary(message) do
    case System.cmd("git", ["commit", "-m", message],
           cd: git_root,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        short_hash =
          case Regex.run(~r"\[[\w/.-]+ ([a-f0-9]+)\]", output) do
            [_, hash] -> hash
            _ -> "unknown"
          end

        {:ok, short_hash}

      {output, _} ->
        {:error, "git commit failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git commit error: #{Exception.message(e)}"}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  alias Minga.Git.StatusEntry

  @spec parse_status_line(String.t()) :: Minga.Git.status_entry() | nil
  defp parse_status_line(line) when byte_size(line) >= 3 do
    index_status = String.at(line, 0)
    worktree_status = String.at(line, 1)
    path = String.trim(String.slice(line, 3..-1//1))

    {status, staged} = interpret_status_codes(index_status, worktree_status)
    %StatusEntry{path: path, status: status, staged: staged}
  end

  defp parse_status_line(_), do: nil

  @spec interpret_status_codes(String.t(), String.t()) :: {atom(), boolean()}
  # Conflict/unmerged states
  defp interpret_status_codes("U", _), do: {:conflict, false}
  defp interpret_status_codes(_, "U"), do: {:conflict, false}
  defp interpret_status_codes("D", "D"), do: {:conflict, false}
  defp interpret_status_codes("A", "A"), do: {:conflict, false}
  # Untracked
  defp interpret_status_codes("?", "?"), do: {:untracked, false}
  # Staged (index has changes)
  defp interpret_status_codes("A", _), do: {:added, true}
  defp interpret_status_codes("M", _), do: {:modified, true}
  defp interpret_status_codes("D", _), do: {:deleted, true}
  defp interpret_status_codes("R", _), do: {:renamed, true}
  defp interpret_status_codes("C", _), do: {:copied, true}
  # Worktree changes
  defp interpret_status_codes(" ", "M"), do: {:modified, false}
  defp interpret_status_codes(" ", "D"), do: {:deleted, false}

  defp interpret_status_codes(idx, wt) do
    Minga.Log.warning(
      :editor,
      "[Git] unexpected status codes: index=#{inspect(idx)} worktree=#{inspect(wt)}"
    )

    {:unknown, false}
  end

  @spec parse_log_line(String.t()) :: Minga.Git.log_entry() | nil
  defp parse_log_line(line) do
    case String.split(line, <<0x1F>>) do
      [hash, short_hash, author, date, message] ->
        %Minga.Git.LogEntry{
          hash: hash,
          short_hash: short_hash,
          author: author,
          date: date,
          message: message
        }

      _ ->
        nil
    end
  end

  @spec parse_porcelain_blame(String.t()) :: String.t()
  defp parse_porcelain_blame(output) do
    lines = String.split(output, "\n")

    author =
      lines
      |> Enum.find_value("unknown", fn
        "author " <> name -> name
        _ -> nil
      end)

    summary =
      lines
      |> Enum.find_value("", fn
        "summary " <> msg -> msg
        _ -> nil
      end)

    date =
      lines
      |> Enum.find_value("", fn
        "author-time " <> ts ->
          case Integer.parse(ts) do
            {unix, _} ->
              DateTime.from_unix!(unix) |> Calendar.strftime("%Y-%m-%d")

            _ ->
              ""
          end

        _ ->
          nil
      end)

    "#{author} (#{date}): #{summary}"
  end
end
