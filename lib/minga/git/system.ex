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
  @spec show_staged(String.t(), String.t()) :: {:ok, String.t()} | :error
  def show_staged(git_root, relative_path)
      when is_binary(git_root) and is_binary(relative_path) do
    case System.cmd("git", ["show", ":#{relative_path}"],
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
    case System.cmd("git", ["status", "--porcelain=v2", "-z", "-uall"],
           cd: git_root,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, parse_status_output(output)}

      {output, _} ->
        {:error, "git status failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git status error: #{Exception.message(e)}"}
  end

  @impl true
  @spec diff(String.t(), Minga.Git.diff_opts()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(git_root, opts \\ []) when is_binary(git_root) do
    with :ok <- Minga.Git.DiffOptions.validate(opts) do
      args = diff_args(opts)

      case System.cmd("git", args, cd: git_root, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _} -> {:error, "git diff failed: #{String.trim(output)}"}
      end
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git diff error: #{Exception.message(e)}"}
  end

  @spec diff_args(keyword()) :: [String.t()]
  defp diff_args(opts) do
    case Keyword.get(opts, :commit) do
      nil -> working_tree_diff_args(opts)
      commit -> commit_diff_args(commit, Keyword.get(opts, :path))
    end
  end

  @spec working_tree_diff_args(keyword()) :: [String.t()]
  defp working_tree_diff_args(opts) do
    path = Keyword.get(opts, :path)
    staged = Keyword.get(opts, :staged, false)

    args = ["diff"]
    args = if staged, do: args ++ ["--cached"], else: args
    if path, do: args ++ ["--", path], else: args
  end

  @spec commit_diff_args(String.t(), String.t() | nil) :: [String.t()]
  defp commit_diff_args(commit, nil), do: ["show", commit, "--format=", "--patch"]

  defp commit_diff_args(commit, path), do: ["show", commit, "--format=", "--patch", "--", path]

  @impl true
  @spec log(String.t(), keyword()) :: {:ok, [Minga.Git.log_entry()]} | {:error, String.t()}
  def log(git_root, opts \\ []) when is_binary(git_root) do
    count = Keyword.get(opts, :count, 10)
    path = Keyword.get(opts, :path)

    format = "%H%x1f%h%x1f%an%x1f%cr%x1f%s"
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
  @spec commit(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def commit(git_root, message, opts \\ [])
      when is_binary(git_root) and is_binary(message) do
    args = ["commit", "-m", message]
    args = if Keyword.get(opts, :amend, false), do: args ++ ["--amend"], else: args

    case System.cmd("git", args, cd: git_root, stderr_to_stdout: true) do
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

  @impl true
  @spec last_commit_message(String.t()) :: {:ok, String.t()} | :error
  def last_commit_message(git_root) when is_binary(git_root) do
    case System.cmd("git", ["log", "-1", "--format=%B"], cd: git_root, stderr_to_stdout: true) do
      {msg, 0} -> {:ok, String.trim(msg)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @impl true
  @spec ahead_behind(String.t()) :: {:ok, non_neg_integer(), non_neg_integer()} | :error
  def ahead_behind(git_root) when is_binary(git_root) do
    case System.cmd("git", ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
           cd: git_root,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.split(String.trim(output), "\t") do
          [ahead_str, behind_str] ->
            {ahead, _} = Integer.parse(ahead_str)
            {behind, _} = Integer.parse(behind_str)
            {:ok, ahead, behind}

          _ ->
            :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  @impl true
  @spec unstage(String.t(), String.t() | [String.t()]) :: :ok | {:error, String.t()}
  def unstage(git_root, path) when is_binary(git_root) and is_binary(path) do
    unstage(git_root, [path])
  end

  def unstage(git_root, paths) when is_binary(git_root) and is_list(paths) do
    args = ["reset", "HEAD", "--"] ++ paths

    case System.cmd("git", args, cd: git_root, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git reset failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git reset error: #{Exception.message(e)}"}
  end

  @impl true
  @spec unstage_all(String.t()) :: :ok | {:error, String.t()}
  def unstage_all(git_root) when is_binary(git_root) do
    case System.cmd("git", ["reset", "HEAD"], cd: git_root, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git reset failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git reset error: #{Exception.message(e)}"}
  end

  @impl true
  @spec discard(String.t(), String.t()) :: :ok | {:error, String.t()}
  def discard(git_root, path) when is_binary(git_root) and is_binary(path) do
    abs_path = Path.join(git_root, path)

    # Check if the file is tracked by git
    case System.cmd("git", ["ls-files", "--error-unmatch", path],
           cd: git_root,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        # Tracked file: restore from index/HEAD
        case System.cmd("git", ["checkout", "--", path],
               cd: git_root,
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {output, _} -> {:error, "git checkout failed: #{String.trim(output)}"}
        end

      _ ->
        # Untracked file: delete it
        case File.rm(abs_path) do
          :ok -> :ok
          {:error, reason} -> {:error, "Failed to remove #{path}: #{inspect(reason)}"}
        end
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git discard error: #{Exception.message(e)}"}
  end

  @impl true
  @spec branch_list(String.t()) :: {:ok, [Minga.Git.BranchInfo.t()]} | {:error, String.t()}
  def branch_list(git_root) when is_binary(git_root) do
    format = "%(refname:short)%09%(upstream:short)%09%(upstream:track)%09%(HEAD)"

    case System.cmd("git", ["branch", "-a", "--format=#{format}"],
           cd: git_root,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        branches =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_branch_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, branches}

      {output, _} ->
        {:error, "git branch failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git branch error: #{Exception.message(e)}"}
  end

  @impl true
  @spec branch_create(String.t(), String.t()) :: :ok | {:error, String.t()}
  def branch_create(git_root, name) when is_binary(git_root) and is_binary(name) do
    case System.cmd("git", ["checkout", "-b", name], cd: git_root, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git checkout -b failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] ->
      {:error, "git branch create error: #{Exception.message(e)}"}
  end

  @impl true
  @spec branch_switch(String.t(), String.t()) :: :ok | {:error, String.t()}
  def branch_switch(git_root, name) when is_binary(git_root) and is_binary(name) do
    case System.cmd("git", ["checkout", name], cd: git_root, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git checkout failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] ->
      {:error, "git branch switch error: #{Exception.message(e)}"}
  end

  @impl true
  @spec branch_delete(String.t(), String.t(), boolean()) :: :ok | {:error, String.t()}
  def branch_delete(git_root, name, force \\ false)
      when is_binary(git_root) and is_binary(name) do
    flag = if force, do: "-D", else: "-d"

    case System.cmd("git", ["branch", flag, name], cd: git_root, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git branch delete failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] ->
      {:error, "git branch delete error: #{Exception.message(e)}"}
  end

  @impl true
  @spec stash(String.t(), keyword()) :: :ok | {:error, String.t()}
  def stash(git_root, opts \\ []) when is_binary(git_root) do
    args = ["stash", "push"]

    args =
      if Keyword.get(opts, :include_untracked, false),
        do: args ++ ["--include-untracked"],
        else: args

    case System.cmd("git", args, cd: git_root, stderr_to_stdout: true) do
      {output, 0} ->
        case String.trim(output) do
          "No local changes to save" -> {:error, "No changes to stash"}
          _ -> :ok
        end

      {output, _} ->
        {:error, "git stash failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git stash error: #{Exception.message(e)}"}
  end

  @impl true
  @spec stash_pop(String.t()) :: :ok | {:error, String.t()}
  def stash_pop(git_root) when is_binary(git_root) do
    case System.cmd("git", ["stash", "pop"], cd: git_root, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git stash pop failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git stash pop error: #{Exception.message(e)}"}
  end

  @impl true
  @spec stash_list(String.t()) :: {:ok, [Minga.Git.stash_entry()]} | {:error, String.t()}
  def stash_list(git_root) when is_binary(git_root) do
    format = "%gd%x1f%cr%x1f%gs"

    case System.cmd("git", ["stash", "list", "--format=#{format}"],
           cd: git_root,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        entries =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&parse_stash_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, entries}

      {output, _} ->
        {:error, "git stash list failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git stash list error: #{Exception.message(e)}"}
  end

  @impl true
  @spec stash_drop(String.t(), non_neg_integer()) :: :ok | {:error, String.t()}
  def stash_drop(git_root, index) when is_binary(git_root) and is_integer(index) and index >= 0 do
    case System.cmd("git", ["stash", "drop", "stash@{#{index}}"],
           cd: git_root,
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git stash drop failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git stash drop error: #{Exception.message(e)}"}
  end

  @impl true
  @spec push(String.t(), keyword()) :: :ok | {:error, String.t()}
  def push(git_root, opts \\ []) when is_binary(git_root) do
    args = ["push"]
    args = if Keyword.get(opts, :set_upstream), do: args ++ ["--set-upstream"], else: args
    args = if Keyword.get(opts, :force), do: args ++ ["--force-with-lease"], else: args

    case System.cmd("git", args, cd: git_root, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git push failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git push error: #{Exception.message(e)}"}
  end

  @impl true
  @spec pull(String.t(), keyword()) :: :ok | {:error, String.t()}
  def pull(git_root, opts \\ []) when is_binary(git_root) do
    args = ["pull"]
    args = if Keyword.get(opts, :rebase), do: args ++ ["--rebase"], else: args

    case System.cmd("git", args, cd: git_root, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git pull failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git pull error: #{Exception.message(e)}"}
  end

  @impl true
  @spec fetch_remotes(String.t(), keyword()) :: :ok | {:error, String.t()}
  def fetch_remotes(git_root, _opts \\ []) when is_binary(git_root) do
    case System.cmd("git", ["fetch", "--all"], cd: git_root, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git fetch failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git fetch error: #{Exception.message(e)}"}
  end

  @impl true
  @spec current_branch(String.t()) :: {:ok, String.t()} | :error
  def current_branch(git_root) when is_binary(git_root) do
    # Read .git/HEAD directly to avoid spawning a subprocess.
    # Called at Git.Buffer init and on save (invalidate_base), not per-frame.
    head_path = Path.join(git_root, ".git/HEAD")

    case File.read(head_path) do
      {:ok, "ref: refs/heads/" <> branch} ->
        {:ok, String.trim(branch)}

      {:ok, _detached} ->
        # Detached HEAD: fall back to git CLI for the short SHA
        case System.cmd("git", ["rev-parse", "--short", "HEAD"],
               cd: git_root,
               stderr_to_stdout: true
             ) do
          {output, 0} -> {:ok, String.trim(output)}
          _ -> :error
        end

      {:error, _} ->
        :error
    end
  rescue
    _ -> :error
  end

  # ── Private ────────────────────────────────────────────────────────────────

  alias Minga.Git.StatusEntry

  @doc false
  @spec parse_status_output(String.t()) :: [Minga.Git.status_entry()]
  def parse_status_output(output) when is_binary(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> parse_status_tokens()
  end

  @spec parse_status_tokens([String.t()]) :: [Minga.Git.status_entry()]
  defp parse_status_tokens([]), do: []

  defp parse_status_tokens(["2 " <> _ = record, _old_path | rest]) do
    # Porcelain v2 `-z` emits rename/copy records as the new path in the main record.
    # The following token is the old path; StatusEntry intentionally keeps only the current path.
    parse_status_record(record) ++ parse_status_tokens(rest)
  end

  defp parse_status_tokens([record | rest]) do
    parse_status_record(record) ++ parse_status_tokens(rest)
  end

  @spec parse_status_record(String.t()) :: [Minga.Git.status_entry()]
  defp parse_status_record("1 " <> _ = record), do: parse_tracked_status_record(record)

  defp parse_status_record("2 " <> _ = record), do: parse_renamed_or_copied_status_record(record)

  defp parse_status_record("u " <> _ = record), do: parse_unmerged_status_record(record)

  defp parse_status_record("? " <> path),
    do: [%StatusEntry{path: path, status: :untracked, staged: false}]

  defp parse_status_record(_), do: []

  @spec parse_tracked_status_record(String.t()) :: [Minga.Git.status_entry()]
  defp parse_tracked_status_record(record) do
    case String.split(record, " ", parts: 9) do
      ["1", xy, _sub, _mode_head, _mode_index, _mode_worktree, _head_hash, _index_hash, path] ->
        interpret_status_codes(status_code_at(xy, 0), status_code_at(xy, 1), path)

      _ ->
        []
    end
  end

  @spec parse_renamed_or_copied_status_record(String.t()) :: [Minga.Git.status_entry()]
  defp parse_renamed_or_copied_status_record(record) do
    case String.split(record, " ", parts: 10) do
      [
        "2",
        xy,
        _sub,
        _mode_head,
        _mode_index,
        _mode_worktree,
        _head_hash,
        _index_hash,
        _score,
        path
      ] ->
        interpret_status_codes(status_code_at(xy, 0), status_code_at(xy, 1), path)

      _ ->
        []
    end
  end

  @spec parse_unmerged_status_record(String.t()) :: [Minga.Git.status_entry()]
  defp parse_unmerged_status_record(record) do
    case String.split(record, " ", parts: 11) do
      [
        "u",
        _xy,
        _sub,
        _mode_stage1,
        _mode_stage2,
        _mode_stage3,
        _mode_worktree,
        _hash_stage1,
        _hash_stage2,
        _hash_stage3,
        path
      ] ->
        [%StatusEntry{path: path, status: :conflict, staged: false}]

      _ ->
        []
    end
  end

  @spec status_code_at(String.t(), 0 | 1) :: String.t()
  defp status_code_at(xy, index) do
    xy
    |> String.at(index)
    |> normalize_status_code()
  end

  @spec normalize_status_code(String.t() | nil) :: String.t()
  defp normalize_status_code("."), do: " "
  defp normalize_status_code(nil), do: " "
  defp normalize_status_code(code), do: code

  @spec interpret_status_codes(String.t(), String.t(), String.t()) :: [Minga.Git.status_entry()]
  # Conflict/unmerged states
  defp interpret_status_codes("U", _, path),
    do: [%StatusEntry{path: path, status: :conflict, staged: false}]

  defp interpret_status_codes(_, "U", path),
    do: [%StatusEntry{path: path, status: :conflict, staged: false}]

  defp interpret_status_codes("D", "D", path),
    do: [%StatusEntry{path: path, status: :conflict, staged: false}]

  defp interpret_status_codes("A", "A", path),
    do: [%StatusEntry{path: path, status: :conflict, staged: false}]

  # Untracked
  defp interpret_status_codes("?", "?", path),
    do: [%StatusEntry{path: path, status: :untracked, staged: false}]

  # Both staged and worktree changes: produce two entries
  defp interpret_status_codes("M", "M", path) do
    [
      %StatusEntry{path: path, status: :modified, staged: true},
      %StatusEntry{path: path, status: :modified, staged: false}
    ]
  end

  defp interpret_status_codes("M", "D", path) do
    [
      %StatusEntry{path: path, status: :modified, staged: true},
      %StatusEntry{path: path, status: :deleted, staged: false}
    ]
  end

  defp interpret_status_codes("A", "M", path) do
    [
      %StatusEntry{path: path, status: :added, staged: true},
      %StatusEntry{path: path, status: :modified, staged: false}
    ]
  end

  defp interpret_status_codes("A", "D", path) do
    [
      %StatusEntry{path: path, status: :added, staged: true},
      %StatusEntry{path: path, status: :deleted, staged: false}
    ]
  end

  # Staged only (index has changes, worktree clean)
  defp interpret_status_codes("A", " ", path),
    do: [%StatusEntry{path: path, status: :added, staged: true}]

  defp interpret_status_codes("M", " ", path),
    do: [%StatusEntry{path: path, status: :modified, staged: true}]

  defp interpret_status_codes("D", " ", path),
    do: [%StatusEntry{path: path, status: :deleted, staged: true}]

  defp interpret_status_codes("R", " ", path),
    do: [%StatusEntry{path: path, status: :renamed, staged: true}]

  defp interpret_status_codes("C", " ", path),
    do: [%StatusEntry{path: path, status: :copied, staged: true}]

  defp interpret_status_codes("R", _, path),
    do: [%StatusEntry{path: path, status: :renamed, staged: true}]

  defp interpret_status_codes("C", _, path),
    do: [%StatusEntry{path: path, status: :copied, staged: true}]

  # Worktree changes only
  defp interpret_status_codes(" ", "M", path),
    do: [%StatusEntry{path: path, status: :modified, staged: false}]

  defp interpret_status_codes(" ", "D", path),
    do: [%StatusEntry{path: path, status: :deleted, staged: false}]

  defp interpret_status_codes(idx, wt, path) do
    Minga.Log.warning(
      :editor,
      "[Git] unexpected status codes: index=#{inspect(idx)} worktree=#{inspect(wt)}"
    )

    [%StatusEntry{path: path, status: :unknown, staged: false}]
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

  @spec parse_stash_line(String.t()) :: Minga.Git.stash_entry() | nil
  defp parse_stash_line(line) do
    case String.split(line, <<0x1F>>) do
      [ref, date, message] -> build_stash_entry(stash_index(ref), ref, date, message)
      _ -> nil
    end
  end

  @spec build_stash_entry({:ok, non_neg_integer()} | :error, String.t(), String.t(), String.t()) ::
          Minga.Git.stash_entry() | nil
  defp build_stash_entry({:ok, index}, ref, date, message) do
    %Minga.Git.StashEntry{index: index, ref: ref, date: date, message: message}
  end

  defp build_stash_entry(:error, _ref, _date, _message), do: nil

  @spec stash_index(String.t()) :: {:ok, non_neg_integer()} | :error
  defp stash_index(ref) do
    case Regex.run(~r/stash@\{(\d+)\}/, ref) do
      [_, index] -> {:ok, String.to_integer(index)}
      _ -> :error
    end
  end

  @spec parse_branch_line(String.t()) :: Minga.Git.BranchInfo.t() | nil
  defp parse_branch_line("origin/HEAD\t" <> _), do: nil

  defp parse_branch_line(line) do
    case String.split(line, "\t") do
      [name, upstream, track, head_marker] ->
        remote = String.starts_with?(name, "origin/")
        current = String.trim(head_marker) == "*"
        upstream = if upstream == "", do: nil, else: upstream
        {ahead, behind} = parse_track_info(track)

        %Minga.Git.BranchInfo{
          name: name,
          current: current,
          upstream: upstream,
          remote: remote,
          ahead: ahead,
          behind: behind
        }

      _ ->
        nil
    end
  end

  @spec parse_track_info(String.t()) :: {non_neg_integer() | nil, non_neg_integer() | nil}
  defp parse_track_info(""), do: {nil, nil}

  defp parse_track_info(track) do
    ahead =
      case Regex.run(~r/ahead (\d+)/, track) do
        [_, n] -> String.to_integer(n)
        _ -> nil
      end

    behind =
      case Regex.run(~r/behind (\d+)/, track) do
        [_, n] -> String.to_integer(n)
        _ -> nil
      end

    {ahead, behind}
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
