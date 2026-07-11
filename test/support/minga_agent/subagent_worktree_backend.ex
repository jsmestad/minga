defmodule Minga.Test.SubagentWorktreeBackend do
  @moduledoc false

  @behaviour MingaAgent.Subagent.Worktree.Backend

  @impl MingaAgent.Subagent.Worktree.Backend
  def run(cwd, args, opts) do
    notify(opts, cwd, args)
    dispatch(cwd, args, opts)
  end

  @spec dispatch(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp dispatch(_cwd, ["rev-parse", "--show-toplevel"], opts),
    do: {:ok, Keyword.fetch!(opts, :root) <> "\n"}

  defp dispatch(cwd, ["status", "--porcelain"], opts) do
    root = Keyword.fetch!(opts, :root)

    if cwd == root do
      if Keyword.get(opts, :dirty_parent, false), do: {:ok, "?? dirty.txt\n"}, else: {:ok, ""}
    else
      child_status_result(cwd, opts)
    end
  end

  defp dispatch(_cwd, ["rev-parse", "HEAD"], _opts), do: {:ok, "test-base-sha\n"}

  defp dispatch(_cwd, ["worktree", "add", "-b", _branch, path, _sha], _opts) do
    File.mkdir_p!(path)
    {:ok, ""}
  end

  defp dispatch(_cwd, ["rev-list", "--count", "HEAD", _base], opts) do
    {:ok, if(Keyword.get(opts, :committed_child, false), do: "1\n", else: "0\n")}
  end

  defp dispatch(_cwd, ["worktree", "remove", "--force", path], _opts) do
    File.rm_rf!(path)
    {:ok, ""}
  end

  defp dispatch(_cwd, ["branch", "-D", _branch], _opts), do: {:ok, ""}
  defp dispatch(_cwd, args, _opts), do: {:error, "unexpected fake git command: #{inspect(args)}"}

  @spec child_status_result(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp child_status_result(path, opts) do
    if Keyword.get(opts, :inspection_error, false) do
      {:error, "inspection failed"}
    else
      case File.ls(path) do
        {:ok, []} -> {:ok, ""}
        {:ok, _entries} -> {:ok, "?? child.txt\n"}
        {:error, _reason} -> {:ok, ""}
      end
    end
  end

  @spec notify(keyword(), String.t(), [String.t()]) :: :ok
  defp notify(opts, cwd, args) do
    case Keyword.get(opts, :test_pid) do
      pid when is_pid(pid) -> send(pid, {:worktree_command, cwd, args})
      _other -> :ok
    end

    :ok
  end
end
