defmodule Minga.Git do
  @moduledoc """
  Git operations, delegated to a configurable backend.

  In production, uses `Minga.Git.System` which shells out to the `git`
  CLI. In tests, swap to `Minga.Git.Stub` to avoid spawning OS processes:

      config :minga, git_module: Minga.Git.Stub
  """

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

  @typedoc "A structured status entry for one file."
  @type status_entry :: StatusEntry.t()

  @typedoc "A structured log entry."
  @type log_entry :: LogEntry.t()

  # ── Delegated operations (go through the backend) ──────────────────────

  @doc """
  Finds the git repository root for a file path.

  Returns `{:ok, root_path}` if the file is inside a git repo, or
  `:not_git` if it isn't.
  """
  @spec root_for(String.t()) :: {:ok, String.t()} | :not_git
  def root_for(path), do: impl().root_for(path)

  @doc """
  Reads the HEAD version of a file from git.

  Returns `{:ok, content}` with the file content at HEAD, or `:error`
  if the file doesn't exist in HEAD (new file, not tracked, etc.).
  """
  @spec show_head(String.t(), String.t()) :: {:ok, String.t()} | :error
  def show_head(git_root, relative_path), do: impl().show_head(git_root, relative_path)

  @doc """
  Applies a unified diff patch to the git index (staging area).
  """
  @spec stage_patch(String.t(), String.t()) :: :ok | {:error, String.t()}
  def stage_patch(git_root, patch), do: impl().stage_patch(git_root, patch)

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
  @spec status(String.t()) :: {:ok, [status_entry()]} | {:error, String.t()}
  def status(git_root), do: impl().status(git_root)

  @doc """
  Returns the diff for a specific file or all changes.

  Options: `:path` (file path), `:staged` (boolean, default false).
  """
  @spec diff(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(git_root, opts \\ []), do: impl().diff(git_root, opts)

  @doc """
  Returns recent commits as structured entries.

  Options: `:count` (default 10), `:path` (limit to file).
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
  """
  @spec commit(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def commit(git_root, message), do: impl().commit(git_root, message)

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

  @doc "Returns a summary map (branch, ahead/behind, file counts) from a Repo."
  @spec repo_summary(pid()) :: map()
  defdelegate repo_summary(repo_pid), to: Minga.Git.Repo, as: :summary

  @doc "Triggers a background refresh of the Repo's cached git state."
  @spec refresh_repo(pid()) :: :ok
  defdelegate refresh_repo(repo_pid), to: Minga.Git.Repo, as: :refresh

  @doc """
  Returns the git tracking process for a buffer, or nil if untracked.

  Composes the Tracker lookup so callers don't need to know about
  the Tracker → Buffer two-step.
  """
  @spec tracking_pid(pid()) :: pid() | nil
  defdelegate tracking_pid(buffer_pid), to: Minga.Git.Tracker, as: :lookup

  @doc "Returns gutter sign indicators (line → hunk type) for a tracked buffer."
  @spec gutter_signs(GenServer.server()) :: %{non_neg_integer() => atom()}
  defdelegate gutter_signs(git_buffer), to: Minga.Git.Buffer, as: :signs

  @doc "Returns modeline-ready git info (branch, hunk counts) for a tracked buffer."
  @spec modeline_info(GenServer.server()) :: map()
  defdelegate modeline_info(git_buffer), to: Minga.Git.Buffer, as: :modeline_info

  @doc "Returns all diff hunks for a tracked buffer."
  @spec hunks(GenServer.server()) :: [Minga.Core.Diff.hunk()]
  defdelegate hunks(git_buffer), to: Minga.Git.Buffer, as: :hunks

  @doc "Returns the hunk at a specific line, or nil."
  @spec hunk_at(GenServer.server(), non_neg_integer()) :: Minga.Core.Diff.hunk() | nil
  defdelegate hunk_at(git_buffer, line), to: Minga.Git.Buffer, as: :hunk_at

  # ── Pure diff computation ──────────────────────────────────────────────

  @doc "Computes line-level diff hunks between two lists of lines."
  @spec diff_lines([String.t()], [String.t()]) :: [Minga.Core.Diff.hunk()]
  defdelegate diff_lines(base_lines, current_lines), to: Minga.Core.Diff

  @doc "Reverts a single hunk, restoring the base content for those lines."
  @spec revert_hunk([String.t()], Minga.Core.Diff.hunk()) :: [String.t()]
  defdelegate revert_hunk(current_lines, hunk), to: Minga.Core.Diff

  # ── Pure calculations (no backend needed) ──────────────────────────────

  @doc """
  Returns the path of a file relative to the git root.
  """
  @spec relative_path(String.t(), String.t()) :: String.t()
  def relative_path(git_root, file_path) do
    Path.relative_to(Path.expand(file_path), Path.expand(git_root))
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec impl() :: module()
  defp impl do
    Application.get_env(:minga, :git_module, Minga.Git.System)
  end
end
