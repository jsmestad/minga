defmodule MingaAgent.Changeset.Overlay.NativeCloner do
  @moduledoc """
  Clones a tree with the `minga-clone-tree` helper in `priv`, built by `mix native.build.support`.

  * **macOS:** one `clonefile(2)` call clones the whole directory tree, so the cost is one system call rather than one per file.
  * **Linux:** there is no directory clone call, so the helper walks the tree and clones each regular file with the `FICLONE` ioctl (Btrfs, XFS with reflink, and other file systems that share blocks).

  The helper never copies bytes. Its exit status separates "cloning is not possible here" (a volume that cannot clone, such as HFS+ or ext4; two different file systems; a special file in the tree; a relative symlink that resolves outside the tree, which would dangle in the clone) from real failures; `exit_result/2` maps it. A missing helper also counts as unsupported, the same as a volume that cannot clone.
  """

  @behaviour MingaAgent.Changeset.Overlay.Cloner

  alias MingaAgent.Changeset.Overlay.Cloner

  @helper_name "minga-clone-tree"

  # Exit statuses from zig/src/clone_tree_main.zig.
  @exit_cloned 0
  @exit_unsupported 3

  @impl true
  @spec clone(String.t(), String.t()) :: :ok | {:error, Cloner.error()}
  def clone(source, target) when is_binary(source) and is_binary(target) do
    helper = Path.join(:code.priv_dir(:minga), @helper_name)

    if File.regular?(helper) do
      {output, status} = System.cmd(helper, [source, target], stderr_to_stdout: true)
      exit_result(status, output)
    else
      {:error, {:unsupported, {:helper_not_found, helper}}}
    end
  end

  @doc """
  Maps the helper's exit status and output to a clone result.

  Status 0 is a complete clone, and status 3 means cloning is not possible here. Every other status is a real failure, including a usage error or a crash. The reason keeps the first output line, which names the failing operation, path, and errno.
  """
  @spec exit_result(non_neg_integer(), String.t()) :: :ok | {:error, Cloner.error()}
  def exit_result(@exit_cloned, _output), do: :ok
  def exit_result(@exit_unsupported, output), do: {:error, {:unsupported, first_line(output)}}
  def exit_result(status, output), do: {:error, {:clone_failed, status, first_line(output)}}

  @impl true
  @spec remove(String.t()) :: :ok | {:error, term()}
  def remove(path) when is_binary(path) do
    case System.find_executable("rm") do
      nil -> remove_in_beam(path)
      rm -> remove_with(rm, path)
    end
  end

  @spec remove_with(String.t(), String.t()) :: :ok | {:error, term()}
  defp remove_with(rm, path) do
    case System.cmd(rm, ["-rf", "--", path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:remove_failed, status, first_line(output)}}
    end
  end

  @spec remove_in_beam(String.t()) :: :ok | {:error, term()}
  defp remove_in_beam(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, _file} -> {:error, reason}
    end
  end

  @spec first_line(String.t()) :: String.t()
  defp first_line(output), do: output |> String.trim() |> String.split("\n", parts: 2) |> hd()
end
