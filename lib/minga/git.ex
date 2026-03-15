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
