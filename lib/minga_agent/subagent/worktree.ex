defmodule MingaAgent.Subagent.Worktree do
  @moduledoc """
  Owns the Git worktree lifecycle for isolated subagents.

  A changed child worktree is preserved and described in the result. A clean
  child is removed with its temporary branch. The command backend is injectable
  so orchestration decisions can be tested without spawning OS processes.
  """

  alias MingaAgent.Subagent.Worktree.System

  @enforce_keys [:root, :path, :branch, :base_sha, :backend, :backend_opts]
  defstruct [:root, :path, :branch, :base_sha, :backend, :backend_opts]

  @type t :: %__MODULE__{
          root: String.t(),
          path: String.t(),
          branch: String.t(),
          base_sha: String.t(),
          backend: module(),
          backend_opts: keyword()
        }

  @type create_opts :: [backend: module(), backend_opts: keyword()]

  @doc "Creates an isolated child worktree from a clean Git repository."
  @spec create(String.t(), create_opts()) :: {:ok, t()} | {:error, String.t()}
  def create(project_root, opts \\ []) do
    backend = Keyword.get(opts, :backend, System)
    backend_opts = Keyword.get(opts, :backend_opts, [])

    with {:ok, root} <- git_root(project_root, backend, backend_opts),
         :ok <- require_clean_git(root, backend, backend_opts),
         {:ok, base_sha} <- output(backend, backend_opts, root, ["rev-parse", "HEAD"]),
         worktree <- new(root, String.trim(base_sha), backend, backend_opts),
         :ok <- add(worktree) do
      {:ok, worktree}
    end
  end

  @doc "Finishes a successful child, preserving changed work or cleaning a no-op child."
  @spec finish_result(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def finish_result(%__MODULE__{} = worktree, result) do
    case change_status(worktree) do
      {:ok, true} -> {:ok, result <> metadata(worktree)}
      {:ok, false} -> cleanup(worktree, {:ok, result})
      {:error, _reason} -> {:ok, result <> metadata(worktree)}
    end
  end

  @doc "Finishes a failed child without discarding any changes it produced."
  @spec finish_error(t(), String.t()) :: {:error, String.t()}
  def finish_error(%__MODULE__{} = worktree, reason) do
    case change_status(worktree) do
      {:ok, true} -> {:error, reason <> metadata(worktree)}
      {:ok, false} -> cleanup(worktree, {:error, reason})
      {:error, _inspection_reason} -> {:error, reason <> metadata(worktree)}
    end
  end

  @doc "Formats the location and branch metadata for a preserved worktree."
  @spec metadata(t()) :: String.t()
  def metadata(%__MODULE__{} = worktree) do
    "\n\nWorktree: #{worktree.path}\nBranch: #{worktree.branch}"
  end

  @spec git_root(String.t(), module(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  defp git_root(project_root, backend, backend_opts) do
    case output(backend, backend_opts, project_root, ["rev-parse", "--show-toplevel"]) do
      {:ok, root} -> {:ok, String.trim(root)}
      {:error, reason} -> {:error, "Worktree isolation requires a git repository: #{reason}"}
    end
  end

  @spec require_clean_git(String.t(), module(), keyword()) :: :ok | {:error, String.t()}
  defp require_clean_git(root, backend, backend_opts) do
    case output(backend, backend_opts, root, ["status", "--porcelain"]) do
      {:ok, ""} -> :ok
      {:ok, _dirty} -> {:error, "Worktree isolation requires a clean git tree"}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec new(String.t(), String.t(), module(), keyword()) :: t()
  defp new(root, base_sha, backend, backend_opts) do
    id = :erlang.unique_integer([:positive])

    %__MODULE__{
      root: root,
      path: Path.join(Path.dirname(root), "#{Path.basename(root)}-subagent-#{id}"),
      branch: "subagent/#{id}",
      base_sha: base_sha,
      backend: backend,
      backend_opts: backend_opts
    }
  end

  @spec add(t()) :: :ok | {:error, String.t()}
  defp add(worktree) do
    case command(worktree, worktree.root, [
           "worktree",
           "add",
           "-b",
           worktree.branch,
           worktree.path,
           worktree.base_sha
         ]) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to create subagent worktree: #{reason}"}
    end
  end

  @spec change_status(t()) :: {:ok, boolean()} | {:error, String.t()}
  defp change_status(worktree) do
    with {:ok, dirty} <- output(worktree, worktree.path, ["status", "--porcelain"]),
         {:ok, count} <-
           output(worktree, worktree.path, [
             "rev-list",
             "--count",
             "HEAD",
             "^#{worktree.base_sha}"
           ]) do
      {:ok, dirty != "" or String.trim(count) != "0"}
    end
  end

  @spec cleanup(t(), {:ok, String.t()} | {:error, String.t()}) ::
          {:ok, String.t()} | {:error, String.t()}
  defp cleanup(worktree, result) do
    case command(worktree, worktree.root, ["worktree", "remove", "--force", worktree.path]) do
      :ok -> _result = command(worktree, worktree.root, ["branch", "-D", worktree.branch])
      {:error, _reason} -> :ok
    end

    result
  end

  @spec output(t(), String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  defp output(worktree, cwd, args) do
    output(worktree.backend, worktree.backend_opts, cwd, args)
  end

  @spec output(module(), keyword(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, String.t()}
  defp output(backend, backend_opts, cwd, args), do: backend.run(cwd, args, backend_opts)

  @spec command(t(), String.t(), [String.t()]) :: :ok | {:error, String.t()}
  defp command(worktree, cwd, args) do
    case output(worktree, cwd, args) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
