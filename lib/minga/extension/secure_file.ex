defmodule Minga.Extension.SecureFile do
  @moduledoc false

  @open_timeout 1_000

  @type read_error ::
          {:non_regular_file, String.t(), atom()}
          | {:file_too_large, String.t(), non_neg_integer(), pos_integer()}
          | {:file_changed_during_read, String.t()}
          | {:file_read_failed, String.t(), File.posix() | term()}

  @doc "Reads one regular file through a verified descriptor without following a symlink."
  @spec read(String.t(), pos_integer()) :: {:ok, binary()} | {:error, read_error()}
  def read(path, max_bytes) when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    task = Task.async(fn -> do_read(path, max_bytes) end)

    case Task.yield(task, @open_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, {:file_read_failed, path, :open_timeout}}
      {:exit, reason} -> {:error, {:file_read_failed, path, reason}}
    end
  end

  @spec do_read(String.t(), pos_integer()) :: {:ok, binary()} | {:error, read_error()}
  defp do_read(path, max_bytes) do
    with {:ok, before_stat} <- lstat_regular(path),
         {:ok, device} <- open(path) do
      try do
        read_opened(device, path, before_stat, max_bytes)
      after
        File.close(device)
      end
    else
      {:error, _reason} = error -> error
    end
  end

  @spec lstat_regular(String.t()) :: {:ok, File.Stat.t()} | {:error, read_error()}
  defp lstat_regular(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      {:ok, %File.Stat{type: type}} -> {:error, {:non_regular_file, path, type}}
      {:error, reason} -> {:error, {:file_read_failed, path, reason}}
    end
  end

  @spec open(String.t()) :: {:ok, IO.device()} | {:error, read_error()}
  defp open(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, device} -> {:ok, device}
      {:error, reason} -> {:error, {:file_read_failed, path, reason}}
    end
  end

  @spec read_opened(IO.device(), String.t(), File.Stat.t(), pos_integer()) ::
          {:ok, binary()} | {:error, read_error()}
  defp read_opened(device, path, before_stat, max_bytes) do
    with {:ok, descriptor_stat} <- descriptor_stat(device, path),
         :ok <- regular_descriptor(descriptor_stat, path),
         :ok <- same_file(before_stat, descriptor_stat, path),
         :ok <- size_within_limit(descriptor_stat.size, path, max_bytes),
         {:ok, binary} <- bounded_read(device, path, max_bytes),
         {:ok, after_stat} <- lstat_regular(path),
         :ok <- same_file(descriptor_stat, after_stat, path) do
      {:ok, binary}
    end
  end

  @spec descriptor_stat(IO.device(), String.t()) ::
          {:ok, File.Stat.t()} | {:error, read_error()}
  defp descriptor_stat(device, path) do
    case :file.read_file_info(device, [{:time, :posix}]) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, reason} -> {:error, {:file_read_failed, path, reason}}
    end
  end

  @spec regular_descriptor(File.Stat.t(), String.t()) :: :ok | {:error, read_error()}
  defp regular_descriptor(%File.Stat{type: :regular}, _path), do: :ok

  defp regular_descriptor(%File.Stat{type: type}, path),
    do: {:error, {:non_regular_file, path, type}}

  @spec same_file(File.Stat.t(), File.Stat.t(), String.t()) :: :ok | {:error, read_error()}
  defp same_file(first, second, path) do
    if identity(first) == identity(second),
      do: :ok,
      else: {:error, {:file_changed_during_read, path}}
  end

  @spec identity(File.Stat.t()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}

  @spec size_within_limit(non_neg_integer(), String.t(), pos_integer()) ::
          :ok | {:error, read_error()}
  defp size_within_limit(size, _path, max_bytes) when size <= max_bytes, do: :ok

  defp size_within_limit(size, path, max_bytes),
    do: {:error, {:file_too_large, path, size, max_bytes}}

  @spec bounded_read(IO.device(), String.t(), pos_integer()) ::
          {:ok, binary()} | {:error, read_error()}
  defp bounded_read(device, path, max_bytes) do
    case IO.binread(device, max_bytes + 1) do
      binary when is_binary(binary) and byte_size(binary) <= max_bytes ->
        {:ok, binary}

      binary when is_binary(binary) ->
        {:error, {:file_too_large, path, byte_size(binary), max_bytes}}

      :eof ->
        {:ok, <<>>}

      {:error, reason} ->
        {:error, {:file_read_failed, path, reason}}
    end
  end
end
