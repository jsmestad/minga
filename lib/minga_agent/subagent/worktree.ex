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
  @type disposal ::
          :removed
          | {:preserved, String.t(), String.t(), :changed | {:uncertain, String.t()}}
          | {:branch_retained, String.t(), String.t()}

  @doc "Creates an isolated child worktree from a clean Git repository."
  @spec create(String.t(), create_opts()) :: {:ok, t()} | {:error, String.t()}
  def create(project_root, opts \\ []) do
    with {:ok, worktree} <- prepare(project_root, opts) do
      case allocate(worktree) do
        :ok -> {:ok, worktree}
        {:error, reason} -> {:error, reason <> "\nAllocation not verified." <> metadata(worktree)}
      end
    end
  end

  @doc "Inspects the project and plans an exact checkout without allocating it."
  @spec prepare(String.t(), create_opts()) :: {:ok, t()} | {:error, String.t()}
  def prepare(project_root, opts) do
    backend = Keyword.get(opts, :backend, System)
    backend_opts = Keyword.get(opts, :backend_opts, [])

    with {:ok, root} <- git_root(project_root, backend, backend_opts),
         :ok <- require_clean_git(root, backend, backend_opts),
         {:ok, base_sha} <- output(backend, backend_opts, root, ["rev-parse", "HEAD"]) do
      {:ok, new(root, String.trim(base_sha), backend, backend_opts)}
    end
  end

  @doc "Finishes a successful child, preserving changed work or cleaning a no-op child."
  @spec finish_result(t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def finish_result(%__MODULE__{} = worktree, result) do
    {:ok, result <> disposal_notice(dispose(worktree))}
  end

  @doc "Finishes a failed child without discarding any changes it produced."
  @spec finish_error(t(), String.t()) :: {:error, String.t()}
  def finish_error(%__MODULE__{} = worktree, reason) do
    {:error, reason <> disposal_notice(dispose(worktree))}
  end

  @doc "Removes an unchanged worktree at its exact base without discarding work on uncertainty."
  @spec dispose(t()) :: disposal()
  def dispose(%__MODULE__{} = worktree) do
    case change_status(worktree) do
      {:ok, false} -> cleanup(worktree)
      {:ok, true} -> {:preserved, worktree.path, worktree.branch, :changed}
      {:error, reason} -> {:preserved, worktree.path, worktree.branch, {:uncertain, reason}}
    end
  end

  @doc "Reports preserved work or uncertainty without altering the original subagent result."
  @spec disposal_notice(disposal()) :: String.t()
  def disposal_notice(:removed), do: ""
  def disposal_notice({:preserved, path, branch, :changed}), do: location(path, branch)

  def disposal_notice({:preserved, path, branch, {:uncertain, reason}}),
    do: location(path, branch) <> "\nWorktree retained: #{reason}"

  def disposal_notice({:branch_retained, branch, reason}),
    do: "\n\nWorktree removed; branch retained: #{branch}\n#{reason}"

  @doc "Formats the location and branch metadata for a preserved worktree."
  @spec metadata(t()) :: String.t()
  def metadata(%__MODULE__{} = worktree) do
    location(worktree.path, worktree.branch)
  end

  @spec location(String.t(), String.t()) :: String.t()
  defp location(path, branch), do: "\n\nWorktree: #{path}\nBranch: #{branch}"

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
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    %__MODULE__{
      root: root,
      path: Path.join(Path.dirname(root), "#{Path.basename(root)}-subagent-#{id}"),
      branch: "subagent/#{id}",
      base_sha: base_sha,
      backend: backend,
      backend_opts: backend_opts
    }
  end

  @doc "Allocates the planned checkout. Failure is not proof that Git made no changes."
  @spec allocate(t()) :: :ok | {:error, String.t()}
  def allocate(%__MODULE__{} = worktree) do
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
    with {:ok, entries} <- output(worktree, worktree.path, ["ls-files", "-v", "-z"]),
         :ok <- require_visible_index(entries),
         {:ok, dirty} <-
           output(worktree, worktree.path, [
             "status",
             "--porcelain=v1",
             "--untracked-files=all",
             "--ignored=matching",
             "--ignore-submodules=none"
           ]),
         {:ok, head} <- output(worktree, worktree.path, ["rev-parse", "HEAD"]) do
      {:ok, dirty != "" or String.trim(head) != worktree.base_sha}
    end
  end

  @spec require_visible_index(String.t()) :: :ok | {:error, String.t()}
  defp require_visible_index(entries) do
    if Enum.all?(:binary.split(entries, <<0>>, [:global, :trim_all]), fn
         <<"H ", _path::binary>> -> true
         _hidden -> false
       end) do
      :ok
    else
      {:error, "Git index flags hide tracked worktree paths"}
    end
  end

  @spec cleanup(t()) :: disposal()
  defp cleanup(worktree) do
    case command(worktree, worktree.root, ["worktree", "remove", worktree.path]) do
      :ok ->
        branch_ref = "refs/heads/#{worktree.branch}"

        case command(worktree, worktree.root, ["update-ref", "-d", branch_ref, worktree.base_sha]) do
          :ok -> :removed
          {:error, reason} -> {:branch_retained, worktree.branch, reason}
        end

      {:error, reason} ->
        {:preserved, worktree.path, worktree.branch, {:uncertain, reason}}
    end
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
