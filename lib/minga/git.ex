defmodule Minga.Git do
  @moduledoc """
  Git utility functions for interacting with the git CLI.

  All functions shell out to `git` with timeouts and error handling.
  These are called infrequently (buffer open, index change, hunk ops)
  so the process spawn overhead is acceptable.
  """

  @cmd_timeout 5_000

  @doc """
  Finds the git repository root for a file path.

  Returns `{:ok, root_path}` if the file is inside a git repo, or
  `:not_git` if it isn't.
  """
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

  @doc """
  Reads the HEAD version of a file from git.

  Returns `{:ok, content}` with the file content at HEAD, or `:error`
  if the file doesn't exist in HEAD (new file, not tracked, etc.).
  """
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

  @doc """
  Applies a unified diff patch to the git index (staging area).

  The patch is piped to `git apply --cached` via stdin.
  """
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

  @doc """
  Gets blame information for a specific line of a file.

  Returns `{:ok, blame_text}` with a human-readable blame string,
  or `:error` if blame fails.
  """
  @spec blame_line(String.t(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | :error
  def blame_line(git_root, relative_path, line_number)
      when is_binary(git_root) and is_binary(relative_path) and is_integer(line_number) do
    # git blame uses 1-indexed line numbers
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

  @doc """
  Returns the path of a file relative to the git root.
  """
  @spec relative_path(String.t(), String.t()) :: String.t()
  def relative_path(git_root, file_path) do
    Path.relative_to(Path.expand(file_path), Path.expand(git_root))
  end

  # ── Private ────────────────────────────────────────────────────────────────

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
