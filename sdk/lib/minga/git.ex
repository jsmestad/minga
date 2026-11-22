defmodule Minga.Git do
  @moduledoc """
  Read and change an explicit Git repository. Operations that invoke Git belong in an extension worker, not an editor callback. Editor buffer tracking and repository processes are private to the host.
  """

  alias Minga.Git.BranchInfo
  alias Minga.Git.LogEntry
  alias Minga.Git.StashEntry
  alias Minga.Git.StatusEntry
  alias Minga.Git.TrackedFile
  alias MingaEditor.Extension.GitDiff.Hunk

  @typedoc "One contiguous change with zero-based coordinates in the base and revised text."
  @type change :: Hunk.change()

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

  @spec root_for(String.t() | nil) :: {:ok, String.t()} | :not_git
  def root_for(_path), do: raise("minga_sdk is compile-time only")

  @spec show_head(String.t(), String.t()) :: {:ok, String.t()} | :error
  def show_head(_git_root, _relative_path), do: raise("minga_sdk is compile-time only")

  @spec show_staged(String.t(), String.t()) :: {:ok, String.t()} | :error
  def show_staged(_git_root, _relative_path), do: raise("minga_sdk is compile-time only")

  @doc """
  Reads a regular file's stage-zero blob, returning `{:ok, nil}` for an absent
  path, `{:ok, ""}` for an empty blob, and `{:error, reason}` for an unmerged
  path or a read failure.
  """
  @spec index_blob(String.t(), String.t()) :: {:ok, binary() | nil} | {:error, String.t()}
  def index_blob(_git_root, _relative_path), do: raise("minga_sdk is compile-time only")

  @spec stage_patch(String.t(), String.t()) :: :ok | {:error, String.t()}
  def stage_patch(_git_root, _patch), do: raise("minga_sdk is compile-time only")

  @doc """
  Stages only the selected change without modifying the worktree.

  Use `nil` for an absent file and `""` for a present empty file in either
  snapshot. A mismatch in index presence or a conflicting edit at the selected
  hunk is rejected. Unrelated staged changes are preserved.
  """
  @spec stage_change(String.t(), String.t(), binary() | nil, binary() | nil, change()) ::
          :ok | {:error, String.t()}
  def stage_change(_git_root, _relative_path, _base, _revised, _change),
    do: raise("minga_sdk is compile-time only")

  @doc "Captures tracked-buffer text, cursor, version, and changes against cached HEAD."
  @spec tracked_file(pid()) :: {:ok, TrackedFile.t()} | :not_tracked
  def tracked_file(_buffer_pid), do: raise("minga_sdk is compile-time only")

  @doc "Finds the change at a buffer line, including the anchor above a deletion."
  @spec change_at([change()], non_neg_integer()) :: change() | nil
  def change_at(_hunks, _line), do: raise("minga_sdk is compile-time only")

  @doc "Returns the next or previous change's buffer line, or nil if there is none."
  @spec neighbor_change_line([change()], non_neg_integer(), :next | :previous) ::
          non_neg_integer() | nil
  def neighbor_change_line(_hunks, _line, _direction),
    do: raise("minga_sdk is compile-time only")

  @doc "Reverts just one change in the revised text, without editing or saving a buffer."
  @spec revert_change(binary(), change()) :: binary()
  def revert_change(_content, _change), do: raise("minga_sdk is compile-time only")

  @spec blame_line(String.t(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | :error
  def blame_line(_git_root, _relative_path, _line_number),
    do: raise("minga_sdk is compile-time only")

  @spec status(String.t(), status_opts()) :: {:ok, [status_entry()]} | {:error, String.t()}
  def status(_git_root, _opts \\ []), do: raise("minga_sdk is compile-time only")

  @spec diff(String.t(), diff_opts()) :: {:ok, String.t()} | {:error, String.t()}
  def diff(_git_root, _opts \\ []), do: raise("minga_sdk is compile-time only")

  @doc "Reads recent commits with `:count`, `:path`, `:skip`, and a full `:revision` object ID."
  @spec log(String.t(), keyword()) :: {:ok, [log_entry()]} | {:error, String.t()}
  def log(_git_root, _opts \\ []), do: raise("minga_sdk is compile-time only")

  @spec stage(String.t(), String.t() | [String.t()]) :: :ok | {:error, String.t()}
  def stage(_git_root, _paths), do: raise("minga_sdk is compile-time only")

  @spec commit(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def commit(_git_root, _message, _opts \\ []), do: raise("minga_sdk is compile-time only")

  @spec last_commit_message(String.t()) :: {:ok, String.t()} | :error
  def last_commit_message(_git_root), do: raise("minga_sdk is compile-time only")

  @spec current_branch(String.t()) :: {:ok, String.t()} | :error
  def current_branch(_git_root), do: raise("minga_sdk is compile-time only")

  @spec ahead_behind(String.t()) :: {:ok, non_neg_integer(), non_neg_integer()} | :error
  def ahead_behind(_git_root), do: raise("minga_sdk is compile-time only")

  @spec unstage(String.t(), String.t() | [String.t()]) :: :ok | {:error, String.t()}
  def unstage(_git_root, _paths), do: raise("minga_sdk is compile-time only")

  @spec unstage_all(String.t()) :: :ok | {:error, String.t()}
  def unstage_all(_git_root), do: raise("minga_sdk is compile-time only")

  @spec discard(String.t(), String.t()) :: :ok | {:error, String.t()}
  def discard(_git_root, _path), do: raise("minga_sdk is compile-time only")

  @spec branch_list(String.t()) :: {:ok, [BranchInfo.t()]} | {:error, String.t()}
  def branch_list(_git_root), do: raise("minga_sdk is compile-time only")

  @spec branch_create(String.t(), String.t()) :: :ok | {:error, String.t()}
  def branch_create(_git_root, _name), do: raise("minga_sdk is compile-time only")

  @spec branch_switch(String.t(), String.t()) :: :ok | {:error, String.t()}
  def branch_switch(_git_root, _name), do: raise("minga_sdk is compile-time only")

  @spec branch_delete(String.t(), String.t(), boolean()) :: :ok | {:error, String.t()}
  def branch_delete(_git_root, _name, _force \\ false),
    do: raise("minga_sdk is compile-time only")

  @spec stash(String.t(), keyword()) :: :ok | {:error, String.t()}
  def stash(_git_root, _opts \\ []), do: raise("minga_sdk is compile-time only")

  @spec stash_pop(String.t()) :: :ok | {:error, String.t()}
  def stash_pop(_git_root), do: raise("minga_sdk is compile-time only")

  @spec stash_list(String.t()) :: {:ok, [stash_entry()]} | {:error, String.t()}
  def stash_list(_git_root), do: raise("minga_sdk is compile-time only")

  @spec stash_drop(String.t(), non_neg_integer()) :: :ok | {:error, String.t()}
  def stash_drop(_git_root, _index), do: raise("minga_sdk is compile-time only")

  @spec push(String.t(), keyword()) :: :ok | {:error, String.t()}
  def push(_git_root, _opts \\ []), do: raise("minga_sdk is compile-time only")

  @spec pull(String.t(), keyword()) :: :ok | {:error, String.t()}
  def pull(_git_root, _opts \\ []), do: raise("minga_sdk is compile-time only")

  @doc "Requests a status refresh if Minga already tracks this repository."
  @spec refresh_status(String.t()) :: :ok
  def refresh_status(_git_root), do: raise("minga_sdk is compile-time only")

  @spec fetch_remotes(String.t(), keyword()) :: :ok | {:error, String.t()}
  def fetch_remotes(_git_root, _opts \\ []), do: raise("minga_sdk is compile-time only")

  @spec relative_path(String.t(), String.t()) :: String.t()
  def relative_path(_git_root, _file_path), do: raise("minga_sdk is compile-time only")
end
