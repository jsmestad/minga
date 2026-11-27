defmodule Minga.Git.System do
  @moduledoc """
  Git backend that shells out to the `git` CLI.

  This is the default (production) implementation of `Minga.Git.Backend`.
  Every function spawns a short-lived OS process through a timeout-bounded helper.
  """

  @behaviour Minga.Git.Backend

  alias Minga.Git.Change
  alias Minga.Git.Metadata
  alias Minga.Git.ReviewIdentity

  @cmd_timeout 5_000
  @typep review_transition :: {String.t() | :unborn, String.t()}
  @default_timeout_ms 2_000
  @status_timeout_ms 2_000

  @impl true
  @spec root_for(String.t()) :: {:ok, String.t()} | :not_git
  def root_for(path) when is_binary(path) do
    dir = if File.dir?(path), do: path, else: Path.dirname(path)

    case git_cmd(["rev-parse", "--show-toplevel"],
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
    case git_cmd(["show", "HEAD:#{relative_path}", "--"],
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
    case git_cmd(["show", ":0:#{relative_path}", "--"],
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
  @spec index_blob(String.t(), String.t()) :: {:ok, binary() | nil} | {:error, String.t()}
  def index_blob(git_root, relative_path) do
    with :ok <- Change.validate_path(relative_path),
         {:ok, content, _mode} <- read_index_entry(git_root, relative_path) do
      {:ok, content}
    end
  end

  @impl true
  @spec stage_patch(String.t(), String.t()) :: :ok | {:error, String.t()}
  def stage_patch(git_root, patch) when is_binary(git_root) and is_binary(patch) do
    apply_cached_patch(git_root, patch, ["apply", "--cached"])
  end

  @impl true
  @spec stage_change(String.t(), String.t(), binary() | nil, binary() | nil, Minga.Git.change()) ::
          :ok | {:error, String.t()}
  def stage_change(git_root, relative_path, base, revised, change) do
    with :ok <- Change.validate_path(relative_path),
         {:ok, index, mode} <- read_index_entry(git_root, relative_path),
         {:ok, result} <- Change.stage_result(base, revised, change, index) do
      if result == index do
        :ok
      else
        patch = Change.patch(relative_path, index, result, mode)
        args = ["-c", "apply.ignoreWhitespace=no", "apply", "--cached", "--whitespace=nowarn"]
        apply_cached_patch(git_root, patch, args)
      end
    end
  end

  @spec read_index_entry(String.t(), String.t()) ::
          {:ok, binary() | nil, binary() | nil} | {:error, String.t()}
  defp read_index_entry("", _path), do: {:error, "Expected a Git repository root."}

  defp read_index_entry(git_root, path) do
    args = ["-C", git_root, "--literal-pathspecs", "ls-files", "--stage", "-z", "--", path]

    case git_cmd(args, []) do
      {output, 0} ->
        read_stage_zero(git_root, path, output)

      {output, _} ->
        {:error, "Could not read the Git index: #{String.trim(output)}"}
    end
  end

  @spec read_stage_zero(String.t(), String.t(), binary()) ::
          {:ok, binary() | nil, binary() | nil} | {:error, String.t()}
  defp read_stage_zero(git_root, path, output) do
    # A literal directory pathspec also selects its descendants.
    entries =
      for entry <- :binary.split(output, <<0>>, [:global, :trim]),
          [metadata, ^path] <- [:binary.split(entry, "\t")],
          do: metadata

    with [metadata] <- entries,
         [mode, oid, "0"] when mode in ["100644", "100755"] <-
           :binary.split(metadata, " ", [:global]) do
      case git_cmd(["-C", git_root, "cat-file", "blob", oid], []) do
        {content, 0} -> {:ok, content, mode}
        {reason, _} -> {:error, "Could not read the Git index blob: #{String.trim(reason)}"}
      end
    else
      [] -> {:ok, nil, nil}
      _ -> {:error, "The Git index path is unmerged or is not a regular file."}
    end
  end

  @spec apply_cached_patch(String.t(), iodata(), [String.t()]) :: :ok | {:error, String.t()}
  defp apply_cached_patch(git_root, patch, args) do
    with tmp when is_binary(tmp) <- System.tmp_dir(),
         suffix <- Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
         dir <- Path.join(tmp, "minga-git-apply-#{suffix}"),
         :ok <- File.mkdir(dir),
         :ok <- apply_from_temp_dir(git_root, dir, patch, args) do
      :ok
    else
      nil ->
        {:error, "Could not find a temporary directory for the Git patch."}

      {:error, reason} when is_atom(reason) ->
        {:error, "Could not write the temporary Git patch: #{:file.format_error(reason)}"}

      {:error, _} = error ->
        error
    end
  end

  @spec apply_from_temp_dir(String.t(), String.t(), iodata(), [String.t()]) ::
          :ok | {:error, String.t() | File.posix()}
  defp apply_from_temp_dir(git_root, dir, patch, args) do
    path = Path.join(dir, "change.patch")

    try do
      with :ok <- File.chmod(dir, 0o700),
           :ok <- File.write(path, patch, [:binary, :exclusive]) do
        case git_cmd(args ++ ["--", path], cd: git_root, timeout_ms: @cmd_timeout) do
          {_output, 0} -> :ok
          {output, _} -> {:error, "git apply failed: #{String.trim(output)}"}
        end
      end
    after
      File.rm(path)
      File.rmdir(dir)
    end
  end

  @impl true
  @spec blame_line(String.t(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | :error
  def blame_line(git_root, relative_path, line_number)
      when is_binary(git_root) and is_binary(relative_path) and is_integer(line_number) do
    line_1 = line_number + 1

    case git_cmd(
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
  @spec status(String.t(), Minga.Git.status_opts()) ::
          {:ok, [Minga.Git.status_entry()]} | {:error, String.t()}
  def status(git_root, opts \\ []) when is_binary(git_root) and is_list(opts) do
    mode = Keyword.get(opts, :untracked_mode, :normal)
    timeout_ms = Keyword.get(opts, :timeout_ms, @status_timeout_ms)

    # `--no-optional-locks` keeps status from taking `.git/index.lock` to refresh
    # the stat cache. Status is a read that can run concurrently with a worktree
    # mutation (stage/discard); without this it can contend with the writer's lock.
    # Worktree writes are serialized among themselves elsewhere (the editor's
    # :git_worktree async lane); this makes the read side lock-free too.
    case git_cmd(["--no-optional-locks", "status", "--porcelain=v2", "-z", untracked_arg(mode)],
           cd: git_root,
           stderr_to_stdout: true,
           timeout_ms: timeout_ms
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

      case git_cmd(args, cd: git_root, stderr_to_stdout: true) do
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
    args = if staged, do: Enum.concat(args, ["--cached"]), else: args
    if path, do: args ++ ["--", path], else: args
  end

  @spec commit_diff_args(String.t(), String.t() | nil) :: [String.t()]
  defp commit_diff_args(commit, nil), do: ["show", commit, "--format=", "--patch"]

  defp commit_diff_args(commit, path), do: ["show", commit, "--format=", "--patch", "--", path]

  @impl true
  @spec log(String.t(), keyword()) :: {:ok, [Minga.Git.log_entry()]} | {:error, String.t()}
  def log(git_root, opts \\ []) when is_binary(git_root) do
    count = Keyword.get(opts, :count, 10)
    skip = Keyword.get(opts, :skip, 0)
    revision = Keyword.get(opts, :revision, "HEAD")
    path = Keyword.get(opts, :path)

    with :ok <- validate_log_position(skip, revision) do
      read_log(git_root, count, skip, revision, path)
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git log error: #{Exception.message(e)}"}
  end

  @spec validate_log_position(term(), term()) :: :ok | {:error, String.t()}
  defp validate_log_position(skip, revision)
       when is_integer(skip) and skip >= 0 and is_binary(revision) do
    if revision == "HEAD" or Regex.match?(~r/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/i, revision) do
      :ok
    else
      {:error, "git log revision must be a full object ID"}
    end
  end

  defp validate_log_position(_skip, _revision), do: {:error, "Invalid git log position"}

  @spec read_log(String.t(), pos_integer(), non_neg_integer(), String.t(), String.t() | nil) ::
          {:ok, [Minga.Git.log_entry()]} | {:error, String.t()}
  defp read_log(git_root, count, skip, revision, path) do
    format = "%H%x1f%h%x1f%an%x1f%cr%x1f%s"
    args = ["log", "--format=#{format}", "-n", "#{count}", "--skip=#{skip}", revision, "--"]
    args = if path, do: args ++ [path], else: args

    case git_cmd(args, cd: git_root, stderr_to_stdout: true) do
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
  end

  @impl true
  @spec stage(String.t(), String.t() | [String.t()]) :: :ok | {:error, String.t()}
  def stage(git_root, path) when is_binary(git_root) and is_binary(path) do
    stage(git_root, [path])
  end

  def stage(git_root, paths) when is_binary(git_root) and is_list(paths) do
    args = ["add", "--"] ++ paths

    case git_cmd(args, cd: git_root, stderr_to_stdout: true) do
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
    args = if Keyword.get(opts, :amend, false), do: Enum.concat(args, ["--amend"]), else: args

    case git_cmd(args, cd: git_root, stderr_to_stdout: true) do
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
  @spec head_commit(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def head_commit(git_root) when is_binary(git_root) do
    case git_cmd(["log", "-1", "--format=%H%x00%B", "HEAD", "--"],
           cd: git_root,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case :binary.split(output, <<0>>) do
          [oid, message] when byte_size(oid) in [40, 64] -> {:ok, {oid, String.trim(message)}}
          _malformed -> :error
        end

      _failure ->
        :error
    end
  rescue
    _ -> :error
  end

  @doc "Binds an exact file path to a fresh baseline in its own Git worktree."
  @impl true
  @spec review_baseline(String.t()) :: {:ok, ReviewIdentity.t()} | :error
  def review_baseline("/" <> _ = path) do
    with target when is_binary(target) <- Metadata.file_target(path),
         directory = Path.dirname(target),
         {:ok, root} <- review_location(directory, "--show-toplevel"),
         {:ok, prefix} <- review_location(directory, "--show-prefix"),
         relative = prefix <> Path.basename(target),
         :ok <- Change.validate_path(relative),
         {:ok, ref} <- review_ref(root) do
      {:ok, {root, relative, ref}}
    else
      _not_proven -> :error
    end
  end

  def review_baseline(_relative), do: :error

  @spec review_location(String.t(), String.t()) :: {:ok, String.t()} | :error
  defp review_location(directory, option) do
    case review_git(directory, ["rev-parse", option], stderr_to_stdout: true) do
      {output, 0} when byte_size(output) > 0 ->
        size = byte_size(output) - 1

        case output do
          <<value::binary-size(^size), "\n">> -> {:ok, value}
          _malformed -> :error
        end

      _not_git ->
        :error
    end
  end

  @doc "Reads the checked-out branch, commit and exact observed prefix of its reflog."
  @spec review_ref(String.t()) :: {:ok, ReviewIdentity.ref()} | :error
  def review_ref(root) do
    with {:ok, ref} <- checked_out_review_ref(root),
         {:ok, tip} <- review_tip(root, ref),
         {:ok, entries} <- review_log(root, ref, tip),
         {:ok, ^ref} <- checked_out_review_ref(root),
         {:ok, ^tip} <- review_tip(root, ref) do
      {:ok, {ref, tip, review_cursor(entries)}}
    else
      _unavailable -> :error
    end
  end

  @doc "Returns recorded new commits on the current first-parent history of the same branch."
  @spec review_transitions(String.t(), ReviewIdentity.ref()) ::
          {:ok, [review_transition()]} | :error
  def review_transitions(root, baseline) do
    with {:ok, tip} <- review_ref(root), do: review_transitions(root, baseline, tip)
  end

  @doc "Returns only immutable ancestry edges recorded as new commits after the baseline."
  @spec review_transitions(String.t(), ReviewIdentity.ref(), ReviewIdentity.ref()) ::
          {:ok, [review_transition()]} | :error
  def review_transitions(_root, same, same), do: {:ok, []}

  def review_transitions(
        root,
        {ref, baseline, {count, _} = original},
        {ref, tip, {seen, _} = end_at}
      )
      when is_binary(tip) and seen >= count do
    with :ok <- validate_oid(tip),
         {:ok, entries} <- review_log(root, ref, tip),
         ^end_at <- review_cursor(entries),
         {newest, prefix} = Enum.split(entries, seen - count),
         ^original <- review_cursor(prefix),
         {:ok, transitions} <- first_parent_transitions(root, baseline, tip) do
      committed = commits_in_log(Enum.reverse(newest), baseline, %{})
      {:ok, Enum.filter(transitions, &is_map_key(committed, &1))}
    else
      _unavailable -> :error
    end
  end

  def review_transitions(_root, _baseline, _tip), do: :error

  @spec review_log(String.t(), String.t(), String.t() | :unborn) ::
          {:ok, [binary()]} | :error
  defp review_log(_root, _ref, :unborn), do: {:ok, []}

  defp review_log(root, ref, tip) do
    case review_git(
           root,
           ["reflog", "show", "--no-show-signature", "--format=%H%x09%gs", ref, "--"],
           stderr_to_stdout: true
         ) do
      {"", 0} ->
        {:ok, []}

      {output, 0} ->
        review_entries(output, tip)

      _unavailable ->
        :error
    end
  end

  @spec review_entries(binary(), String.t()) :: {:ok, [binary()]} | :error
  defp review_entries(output, tip) do
    with [entry | _] = entries <- :binary.split(output, "\n", [:global, :trim]),
         [^tip, _action] <- :binary.split(entry, "\t") do
      {:ok, entries}
    else
      _changed_or_missing -> :error
    end
  end

  @spec review_cursor([binary()]) :: ReviewIdentity.cursor()
  defp review_cursor(entries),
    do: {length(entries), :crypto.hash(:sha256, Enum.intersperse(entries, "\n"))}

  @spec commits_in_log([binary()], String.t() | :unborn, %{optional(review_transition()) => true}) ::
          %{optional(review_transition()) => true}
  defp commits_in_log([], _parent, edges), do: edges

  defp commits_in_log([entry | rest], parent, edges) do
    case :binary.split(entry, "\t") do
      [oid, action] ->
        edges =
          if new_commit_action?(action), do: Map.put(edges, {parent, oid}, true), else: edges

        commits_in_log(rest, oid, edges)

      _malformed ->
        %{}
    end
  end

  @spec new_commit_action?(binary()) :: boolean()
  defp new_commit_action?("commit: " <> _), do: true
  defp new_commit_action?("commit (initial): " <> _), do: true
  defp new_commit_action?("commit (merge): " <> _), do: true
  defp new_commit_action?("cherry-pick: " <> _), do: true
  defp new_commit_action?("revert: " <> _), do: true

  defp new_commit_action?("merge " <> action),
    do: :binary.match(action, ": Merge made by ") != :nomatch

  defp new_commit_action?(_not_a_commit), do: false

  @doc "Reads an exact regular-file path from an immutable commit. Absence is not a lookup failure."
  @spec review_blob(String.t(), String.t() | :unborn, String.t()) ::
          {:ok, binary() | nil} | :error
  def review_blob(root, commit, path) when is_binary(commit) do
    with :ok <- Change.validate_path(path),
         :ok <- validate_oid(commit),
         treeish = commit <> "^{commit}",
         {entries, 0} <-
           review_git(root, ["--literal-pathspecs", "ls-tree", "-z", treeish, "--", path]) do
      exact_review_blob(root, entries, path)
    else
      _failure -> :error
    end
  end

  def review_blob(_root, :unborn, _path), do: {:ok, nil}

  @spec checked_out_review_ref(String.t()) :: {:ok, String.t()} | :error
  defp checked_out_review_ref(root) do
    case review_git(root, ["symbolic-ref", "--no-recurse", "--quiet", "HEAD"]) do
      {"refs/heads/" <> _name = ref, 0} -> {:ok, String.trim_trailing(ref, "\n")}
      _detached_or_unavailable -> :error
    end
  end

  @spec review_tip(String.t(), String.t()) :: {:ok, String.t() | :unborn} | :error
  defp review_tip(root, ref) do
    case review_git(root, ["show-ref", "--hash", "--verify", ref], stderr_to_stdout: true) do
      {output, 0} ->
        verify_review_commit(root, String.trim_trailing(output, "\n"))

      _unresolved ->
        case review_git(root, ["show-ref", "--verify", "--quiet", ref]) do
          {"", 1} -> {:ok, :unborn}
          _lookup_failure -> :error
        end
    end
  end

  @spec verify_review_commit(String.t(), String.t()) :: {:ok, String.t()} | :error
  defp verify_review_commit(root, oid) do
    with :ok <- validate_oid(oid),
         {"commit\n", 0} <- review_git(root, ["cat-file", "-t", oid], stderr_to_stdout: true) do
      {:ok, oid}
    else
      _missing_or_not_commit -> :error
    end
  end

  @spec first_parent_transitions(String.t(), String.t() | :unborn, String.t()) ::
          {:ok, [{String.t() | :unborn, String.t()}]} | :error
  defp first_parent_transitions(root, :unborn, tip) do
    case review_git(root, ["rev-parse", "--is-shallow-repository"]) do
      {"false\n", 0} -> read_first_parent_transitions(root, :unborn, tip, [])
      _incomplete_history -> :error
    end
  end

  defp first_parent_transitions(root, baseline, tip) do
    case validate_oid(baseline) do
      :ok -> read_first_parent_transitions(root, baseline, tip, ["^" <> baseline])
      :error -> :error
    end
  end

  @spec read_first_parent_transitions(String.t(), String.t() | :unborn, String.t(), [String.t()]) ::
          {:ok, [{String.t() | :unborn, String.t()}]} | :error
  defp read_first_parent_transitions(root, baseline, tip, exclusions) do
    args = ["rev-list", "--first-parent", "--parents", "--reverse", tip | exclusions]

    case review_git(root, args) do
      {output, 0} ->
        entries = :binary.split(output, "\n", [:global, :trim])
        collect_first_parent_transitions(entries, baseline, tip, [])

      _failure ->
        :error
    end
  end

  @spec collect_first_parent_transitions(
          [binary()],
          String.t() | :unborn,
          String.t(),
          [{String.t() | :unborn, String.t()}]
        ) :: {:ok, [{String.t() | :unborn, String.t()}]} | :error
  defp collect_first_parent_transitions([], tip, tip, acc), do: {:ok, Enum.reverse(acc)}
  defp collect_first_parent_transitions([], _last, _tip, _acc), do: :error

  defp collect_first_parent_transitions([entry | rest], previous, tip, acc) do
    case :binary.split(entry, " ", [:global]) do
      [commit, ^previous | _other_parents] ->
        collect_first_parent_transitions(rest, commit, tip, [{previous, commit} | acc])

      [commit] when previous == :unborn ->
        collect_first_parent_transitions(rest, commit, tip, [{:unborn, commit} | acc])

      _diverged ->
        :error
    end
  end

  @spec exact_review_blob(String.t(), binary(), String.t()) :: {:ok, binary() | nil} | :error
  defp exact_review_blob(root, entries, path) do
    case exact_path_metadata(entries, path) do
      nil ->
        {:ok, nil}

      metadata ->
        with [mode, "blob", oid] when mode in ["100644", "100755"] <-
               :binary.split(metadata, " ", [:global]),
             {bytes, 0} <- review_git(root, ["cat-file", "blob", oid]) do
          {:ok, bytes}
        else
          _not_regular -> :error
        end
    end
  end

  @spec exact_path_metadata(binary(), String.t()) :: binary() | nil
  defp exact_path_metadata(entries, path) do
    entries
    |> :binary.split(<<0>>, [:global, :trim])
    |> Enum.find_value(fn entry ->
      case :binary.split(entry, "\t") do
        [metadata, ^path] -> metadata
        _descendant -> nil
      end
    end)
  end

  @spec validate_oid(binary()) :: :ok | :error
  defp validate_oid(oid) when byte_size(oid) in [40, 64] do
    if String.match?(oid, ~r/\A[0-9a-f]+\z/), do: :ok, else: :error
  end

  defp validate_oid(_invalid), do: :error

  # A hook can launch Minga with Git variables pointing at a different checkout.
  @review_git_env [
    {"GIT_DIR", nil},
    {"GIT_COMMON_DIR", nil},
    {"GIT_WORK_TREE", nil},
    {"GIT_NAMESPACE", nil},
    {"GIT_GRAFT_FILE", "/dev/null"},
    {"GIT_SHALLOW_FILE", nil},
    {"LC_ALL", "C"}
  ]

  @spec review_git(String.t(), [String.t()], keyword()) :: {binary(), non_neg_integer()}
  defp review_git(root, args, opts \\ []) do
    git_cmd(["--no-replace-objects", "-c", "advice.graftFileDeprecated=false" | args],
      cd: root,
      env: @review_git_env,
      stderr_to_stdout: Keyword.get(opts, :stderr_to_stdout, false)
    )
  end

  @impl true
  @spec ahead_behind(String.t()) :: {:ok, non_neg_integer(), non_neg_integer()} | :error
  def ahead_behind(git_root) when is_binary(git_root) do
    case git_cmd(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
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

    case git_cmd(args, cd: git_root, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git reset failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git reset error: #{Exception.message(e)}"}
  end

  @impl true
  @spec unstage_all(String.t()) :: :ok | {:error, String.t()}
  def unstage_all(git_root) when is_binary(git_root) do
    case git_cmd(["reset", "HEAD"], cd: git_root, stderr_to_stdout: true) do
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
    case git_cmd(["ls-files", "--error-unmatch", path],
           cd: git_root,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        # Tracked file: restore from index/HEAD
        case git_cmd(["checkout", "--", path],
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

    case git_cmd(["branch", "-a", "--format=#{format}"],
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
    case git_cmd(["checkout", "-b", name], cd: git_root, stderr_to_stdout: true) do
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
    case git_cmd(["checkout", name], cd: git_root, stderr_to_stdout: true) do
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

    case git_cmd(["branch", flag, name], cd: git_root, stderr_to_stdout: true) do
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
        do: Enum.concat(args, ["--include-untracked"]),
        else: args

    case git_cmd(args, cd: git_root, stderr_to_stdout: true) do
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
    case git_cmd(["stash", "pop"], cd: git_root, stderr_to_stdout: true) do
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

    case git_cmd(["stash", "list", "--format=#{format}"],
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
    case git_cmd(["stash", "drop", "stash@{#{index}}"],
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

    args =
      if Keyword.get(opts, :set_upstream), do: Enum.concat(args, ["--set-upstream"]), else: args

    args = if Keyword.get(opts, :force), do: Enum.concat(args, ["--force-with-lease"]), else: args

    case git_cmd(args, cd: git_root, stderr_to_stdout: true) do
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
    args = if Keyword.get(opts, :rebase), do: Enum.concat(args, ["--rebase"]), else: args

    case git_cmd(args, cd: git_root, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "git pull failed: #{String.trim(output)}"}
    end
  rescue
    e in [ErlangError, ArgumentError] -> {:error, "git pull error: #{Exception.message(e)}"}
  end

  @impl true
  @spec fetch_remotes(String.t(), keyword()) :: :ok | {:error, String.t()}
  def fetch_remotes(git_root, _opts \\ []) when is_binary(git_root) do
    case git_cmd(["fetch", "--all"], cd: git_root, stderr_to_stdout: true) do
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
    head_path = Path.join(Metadata.directory(git_root), "HEAD")

    case File.read(head_path) do
      {:ok, "ref: refs/heads/" <> branch} ->
        {:ok, String.trim(branch)}

      {:ok, _detached} ->
        # Detached HEAD: fall back to git CLI for the short SHA
        case git_cmd(["rev-parse", "--short", "HEAD"],
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

  @spec untracked_arg(Minga.Git.untracked_mode()) :: String.t()
  defp untracked_arg(:no), do: "-uno"
  defp untracked_arg(:normal), do: "-unormal"
  defp untracked_arg(:all), do: "-uall"
  defp untracked_arg(_), do: "-unormal"

  @spec git_cmd([String.t()], keyword()) :: {String.t(), non_neg_integer()}
  defp git_cmd(args, opts) when is_list(args) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    cmd_opts = opts |> Keyword.delete(:timeout_ms) |> Keyword.put_new(:stderr_to_stdout, true)

    case System.find_executable("git") do
      nil -> {"git executable not found", 127}
      executable -> run_cmd_with_timeout(executable, args, cmd_opts, timeout_ms)
    end
  rescue
    e in [ErlangError, ArgumentError] -> {Exception.message(e), 1}
  end

  @spec run_cmd_with_timeout(String.t(), [String.t()], keyword(), pos_integer()) ::
          {String.t(), non_neg_integer()}
  defp run_cmd_with_timeout(executable, args, opts, timeout_ms) do
    task = Task.async(fn -> System.cmd(executable, args, opts) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, code}} -> {output, code}
      {:exit, reason} -> {inspect(reason), 1}
      nil -> {"git command timed out after #{timeout_ms}ms", 124}
    end
  end

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
