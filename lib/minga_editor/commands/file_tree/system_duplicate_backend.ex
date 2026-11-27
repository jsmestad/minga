defmodule MingaEditor.Commands.FileTree.SystemDuplicateBackend do
  @moduledoc "Claims and copies filesystem destinations on behalf of the file-tree copy worker."

  @behaviour MingaEditor.Commands.FileTree.DuplicateBackend

  alias MingaEditor.Commands.FileTree.DuplicateBackend

  @typep owned :: [DuplicateBackend.owned_entry()]
  @typep copy_step :: {:ok, owned()} | {:error, term(), String.t(), owned()}

  @impl true
  @spec claim_destination(String.t(), DuplicateBackend.entry_type(), DuplicateBackend.context()) ::
          {:ok, DuplicateBackend.claim()} | {:error, term()}
  def claim_destination(path, :directory, _context) do
    with :ok <- File.mkdir(path),
         {:ok, entry} <- new_path_entry(path, :directory) do
      {:ok, {entry, nil}}
    end
  end

  def claim_destination(path, :file, _context) do
    with {:ok, device} <- File.open(path, [:write, :exclusive, :raw]) do
      case :file.read_file_info(device, time: :posix) do
        {:ok, info} ->
          entry = {path, :regular, identity(File.Stat.from_record(info))}
          {:ok, {entry, device}}

        {:error, reason} ->
          _ = File.close(device)
          {:error, reason}
      end
    end
  end

  @impl true
  @spec copy(String.t(), DuplicateBackend.claim(), DuplicateBackend.context()) ::
          DuplicateBackend.copy_result()
  def copy(source, {entry, _device} = claim, _context) do
    case copy_claimed(source, claim, [entry]) do
      {:ok, _owned} -> :ok
      {:error, _, _, _} = error -> error
    end
  end

  @spec copy_claimed(String.t(), DuplicateBackend.claim(), owned()) :: copy_step()
  defp copy_claimed(source, {{target, :directory, _} = entry, nil}, owned) do
    case require_owned(entry) do
      :ok ->
        case File.ls(source) do
          {:ok, names} -> copy_children(names, source, entry, owned)
          {:error, reason} -> {:error, reason, source, owned}
        end

      {:error, reason} ->
        {:error, reason, target, owned}
    end
  end

  defp copy_claimed(source, {{target, :regular, _} = entry, device}, owned) do
    result =
      try do
        with {:ok, mode} <- regular_file_mode(source),
             {:ok, _bytes} <- File.copy(source, device),
             :ok <- require_owned(entry) do
          File.chmod(target, mode)
        end
      after
        File.close(device)
      end

    case result do
      :ok -> {:ok, owned}
      {:error, reason} -> {:error, reason, source, owned}
    end
  end

  @spec copy_children([String.t()], String.t(), DuplicateBackend.owned_entry(), owned()) ::
          copy_step()
  defp copy_children([], _source, _parent, owned), do: {:ok, owned}

  defp copy_children([name | rest], source, {target, _, _} = parent, owned) do
    with :ok <- require_owned(parent),
         {:ok, owned} <- copy_child(Path.join(source, name), Path.join(target, name), owned) do
      copy_children(rest, source, parent, owned)
    else
      {:error, _, _, _} = error -> error
      {:error, reason} -> {:error, reason, target, owned}
    end
  end

  @spec copy_child(String.t(), String.t(), owned()) :: copy_step()
  defp copy_child(source, target, owned) do
    case File.lstat(source, time: :posix) do
      {:ok, %File.Stat{type: :directory}} -> claim_child(source, target, :directory, owned)
      {:ok, %File.Stat{type: :regular}} -> claim_child(source, target, :file, owned)
      {:ok, %File.Stat{type: :symlink}} -> copy_link(source, target, owned)
      {:ok, _special_file} -> {:ok, owned}
      {:error, reason} -> {:error, reason, source, owned}
    end
  end

  @spec claim_child(String.t(), String.t(), DuplicateBackend.entry_type(), owned()) :: copy_step()
  defp claim_child(source, target, kind, owned) do
    case claim_destination(target, kind, nil) do
      {:ok, {entry, _device} = claim} -> copy_claimed(source, claim, [entry | owned])
      {:error, reason} -> {:error, reason, target, owned}
    end
  end

  @spec copy_link(String.t(), String.t(), owned()) :: copy_step()
  defp copy_link(source, target, owned) do
    with {:ok, link} <- File.read_link(source),
         :ok <- File.ln_s(link, target),
         {:ok, entry} <- new_path_entry(target, :symlink) do
      {:ok, [entry | owned]}
    else
      {:error, reason} -> {:error, reason, target, owned}
    end
  end

  @spec regular_file_mode(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp regular_file_mode(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> {:ok, mode}
      {:ok, _other} -> {:error, :source_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec new_path_entry(String.t(), :directory | :symlink) ::
          {:ok, DuplicateBackend.owned_entry()} | {:error, term()}
  defp new_path_entry(path, type) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: ^type} = stat} -> {:ok, {path, type, identity(stat)}}
      {:ok, _replacement} -> {:error, :destination_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec identity(File.Stat.t()) :: DuplicateBackend.identity()
  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}

  @spec require_owned(DuplicateBackend.owned_entry()) :: :ok | {:error, term()}
  defp require_owned({path, type, expected}) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: ^type} = stat} ->
        if identity(stat) == expected, do: :ok, else: {:error, :destination_changed}

      {:ok, _replacement} ->
        {:error, :destination_changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec cleanup(owned(), DuplicateBackend.context()) :: DuplicateBackend.cleanup_result()
  def cleanup(owned, _context) do
    # Claims are newest-first, so children are removed before their parents.
    # Never use rm_rf: a failed copy may share its output directory with a
    # concurrent writer's unclaimed entry.
    Enum.reduce(owned, :ok, fn {path, _, _} = entry, first_failure ->
      case remove_owned(entry) do
        :ok -> first_failure
        {:error, :enoent} -> first_failure
        {:error, reason} when first_failure == :ok -> {:error, reason, path}
        {:error, _reason} -> first_failure
      end
    end)
  end

  @spec remove_owned(DuplicateBackend.owned_entry()) :: :ok | {:error, term()}
  defp remove_owned({path, type, _} = entry) do
    with :ok <- require_owned(entry) do
      if type == :directory, do: File.rmdir(path), else: File.rm(path)
    end
  end
end
