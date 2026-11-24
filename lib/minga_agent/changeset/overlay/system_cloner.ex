defmodule MingaAgent.Changeset.Overlay.SystemCloner do
  @moduledoc """
  Clones a tree with one `cp` process using the filesystem's copy-on-write support.

  * **macOS:** `cp -c` clones every file with `clonefile(2)`. When cloning is not possible, `cp -c` silently copies bytes instead, so this module first requires the source and the target's parent to be on the same volume and that volume to be APFS (`df -t apfs`).
  * **Linux:** `cp --reflink=always` fails instead of copying when the filesystem cannot share blocks (ext4, or two different filesystems).

  Other platforms are not supported. Every failure is returned as `{:error, reason}`, never as a byte copy.
  """

  @behaviour MingaAgent.Changeset.Overlay.Cloner

  @impl true
  @spec clone(String.t(), String.t()) :: :ok | {:error, term()}
  def clone(source, target) when is_binary(source) and is_binary(target) do
    clone(:os.type(), source, target)
  end

  @spec clone({atom(), atom()}, String.t(), String.t()) :: :ok | {:error, term()}
  defp clone({:unix, :darwin}, source, target) do
    parent = Path.dirname(target)

    with :ok <- same_volume(source, parent),
         :ok <- apfs(parent) do
      cp(["-c", "-R", "-p", "--", source, target])
    end
  end

  defp clone({:unix, _os}, source, target) do
    cp(["--reflink=always", "-R", "-p", "--", source, target])
  end

  defp clone(os, _source, _target), do: {:error, {:unsupported_platform, os}}

  @impl true
  @spec remove(String.t()) :: :ok | {:error, term()}
  def remove(path) when is_binary(path) do
    case run("rm", ["-rf", "--", path]) do
      :ok -> :ok
      {:error, {:missing_executable, _command}} -> remove_in_beam(path)
      {:error, _reason} = error -> error
    end
  end

  @spec remove_in_beam(String.t()) :: :ok | {:error, term()}
  defp remove_in_beam(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, _file} -> {:error, reason}
    end
  end

  @spec same_volume(String.t(), String.t()) :: :ok | {:error, term()}
  defp same_volume(source, parent) do
    with {:ok, %File.Stat{major_device: device}} <- File.lstat(source),
         {:ok, %File.Stat{major_device: ^device}} <- File.stat(parent) do
      :ok
    else
      {:ok, %File.Stat{}} -> {:error, :different_volume}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec apfs(String.t()) :: :ok | {:error, term()}
  defp apfs(dir) do
    case run("df", ["-t", "apfs", dir]) do
      :ok -> :ok
      {:error, {:exit, _status, _output}} -> {:error, :not_apfs}
      {:error, _reason} = error -> error
    end
  end

  @spec cp([String.t()]) :: :ok | {:error, term()}
  defp cp(args), do: run("cp", args)

  @spec run(String.t(), [String.t()]) :: :ok | {:error, term()}
  defp run(command, args) do
    case System.find_executable(command) do
      nil ->
        {:error, {:missing_executable, command}}

      executable ->
        case System.cmd(executable, args, stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:exit, status, String.trim(output)}}
        end
    end
  end
end
