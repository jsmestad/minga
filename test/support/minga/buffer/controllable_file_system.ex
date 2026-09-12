defmodule Minga.Buffer.ControllableFileSystem do
  @moduledoc "Deterministic file-system backend for local-save failure and commit-boundary tests."

  @behaviour Minga.Buffer.Persistence.FileSystem

  alias Minga.Buffer.Persistence.SystemFileSystem

  @impl Minga.Buffer.Persistence.FileSystem
  @spec lstat(String.t(), keyword()) :: {:ok, File.Stat.t()} | {:error, term()}
  def lstat(path, opts), do: SystemFileSystem.lstat(path, opts)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec read_link(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def read_link(path, opts), do: SystemFileSystem.read_link(path, opts)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec stat(String.t(), keyword()) :: {:ok, File.Stat.t()} | {:error, term()}
  def stat(path, opts), do: SystemFileSystem.stat(path, opts)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec mkdir_p(String.t(), keyword()) :: :ok | {:error, term()}
  def mkdir_p(path, opts), do: SystemFileSystem.mkdir_p(path, opts)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec open_exclusive(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def open_exclusive(path, opts) do
    secured_opts = maybe_inject_open_permissions(opts)
    opened = maybe_run(opts, :open, fn -> SystemFileSystem.open_exclusive(path, secured_opts) end)
    maybe_pause_after_open(opened, path, opts)
  end

  @impl Minga.Buffer.Persistence.FileSystem
  @spec write(term(), binary(), keyword()) :: :ok | {:error, term()}
  def write(device, content, opts) do
    maybe_run(opts, :write, fn -> SystemFileSystem.write(device, content, opts) end)
  end

  @impl Minga.Buffer.Persistence.FileSystem
  @spec preserve_metadata(String.t(), File.Stat.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def preserve_metadata(path, metadata, opts) do
    maybe_run(opts, :metadata, fn ->
      SystemFileSystem.preserve_metadata(path, metadata, opts)
    end)
  end

  @impl Minga.Buffer.Persistence.FileSystem
  @spec flush(term(), keyword()) :: :ok | {:error, term()}
  def flush(device, opts) do
    maybe_run(opts, :flush, fn -> SystemFileSystem.flush(device, opts) end)
  end

  @impl Minga.Buffer.Persistence.FileSystem
  @spec close(term(), keyword()) :: :ok | {:error, term()}
  def close(device, opts), do: SystemFileSystem.close(device, opts)

  @impl Minga.Buffer.Persistence.FileSystem
  @spec rename(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def rename(source, destination, opts) do
    before_commit(opts, source, destination)
    maybe_run(opts, :rename, fn -> SystemFileSystem.rename(source, destination, opts) end)
  end

  @impl Minga.Buffer.Persistence.FileSystem
  @spec link(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def link(source, destination, opts) do
    before_commit(opts, source, destination)
    maybe_run(opts, :rename, fn -> SystemFileSystem.link(source, destination, opts) end)
  end

  @impl Minga.Buffer.Persistence.FileSystem
  @spec remove(String.t(), keyword()) :: :ok | {:error, term()}
  def remove(path, opts) do
    maybe_run(opts, :cleanup, fn -> SystemFileSystem.remove(path, opts) end)
  end

  @spec maybe_run(keyword(), atom(), (-> result)) :: result when result: term()
  defp maybe_run(opts, stage, operation) do
    case Keyword.get(opts, :fail_at) do
      ^stage -> {:error, {:injected, stage}}
      _other -> operation.()
    end
  end

  @spec before_commit(keyword(), String.t(), String.t()) :: :ok
  defp before_commit(opts, source, destination) do
    case Keyword.get(opts, :controller) do
      nil ->
        :ok

      controller ->
        send(controller, {:local_save_before_commit, self(), source, destination})

        receive do
          :continue_local_save_commit -> :ok
        end
    end
  end

  @spec maybe_inject_open_permissions(keyword()) :: keyword()
  defp maybe_inject_open_permissions(opts) do
    case Keyword.get(opts, :fail_at) do
      :open_permissions ->
        Keyword.put(opts, :temporary_chmod, fn _path, _mode ->
          {:error, {:injected, :open_permissions}}
        end)

      _other ->
        opts
    end
  end

  @spec maybe_pause_after_open({:ok, term()} | {:error, term()}, String.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  defp maybe_pause_after_open({:ok, _device} = opened, path, opts) do
    case Keyword.get(opts, :open_controller) do
      nil ->
        opened

      controller ->
        send(controller, {:local_save_temp_opened, self(), path})

        receive do
          :continue_local_save_write -> opened
        end
    end
  end

  defp maybe_pause_after_open({:error, _reason} = error, _path, _opts), do: error
end
