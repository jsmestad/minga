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

  defp dispatch(_cwd, ["status", "--porcelain"], opts) do
    if Keyword.get(opts, :dirty_parent, false), do: {:ok, "?? dirty.txt\n"}, else: {:ok, ""}
  end

  defp dispatch(_cwd, ["ls-files", "-v", "-z"], _opts), do: {:ok, ""}

  defp dispatch(
         cwd,
         [
           "status",
           "--porcelain=v1",
           "--untracked-files=all",
           "--ignored=matching",
           "--ignore-submodules=none"
         ],
         opts
       ),
       do: child_status_result(cwd, opts)

  defp dispatch(cwd, ["rev-parse", "HEAD"], opts) do
    if cwd != Keyword.fetch!(opts, :root) and Keyword.get(opts, :committed_child, false),
      do: {:ok, "different-sha\n"},
      else: {:ok, "test-base-sha\n"}
  end

  defp dispatch(_cwd, ["worktree", "add", "-b", _branch, path, _sha], opts) do
    File.mkdir_p!(path)

    if gate = Keyword.get(opts, :setup_gate) do
      send(Keyword.fetch!(opts, :test_pid), {:worktree_allocated, self(), gate, path})

      receive do
        {^gate, :continue} -> :ok
      end
    end

    if Keyword.get(opts, :partial_setup, false) do
      File.write!(Path.join(path, "hook-output.txt"), "written before index setup failed")
      {:error, "post-checkout failed"}
    else
      {:ok, ""}
    end
  end

  defp dispatch(_cwd, ["worktree", "remove", path], opts) do
    if gate = Keyword.get(opts, :disposal_gate) do
      send(Keyword.fetch!(opts, :test_pid), {:worktree_disposing, self(), gate, path})

      receive do
        {^gate, :continue} -> :ok
      end
    end

    if Keyword.get(opts, :late_user_edit, false) do
      File.write!(Path.join(path, "draft.txt"), "unsaved to Git\n")
    end

    case File.rmdir(path) do
      :ok -> {:ok, ""}
      {:error, reason} -> {:error, Atom.to_string(reason)}
    end
  end

  defp dispatch(_cwd, ["update-ref", "-d", _branch, _expected_base], _opts), do: {:ok, ""}
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
