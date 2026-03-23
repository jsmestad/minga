defmodule Minga.Extension.Git do
  @moduledoc """
  Resolves git-sourced extensions by cloning and updating repos.

  Extensions declared with `git:` are cloned to a local cache directory
  (`~/.local/share/minga/extensions/{name}/`). On first load, the repo
  is cloned. On subsequent boots, the cached checkout is used as-is.
  Explicit updates via `SPC h e u` fetch and fast-forward.
  """

  @extensions_dir Path.expand("~/.local/share/minga/extensions")

  @typedoc "Summary of available updates for a git extension."
  @type update_info :: %{
          name: atom(),
          old_ref: String.t(),
          new_ref: String.t(),
          commit_count: non_neg_integer(),
          branch: String.t() | nil
        }

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Ensures the git repo is cloned locally. Returns the local path.

  If the cache directory already exists, returns it immediately (no
  network access). If missing, clones the repo. Respects `branch:` and
  `ref:` options from the git config.
  """
  @spec ensure_cloned(atom(), %{url: String.t(), branch: String.t() | nil, ref: String.t() | nil}) ::
          {:ok, String.t()} | {:error, String.t()}
  def ensure_cloned(name, git_opts) do
    dest = extension_path(name)

    if File.dir?(Path.join(dest, ".git")) do
      {:ok, dest}
    else
      clone(name, git_opts, dest)
    end
  end

  @doc """
  Fetches remote changes and returns update info without applying them.

  Returns `{:ok, update_info}` if there are new commits available,
  `:up_to_date` if already current, or `{:error, reason}` on failure.
  """
  @spec fetch_updates(atom(), %{url: String.t(), branch: String.t() | nil, ref: String.t() | nil}) ::
          {:ok, update_info()} | :up_to_date | {:error, String.t()}
  def fetch_updates(name, git_opts) do
    dest = extension_path(name)

    if File.dir?(Path.join(dest, ".git")) do
      fetch_and_compare(name, git_opts, dest)
    else
      {:error, "extension #{name}: not cloned yet"}
    end
  end

  @doc """
  Applies a previously fetched update by fast-forwarding the local checkout.
  """
  @spec apply_update(atom()) :: :ok | {:error, String.t()}
  def apply_update(name) do
    dest = extension_path(name)

    case git(dest, ["merge", "--ff-only", "FETCH_HEAD"]) do
      {_output, 0} -> :ok
      {output, _} -> {:error, "fast-forward failed for #{name}: #{String.trim(output)}"}
    end
  end

  @doc """
  Rolls back to a specific ref after a failed update or compile.
  """
  @spec rollback(atom(), String.t()) :: :ok | {:error, String.t()}
  def rollback(name, ref) do
    dest = extension_path(name)

    case git(dest, ["checkout", ref]) do
      {_output, 0} -> :ok
      {output, _} -> {:error, "rollback failed for #{name}: #{String.trim(output)}"}
    end
  end

  @doc """
  Returns the current HEAD ref (short hash) for a cloned extension.
  """
  @spec current_ref(atom()) :: {:ok, String.t()} | {:error, String.t()}
  def current_ref(name) do
    dest = extension_path(name)

    if File.dir?(dest) do
      case git(dest, ["rev-parse", "--short", "HEAD"]) do
        {ref, 0} -> {:ok, String.trim(ref)}
        {output, _} -> {:error, "could not read HEAD for #{name}: #{String.trim(output)}"}
      end
    else
      {:error, "extension #{name}: not cloned"}
    end
  end

  @doc "Returns the local cache path for a named extension."
  @spec extension_path(atom()) :: String.t()
  def extension_path(name) do
    Path.join(@extensions_dir, Atom.to_string(name))
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec clone(
          atom(),
          %{url: String.t(), branch: String.t() | nil, ref: String.t() | nil},
          String.t()
        ) ::
          {:ok, String.t()} | {:error, String.t()}
  defp clone(name, git_opts, dest) do
    File.mkdir_p!(Path.dirname(dest))

    args = build_clone_args(git_opts, dest)

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_output, 0} ->
        maybe_checkout_ref(name, git_opts, dest)

      {output, _} ->
        {:error, "git clone failed for #{name}: #{String.trim(output)}"}
    end
  end

  @spec build_clone_args(map(), String.t()) :: [String.t()]
  defp build_clone_args(%{url: url, branch: branch}, dest) do
    base = ["clone", "--depth", "1"]

    branch_args =
      if branch do
        ["--branch", branch]
      else
        []
      end

    base ++ branch_args ++ [url, dest]
  end

  @spec maybe_checkout_ref(atom(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp maybe_checkout_ref(_name, %{ref: nil}, dest), do: {:ok, dest}

  defp maybe_checkout_ref(name, %{ref: ref}, dest) do
    # For a specific ref, we need to unshallow first to access it
    git(dest, ["fetch", "--unshallow", "origin"])

    case git(dest, ["checkout", ref]) do
      {_output, 0} -> {:ok, dest}
      {output, _} -> {:error, "checkout ref #{ref} failed for #{name}: #{String.trim(output)}"}
    end
  end

  @spec fetch_and_compare(atom(), map(), String.t()) ::
          {:ok, update_info()} | :up_to_date | {:error, String.t()}
  defp fetch_and_compare(name, git_opts, dest) do
    # Pinned refs don't get updates
    if git_opts.ref do
      :up_to_date
    else
      do_fetch_and_compare(name, git_opts, dest)
    end
  end

  @spec do_fetch_and_compare(atom(), map(), String.t()) ::
          {:ok, update_info()} | :up_to_date | {:error, String.t()}
  defp do_fetch_and_compare(name, git_opts, dest) do
    case git(dest, ["fetch", "origin"]) do
      {_output, 0} ->
        compare_refs(name, git_opts, dest)

      {output, _} ->
        {:error, "fetch failed for #{name}: #{String.trim(output)}"}
    end
  end

  @spec compare_refs(atom(), map(), String.t()) ::
          {:ok, update_info()} | :up_to_date
  defp compare_refs(name, git_opts, dest) do
    branch = git_opts.branch || "main"
    remote_ref = "origin/#{branch}"

    {old_ref, 0} = git(dest, ["rev-parse", "--short", "HEAD"])
    {new_ref, 0} = git(dest, ["rev-parse", "--short", remote_ref])

    old_ref = String.trim(old_ref)
    new_ref = String.trim(new_ref)

    if old_ref == new_ref do
      :up_to_date
    else
      {count_str, 0} = git(dest, ["rev-list", "--count", "HEAD..#{remote_ref}"])
      count = count_str |> String.trim() |> String.to_integer()

      {:ok,
       %{
         name: name,
         old_ref: old_ref,
         new_ref: new_ref,
         commit_count: count,
         branch: branch
       }}
    end
  end

  @spec git(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  defp git(dir, args) do
    System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end
end
