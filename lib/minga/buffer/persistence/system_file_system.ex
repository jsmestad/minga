defmodule Minga.Buffer.Persistence.SystemFileSystem do
  @moduledoc "Production file-system operations for atomic local saves."

  @behaviour Minga.Buffer.Persistence.FileSystem

  import Bitwise, only: [band: 2]

  @impl Minga.Buffer.Persistence.FileSystem
  @spec lstat(String.t(), keyword()) :: {:ok, File.Stat.t()} | {:error, term()}
  def lstat(path, _opts), do: File.lstat(path)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec read_link(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def read_link(path, _opts), do: File.read_link(path)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec stat(String.t(), keyword()) :: {:ok, File.Stat.t()} | {:error, term()}
  def stat(path, _opts), do: File.stat(path)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec mkdir_p(String.t(), keyword()) :: :ok | {:error, term()}
  def mkdir_p(path, _opts), do: File.mkdir_p(path)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec open_exclusive(String.t(), keyword()) ::
          {:ok, :file.io_device()} | {:error, term()}
  def open_exclusive(path, opts) do
    case :file.open(path, [:write, :binary, :raw, :exclusive]) do
      {:ok, device} -> restrict_opened_temp(path, device, opts)
      {:error, _reason} = error -> error
    end
  end

  @impl Minga.Buffer.Persistence.FileSystem
  @spec write(:file.io_device(), binary(), keyword()) :: :ok | {:error, term()}
  def write(device, content, _opts), do: :file.write(device, content)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec preserve_metadata(String.t(), File.Stat.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def preserve_metadata(_path, nil, _opts), do: :ok

  def preserve_metadata(path, %{uid: uid, gid: gid, mode: mode}, _opts) do
    with :ok <- File.chown(path, uid),
         :ok <- File.chgrp(path, gid) do
      File.chmod(path, band(mode, 0o7777))
    end
  end

  @impl Minga.Buffer.Persistence.FileSystem
  @spec flush(:file.io_device(), keyword()) :: :ok | {:error, term()}
  def flush(device, _opts), do: :file.sync(device)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec close(:file.io_device(), keyword()) :: :ok | {:error, term()}
  def close(device, _opts), do: :file.close(device)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec rename(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def rename(source, destination, _opts), do: File.rename(source, destination)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec link(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def link(source, destination, _opts), do: File.ln(source, destination)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec remove(String.t(), keyword()) :: :ok | {:error, term()}
  def remove(path, _opts), do: File.rm(path)

  @spec restrict_opened_temp(String.t(), :file.io_device(), keyword()) ::
          {:ok, :file.io_device()} | {:error, term()}
  defp restrict_opened_temp(path, device, opts) do
    chmod = Keyword.get(opts, :temporary_chmod, &File.chmod/2)

    case chmod.(path, 0o600) do
      :ok ->
        {:ok, device}

      {:error, _reason} = error ->
        close_result = :file.close(device)
        remove_result = File.rm(path)
        open_failure(error, close_result, remove_result)
    end
  end

  @spec open_failure(
          {:error, term()},
          :ok | {:error, term()},
          :ok | {:error, term()}
        ) :: {:error, term()}
  defp open_failure(error, :ok, :ok), do: error

  defp open_failure({:error, reason}, close_result, remove_result) do
    {:error, {reason, {:cleanup_failed, close_result, remove_result}}}
  end
end
