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

  @typedoc "A single file change in a worktree: action and relative path."
  @type change :: {:added | :modified | :deleted, String.t()}

  @doc "Formats the location and branch metadata for a preserved worktree."
  @spec metadata(t()) :: String.t()
  def metadata(%__MODULE__{} = worktree) do
    "\n\nWorktree: #{worktree.path}\nBranch: #{worktree.branch}"
  end

  @doc "Collects structured file changes from a worktree relative to its base SHA."
  @spec collect_changes(t()) :: {:ok, [change()]} | {:error, String.t()}
  def collect_changes(%__MODULE__{} = worktree) do
    with {:ok, committed} <- committed_changes(worktree),
         {:ok, uncommitted} <- uncommitted_changes(worktree) do
      {:ok, merge_changes(committed, uncommitted)}
    end
  end

  @doc "Collects changes from a worktree path and base SHA using the system backend."
  @spec collect_changes_from(String.t(), String.t()) :: {:ok, [change()]} | {:error, String.t()}
  def collect_changes_from(worktree_path, base_sha)
      when is_binary(worktree_path) and is_binary(base_sha) do
    with {:ok, committed} <- git_diff(worktree_path, base_sha, "HEAD"),
         {:ok, uncommitted} <- git_diff(worktree_path, "HEAD", nil) do
      {:ok, merge_changes(committed, uncommitted)}
    end
  end

  @doc "Reads the content of a changed file from the worktree."
  @spec read_file(t(), String.t()) :: {:ok, binary()} | {:error, String.t()}
  def read_file(%__MODULE__{path: wt_path}, relative_path) do
    full_path = Path.join(wt_path, relative_path)

    case File.read(full_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Failed to read #{relative_path}: #{inspect(reason)}"}
    end
  end

  @doc "Reads the base version of a file from the worktree's base SHA."
  @spec read_base_file(t(), String.t()) :: {:ok, binary()} | {:error, String.t()}
  def read_base_file(%__MODULE__{} = worktree, relative_path) do
    case output(worktree, worktree.path, ["show", "#{worktree.base_sha}:#{relative_path}"]) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, "File #{relative_path} not in base revision"}
    end
  end

  @spec git_diff(String.t(), String.t(), String.t() | nil) ::
          {:ok, [change()]} | {:error, String.t()}
  defp git_diff(cwd, from, nil) do
    case System.run(cwd, ["diff", "--name-status", from], []) do
      {:ok, ""} -> {:ok, []}
      {:ok, output} -> {:ok, parse_name_status(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_diff(cwd, from, to) do
    case System.run(cwd, ["diff", "--name-status", from, to], []) do
      {:ok, ""} -> {:ok, []}
      {:ok, output} -> {:ok, parse_name_status(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec committed_changes(t()) :: {:ok, [change()]} | {:error, String.t()}
  defp committed_changes(%__MODULE__{} = worktree) do
    case output(worktree, worktree.path, [
           "diff",
           "--name-status",
           worktree.base_sha,
           "HEAD"
         ]) do
      {:ok, ""} -> {:ok, []}
      {:ok, diff_output} -> {:ok, parse_name_status(diff_output)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec uncommitted_changes(t()) :: {:ok, [change()]} | {:error, String.t()}
  defp uncommitted_changes(%__MODULE__{} = worktree) do
    case output(worktree, worktree.path, ["diff", "--name-status", "HEAD"]) do
      {:ok, ""} -> {:ok, []}
      {:ok, diff_output} -> {:ok, parse_name_status(diff_output)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec parse_name_status(String.t()) :: [change()]
  defp parse_name_status(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, "\t", parts: 2) do
        ["A", path] -> {:added, path}
        ["M", path] -> {:modified, path}
        ["D", path] -> {:deleted, path}
        [status, path] when byte_size(status) > 0 -> {:modified, path}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @spec merge_changes([change()], [change()]) :: [change()]
  defp merge_changes(committed, uncommitted) do
    committed_map = Map.new(committed, fn {action, path} -> {path, action} end)
    uncommitted_map = Map.new(uncommitted, fn {action, path} -> {path, action} end)
    merged = Map.merge(committed_map, uncommitted_map)
    Enum.map(merged, fn {path, action} -> {action, path} end)
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
