defmodule Minga.Git do
  @moduledoc """
  Git operations, delegated to a configurable backend.

  In production, uses `Minga.Git.System` which shells out to the `git`
  CLI. In tests, swap to `Minga.Git.Stub` to avoid spawning OS processes:

      config :minga, git_module: Minga.Git.Stub
  """

  alias Minga.Buffer
  alias Minga.Core.Diff
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.Git.Change
  alias Minga.Git.StashEntry
  alias Minga.Git.TrackedFile
  alias Minga.Project.Root

  defmodule StatusEntry do
    @moduledoc false
    @enforce_keys [:path, :status, :staged]
    defstruct [:path, :status, :staged]

    @type t :: %__MODULE__{
            path: String.t(),
            status:
              :added
              | :modified
              | :deleted
              | :renamed
              | :copied
              | :untracked
              | :conflict
              | :unknown,
            staged: boolean()
          }
  end

  defmodule BranchInfo do
    @moduledoc "Structured information about a git branch."
    @enforce_keys [:name, :current]
    defstruct [:name, :current, upstream: nil, remote: false, ahead: nil, behind: nil]

    @type t :: %__MODULE__{
            name: String.t(),
            current: boolean(),
            upstream: String.t() | nil,
            remote: boolean(),
            ahead: non_neg_integer() | nil,
            behind: non_neg_integer() | nil
          }
  end

  defmodule LogEntry do
    @moduledoc false
    @enforce_keys [:hash, :short_hash, :author, :date, :message]
    defstruct [:hash, :short_hash, :author, :date, :message]

    @type t :: %__MODULE__{
            hash: String.t(),
            short_hash: String.t(),
            author: String.t(),
            date: String.t(),
            message: String.t()
          }
  end

  @typedoc "One contiguous change with zero-based coordinates in the base and revised text."
  @type change :: Diff.hunk()

  @typedoc "A structured status entry for one file."
  @type status_entry :: StatusEntry.t()

  @typedoc "A structured log entry."
  @type log_entry :: LogEntry.t()

  @typedoc "A structured stash entry."
  @type stash_entry :: StashEntry.t()

  @typedoc "Accepted diff options. Unknown keys, duplicate keys, and invalid values are rejected. `:commit` may be combined with `:staged`, but only when `:staged` is `false`."
  @type diff_opt :: {:path, String.t()} | {:staged, boolean()} | {:commit, String.t()}

  @type diff_opts :: [diff_opt()]

  @typedoc "How much untracked-file detail `git status` should enumerate."
  @type untracked_mode :: :no | :normal | :all

  @typedoc "Accepted `status/2` options."
  @type status_opt :: {:untracked_mode, untracked_mode()} | {:timeout_ms, pos_integer()}

  @type status_opts :: [status_opt()]

  # ── Delegated operations (go through the backend) ──────────────────────

  @doc """
  Finds the git repository root for a file path.

  Returns `{:ok, root_path}` if the file is inside a git repo, or
  `:not_git` if it isn't or if no path was provided (`nil`).
  """
  @spec root_for(String.t() | nil) :: {:ok, String.t()} | :not_git
  def root_for(nil), do: :not_git
  def root_for(path), do: impl().root_for(path)

  @doc """
  Reads the HEAD version of a file from git.

  Returns `{:ok, content}` with the file content at HEAD, or `:error`
  if the file doesn't exist in HEAD (new file, not tracked, etc.).
  """
  @spec show_head(String.t(), String.t()) :: {:ok, String.t()} | :error
  def show_head(git_root, relative_path), do: impl().show_head(git_root, relative_path)

  @doc """
  Reads the staged (index) version of a file from git.

  Returns `{:ok, content}` with the file content in the index, or `:error`
  if the path has no stage-zero entry in the index.
  """
  @spec show_staged(String.t(), String.t()) :: {:ok, String.t()} | :error
  def show_staged(git_root, relative_path), do: impl().show_staged(git_root, relative_path)

  @doc """
  Reads a regular file's stage-zero blob from the index.

  Returns `{:ok, nil}` only when the path is absent, including after a staged
  deletion. A present empty blob is `{:ok, ""}`. Unmerged paths and read
  failures return `{:error, reason}`.
  """
  @spec index_blob(String.t(), String.t()) :: {:ok, binary() | nil} | {:error, String.t()}
  def index_blob(git_root, relative_path), do: impl().index_blob(git_root, relative_path)

  @doc """
  Applies a unified diff patch to the git index (staging area).
  """
  @spec stage_patch(String.t(), String.t()) :: :ok | {:error, String.t()}
  def stage_patch(git_root, patch), do: impl().stage_patch(git_root, patch)

  @doc """
  Stages only `change` from `base` to `revised`, without writing to the worktree.

  Use `nil` for an absent file and `""` for a present empty file in either
  snapshot. A mismatch in index presence or a conflicting edit at the selected
  hunk is rejected. Unrelated staged changes are preserved.
  """
  @spec stage_change(String.t(), String.t(), binary() | nil, binary() | nil, change()) ::
          :ok | {:error, String.t()}
  def stage_change(git_root, relative_path, base, revised, change),
    do: impl().stage_change(git_root, relative_path, base, revised, change)

  @doc """
  Gets blame information for a specific line of a file.

  Returns `{:ok, blame_text}` with a human-readable blame string,
  or `:error` if blame fails.
  """
  @spec blame_line(String.t(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | :error
  def blame_line(git_root, relative_path, line_number),
    do: impl().blame_line(git_root, relative_path, line_number)

  @doc """
  Returns a structured list of changed files with their status.
  """
  @spec status(String.t(), status_opts()) :: {:ok, [status_entry()]} | {:error, String.t()}
  def status(git_root, opts \\ []), do: impl().status(git_root, opts)

  @doc """
  Returns the diff for a specific file or all changes.

  Options: `:path` (file path), `:staged` (boolean, default false), `:commit` (commit hash).
  `:commit` may be combined with `:staged, false`; commit diffs can still be narrowed with `:path`.
  """
  @spec diff(String.t(), diff_opts()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(git_root, opts \\ []) do
    case Minga.Git.DiffOptions.validate(opts) do
      :ok -> impl().diff(git_root, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns recent commits as structured entries.

  Options: `:count` (default 10), `:path` (limit to one file), `:skip` (default 0), and `:revision` (full object ID, defaults to `HEAD`). Use `:revision` with `:skip` to page through the same history after the active branch moves.
  """
  @spec log(String.t(), keyword()) :: {:ok, [log_entry()]} | {:error, String.t()}
  def log(git_root, opts \\ []), do: impl().log(git_root, opts)

  @doc """
  Stages specific files (equivalent to `git add`).
  """
  @spec stage(String.t(), String.t() | [String.t()]) :: :ok | {:error, String.t()}
  def stage(git_root, paths), do: impl().stage(git_root, paths)

  @doc """
  Creates a commit with the given message.

  Options: `:amend` (boolean, default false) to amend the previous commit.
  """
  @spec commit(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def commit(git_root, message, opts \\ []), do: impl().commit(git_root, message, opts)

  @doc """
  Returns the message of the most recent commit.
  """
  @spec last_commit_message(String.t()) :: {:ok, String.t()} | :error
  def last_commit_message(git_root), do: impl().last_commit_message(git_root)

  @doc """
  Returns the current branch name for a git repository.

  Returns `{:ok, branch_name}` or `:error` if it can't be determined
  (e.g., detached HEAD, not a git repo).
  """
  @spec current_branch(String.t()) :: {:ok, String.t()} | :error
  def current_branch(git_root), do: impl().current_branch(git_root)

  @doc """
  Returns ahead/behind counts relative to the upstream tracking branch.
  """
  @spec ahead_behind(String.t()) :: {:ok, non_neg_integer(), non_neg_integer()} | :error
  def ahead_behind(git_root), do: impl().ahead_behind(git_root)

  @doc """
  Unstages specific files from the index (equivalent to `git reset HEAD -- <paths>`).
  """
  @spec unstage(String.t(), String.t() | [String.t()]) :: :ok | {:error, String.t()}
  def unstage(git_root, paths), do: impl().unstage(git_root, paths)

  @doc """
  Unstages all staged files (equivalent to `git reset HEAD`).
  """
  @spec unstage_all(String.t()) :: :ok | {:error, String.t()}
  def unstage_all(git_root), do: impl().unstage_all(git_root)

  @doc """
  Discards working tree changes for a file. Destructive and irreversible.

  For tracked files, runs `git checkout -- <path>`.
  For untracked files, deletes the file.
  """
  @spec discard(String.t(), String.t()) :: :ok | {:error, String.t()}
  def discard(git_root, path), do: impl().discard(git_root, path)

  @doc "Lists all branches (local and remote)."
  @spec branch_list(String.t()) :: {:ok, [BranchInfo.t()]} | {:error, String.t()}
  def branch_list(git_root), do: impl().branch_list(git_root)

  @doc "Creates a new branch and checks it out."
  @spec branch_create(String.t(), String.t()) :: :ok | {:error, String.t()}
  def branch_create(git_root, name), do: impl().branch_create(git_root, name)

  @doc "Switches to an existing branch."
  @spec branch_switch(String.t(), String.t()) :: :ok | {:error, String.t()}
  def branch_switch(git_root, name), do: impl().branch_switch(git_root, name)

  @doc "Deletes a branch."
  @spec branch_delete(String.t(), String.t(), boolean()) :: :ok | {:error, String.t()}
  def branch_delete(git_root, name, force \\ false),
    do: impl().branch_delete(git_root, name, force)

  @doc "Saves current worktree changes to a stash."
  @spec stash(String.t(), keyword()) :: :ok | {:error, String.t()}
  def stash(git_root, opts \\ []), do: impl().stash(git_root, opts)

  @doc "Pops the most recent stash."
  @spec stash_pop(String.t()) :: :ok | {:error, String.t()}
  def stash_pop(git_root), do: impl().stash_pop(git_root)

  @doc "Lists stashes for a repository."
  @spec stash_list(String.t()) :: {:ok, [stash_entry()]} | {:error, String.t()}
  def stash_list(git_root), do: impl().stash_list(git_root)

  @doc "Drops a stash by index."
  @spec stash_drop(String.t(), non_neg_integer()) :: :ok | {:error, String.t()}
  def stash_drop(git_root, index), do: impl().stash_drop(git_root, index)

  @doc "Pushes the current branch to its upstream remote."
  @spec push(String.t(), keyword()) :: :ok | {:error, String.t()}
  def push(git_root, opts \\ []), do: impl().push(git_root, opts)

  @doc "Pulls from the upstream remote (fetch + merge)."
  @spec pull(String.t(), keyword()) :: :ok | {:error, String.t()}
  def pull(git_root, opts \\ []), do: impl().pull(git_root, opts)

  @doc "Fetches from all remotes."
  @spec fetch_remotes(String.t(), keyword()) :: :ok | {:error, String.t()}
  def fetch_remotes(git_root, opts \\ []), do: impl().fetch_remotes(git_root, opts)

  # ── Repository process lookup ────────────────────────────────────────────

  @doc "Finds the Repo process for a git root path, or nil if not started."
  @spec lookup_repo(String.t()) :: pid() | nil
  defdelegate lookup_repo(git_root), to: Minga.Git.Repo, as: :lookup

  # ── Per-buffer git state ─────────────────────────────────────────────────

  @doc "Returns cached status entries from a running Repo process."
  @spec repo_status(pid()) :: [status_entry()]
  defdelegate repo_status(repo_pid), to: Minga.Git.Repo, as: :status

  @doc "Returns cached entries, their path base, and branch metadata from a Repo."
  @spec repo_status_snapshot(pid()) :: Minga.Git.Repo.status_snapshot()
  defdelegate repo_status_snapshot(repo_pid), to: Minga.Git.Repo, as: :status_snapshot

  @doc "Returns a summary map (branch, ahead/behind, file counts) from a Repo."
  @spec repo_summary(pid()) :: map()
  defdelegate repo_summary(repo_pid), to: Minga.Git.Repo, as: :summary

  @doc "Triggers a background refresh of the Repo's cached git state."
  @spec refresh_repo(pid()) :: :ok
  defdelegate refresh_repo(repo_pid), to: Minga.Git.Repo, as: :refresh

  @doc "Requests a status refresh if Minga already tracks this repository."
  @spec refresh_status(String.t()) :: :ok
  def refresh_status(git_root) when is_binary(git_root) do
    case lookup_repo(git_root) do
      nil -> :ok
      pid -> refresh_repo(pid)
    end
  end

  @doc """
  Returns the git tracking process for a buffer, or nil if untracked.

  Composes the Tracker lookup so callers don't need to know about
  the Tracker → Buffer two-step.
  """
  @spec tracking_pid(pid()) :: pid() | nil
  defdelegate tracking_pid(buffer_pid), to: Minga.Git.Tracker, as: :lookup

  @doc """
  Captures the buffer's content, cursor and mutation version together and
  computes its changes against the Git tracker's cached HEAD.

  Returns `:not_tracked` for a buffer without Git tracking. An absent HEAD
  entry has a `nil` base.
  """
  @spec tracked_file(pid()) :: {:ok, TrackedFile.t()} | :not_tracked
  def tracked_file(buffer_pid) when is_pid(buffer_pid) do
    case tracking_pid(buffer_pid) do
      nil ->
        :not_tracked

      git_pid ->
        GitBuffer.tracked_file(git_pid, Buffer.file_observation(buffer_pid))
    end
  catch
    :exit, _ -> :not_tracked
  end

  @doc "Returns gutter sign indicators (line → hunk type) for a tracked buffer."
  @spec gutter_signs(GenServer.server()) :: %{non_neg_integer() => atom()}
  defdelegate gutter_signs(git_buffer), to: Minga.Git.Buffer, as: :signs

  @doc "Returns modeline-ready git info (branch, hunk counts) for a tracked buffer."
  @spec modeline_info(GenServer.server()) :: Minga.Git.Buffer.modeline_info()
  defdelegate modeline_info(git_buffer), to: Minga.Git.Buffer, as: :modeline_info

  @doc "Returns all diff hunks for a tracked buffer."
  @spec hunks(GenServer.server()) :: [Minga.Core.Diff.hunk()]
  defdelegate hunks(git_buffer), to: Minga.Git.Buffer, as: :hunks

  @doc "Returns the hunk at a specific line, or nil."
  @spec hunk_at(GenServer.server(), non_neg_integer()) :: Minga.Core.Diff.hunk() | nil
  defdelegate hunk_at(git_buffer, line), to: Minga.Git.Buffer, as: :hunk_at

  @doc "Synchronizes a tracked buffer cache with the provided content."
  @spec sync_tracked_buffer(pid(), String.t()) :: :ok
  def sync_tracked_buffer(buffer_pid, content) when is_pid(buffer_pid) and is_binary(content) do
    case tracking_pid(buffer_pid) do
      nil ->
        :ok

      git_pid ->
        Minga.Git.Buffer.update_sync(git_pid, content)
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  # ── Pure diff computation ──────────────────────────────────────────────

  @doc "Finds the change at a buffer line, including the anchor above a deletion."
  @spec change_at([change()], non_neg_integer()) :: change() | nil
  defdelegate change_at(hunks, line), to: Diff, as: :hunk_at_line

  @doc "Returns the next or previous change's buffer line, or nil if there is none."
  @spec neighbor_change_line([change()], non_neg_integer(), :next | :previous) ::
          non_neg_integer() | nil
  def neighbor_change_line(hunks, line, :next) do
    Enum.find_value(hunks, fn hunk ->
      anchor = change_line(hunk)
      if anchor > line, do: anchor
    end)
  end

  def neighbor_change_line(hunks, line, :previous) do
    Enum.reduce_while(hunks, nil, fn hunk, previous ->
      anchor = change_line(hunk)
      if anchor < line, do: {:cont, anchor}, else: {:halt, previous}
    end)
  end

  @doc "Reverts just one change in the revised text, without editing or saving a buffer."
  @spec revert_change(binary(), change()) :: binary()
  def revert_change(content, change) do
    content
    |> Change.lines()
    |> Diff.revert_hunk(change)
    |> Enum.join("\n")
  end

  @doc "Computes line-level diff hunks between two lists of lines."
  @spec diff_lines([String.t()], [String.t()]) :: [Minga.Core.Diff.hunk()]
  defdelegate diff_lines(base_lines, current_lines), to: Minga.Core.Diff

  @doc "Reverts a single hunk, restoring the base content for those lines."
  @spec revert_hunk([String.t()], Minga.Core.Diff.hunk()) :: [String.t()]
  defdelegate revert_hunk(current_lines, hunk), to: Minga.Core.Diff

  # ── Path resolution ─────────────────────────────────────────────────────

  @doc """
  Returns the path of a file relative to the git root, resolving filesystem aliases on both sides.
  """
  @spec relative_path(String.t(), String.t()) :: String.t()
  def relative_path(git_root, file_path) do
    Path.relative_to(canonical_git_path(file_path), canonical_git_path(git_root))
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec change_line(change()) :: non_neg_integer()
  defp change_line(%{type: :deleted, start_line: start}), do: max(0, start - 1)
  defp change_line(%{start_line: start}), do: start

  @spec canonical_git_path(String.t()) :: String.t()
  defp canonical_git_path(path) do
    case Root.canonical_path(path) do
      {:ok, canonical} ->
        canonical

      {:error, :enoent} ->
        expanded = Path.expand(path)
        Path.join(canonical_git_path(Path.dirname(expanded)), Path.basename(expanded))

      {:error, _reason} ->
        Path.expand(path)
    end
  end

  @spec impl() :: module()
  defp impl do
    Application.get_env(:minga, :git_module, Minga.Git.System)
  end
end
