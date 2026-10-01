defmodule MingaAgent.ArtifactStorage.Files do
  @moduledoc "Private regular-file operations for retained artifact storage."

  @type io_device :: :file.io_device()

  @doc "Creates or validates one private directory without following a final symlink."
  @spec ensure_private_directory(String.t()) :: :ok | {:error, term()}
  def ensure_private_directory(path) when is_binary(path) do
    expanded = Path.expand(path)

    case File.lstat(expanded) do
      {:ok, %File.Stat{type: :directory}} -> File.chmod(expanded, 0o700)
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_artifact_directory, expanded, type}}
      {:error, :enoent} -> create_private_directory(expanded)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Rejects an existing non-regular path and makes an existing file private."
  @spec ensure_regular_or_missing(String.t()) :: :ok | {:error, term()}
  def ensure_regular_or_missing(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> File.chmod(path, 0o600)
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_artifact_file, path, type}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Creates an exclusive private capture file and writes its admitted header."
  @spec create_capture_file(String.t(), binary()) :: {:ok, io_device()} | {:error, term()}
  def create_capture_file(path, header) when is_binary(path) and is_binary(header) do
    with :ok <- ensure_missing(path),
         {:ok, io} <- :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      initialize_created_file(path, io, header)
    else
      {:error, :eexist} -> {:error, :capture_file_exists}
      {:error, _reason} = error -> error
    end
  end

  @doc "Opens an existing private regular file for bounded reads."
  @spec open_read(String.t()) :: {:ok, io_device()} | {:error, term()}
  def open_read(path) when is_binary(path) do
    with :ok <- require_regular(path) do
      :file.open(String.to_charlist(path), [:read, :binary, :raw])
    end
  end

  @doc "Opens an existing private regular file for bounded in-place recovery."
  @spec open_read_write(String.t()) :: {:ok, io_device()} | {:error, term()}
  def open_read_write(path) when is_binary(path) do
    with :ok <- require_regular(path) do
      :file.open(String.to_charlist(path), [:read, :write, :binary, :raw])
    end
  end

  @doc "Returns a regular file's byte size without following symlinks."
  @spec regular_size(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def regular_size(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_artifact_file, path, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Renames a private regular file without replacing another path."
  @spec rename(String.t(), String.t()) :: :ok | {:error, term()}
  def rename(source, destination) when is_binary(source) and is_binary(destination) do
    with :ok <- require_regular(source),
         :ok <- ensure_missing(destination) do
      File.rename(source, destination)
    end
  end

  @doc "Deletes one private regular file. Missing files are already deleted."
  @spec remove_regular(String.t()) :: :ok | {:error, term()}
  def remove_regular(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> File.rm(path)
      {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_artifact_file, path, type}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Synchronizes an existing private regular file."
  @spec sync_regular(String.t()) :: :ok | {:error, term()}
  def sync_regular(path) when is_binary(path) do
    with :ok <- require_regular(path),
         {:ok, io} <- :file.open(String.to_charlist(path), [:append, :binary, :raw]) do
      result = :file.sync(io)
      _ = close(io)
      result
    end
  end

  @doc "Synchronizes a directory entry update when the platform permits directory handles."
  @spec sync_directory(String.t()) :: :ok | {:error, term()}
  def sync_directory(path) when is_binary(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, io} ->
        result = :file.sync(io)
        _ = :file.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Durably removes one flat private directory and every regular file it owns."
  @spec remove_private_directory(String.t()) :: :ok | {:error, term()}
  def remove_private_directory(path) when is_binary(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        remove_directory_entries(path)

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_artifact_directory, path, type}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec remove_directory_entries(String.t()) :: :ok | {:error, term()}
  defp remove_directory_entries(path) do
    with {:ok, entries} <- File.ls(path),
         :ok <- validate_regular_entries(path, entries),
         :ok <- remove_regular_entries(path, deletion_order(entries)),
         :ok <- File.rmdir(path),
         :ok <- sync_directory(Path.dirname(path)) do
      :ok
    end
  end

  @spec validate_regular_entries(String.t(), [String.t()]) :: :ok | {:error, term()}
  defp validate_regular_entries(path, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      candidate = Path.join(path, entry)

      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :regular}} -> {:cont, :ok}
        {:ok, %File.Stat{type: type}} -> {:halt, {:error, {:unsafe_artifact_file, candidate, type}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec remove_regular_entries(String.t(), [String.t()]) :: :ok | {:error, term()}
  defp remove_regular_entries(path, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case remove_regular(Path.join(path, entry)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec deletion_order([String.t()]) :: [String.t()]
  defp deletion_order(entries) do
    Enum.sort_by(entries, fn entry ->
      priority = if entry == "artifacts.sqlite3", do: 1, else: 0
      {priority, entry}
    end)
  end

  @doc "Closes a file, treating an already closed descriptor as closed."
  @spec close(io_device() | nil) :: :ok
  def close(nil), do: :ok

  def close(io) do
    case :file.close(io) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  @spec create_private_directory(String.t()) :: :ok | {:error, term()}
  defp create_private_directory(path) do
    with :ok <- File.mkdir_p(path),
         :ok <- File.chmod(path, 0o700) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> :ok
        {:ok, %File.Stat{type: type}} -> {:error, {:unsafe_artifact_directory, path, type}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec require_regular(String.t()) :: :ok | {:error, term()}
  defp require_regular(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        with :ok <- File.chmod(path, 0o600), do: :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_artifact_file, path, type}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec ensure_missing(String.t()) :: :ok | {:error, term()}
  defp ensure_missing(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:artifact_destination_exists, path, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec initialize_created_file(String.t(), io_device(), binary()) ::
          {:ok, io_device()} | {:error, term()}
  defp initialize_created_file(path, io, header) do
    result =
      with :ok <- File.chmod(path, 0o600),
           :ok <- :file.write(io, header) do
        :ok
      end

    case result do
      :ok ->
        {:ok, io}

      {:error, _reason} = error ->
        _ = close(io)
        _ = remove_created_file(path)
        error
    end
  end

  @spec remove_created_file(String.t()) :: :ok
  defp remove_created_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end
end
