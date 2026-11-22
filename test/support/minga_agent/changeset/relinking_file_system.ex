defmodule MingaAgent.Changeset.RelinkingFileSystem do
  @moduledoc """
  Publication file system that turns one entry into a symlink after it has been resolved once.

  Configure it with `relink: {agent, name, link_target}` in the publication options. The first `lstat/2` of a path whose basename is `name` sees the real file; every later one reports a symlink whose `read_link/2` returns `link_target`. Every other operation delegates to `Minga.Buffer.Persistence.SystemFileSystem`. This simulates a symlink swapped in between merge planning and the write.
  """

  @behaviour Minga.Buffer.Persistence.FileSystem

  alias Minga.Buffer.Persistence.SystemFileSystem

  @impl true
  @spec lstat(String.t(), keyword()) :: {:ok, File.Stat.t()} | {:error, term()}
  def lstat(path, opts) do
    {agent, name, _link_target} = Keyword.fetch!(opts, :relink)

    if Path.basename(path) == name and Agent.get_and_update(agent, &{&1, &1 + 1}) > 0 do
      {:ok, %File.Stat{type: :symlink}}
    else
      SystemFileSystem.lstat(path, opts)
    end
  end

  @impl true
  @spec read_link(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def read_link(path, opts) do
    {_agent, name, link_target} = Keyword.fetch!(opts, :relink)

    if Path.basename(path) == name,
      do: {:ok, link_target},
      else: SystemFileSystem.read_link(path, opts)
  end

  @impl true
  @spec stat(String.t(), keyword()) :: {:ok, File.Stat.t()} | {:error, term()}
  def stat(path, opts), do: SystemFileSystem.stat(path, opts)

  @impl true
  @spec mkdir_p(String.t(), keyword()) :: :ok | {:error, term()}
  def mkdir_p(path, opts), do: SystemFileSystem.mkdir_p(path, opts)

  @impl true
  @spec open_exclusive(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def open_exclusive(path, opts), do: SystemFileSystem.open_exclusive(path, opts)

  @impl true
  @spec write(term(), binary(), keyword()) :: :ok | {:error, term()}
  def write(device, content, opts), do: SystemFileSystem.write(device, content, opts)

  @impl true
  @spec preserve_metadata(String.t(), File.Stat.t() | nil, keyword()) :: :ok | {:error, term()}
  def preserve_metadata(path, metadata, opts),
    do: SystemFileSystem.preserve_metadata(path, metadata, opts)

  @impl true
  @spec flush(term(), keyword()) :: :ok | {:error, term()}
  def flush(device, opts), do: SystemFileSystem.flush(device, opts)

  @impl true
  @spec close(term(), keyword()) :: :ok | {:error, term()}
  def close(device, opts), do: SystemFileSystem.close(device, opts)

  @impl true
  @spec rename(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def rename(source, destination, opts), do: SystemFileSystem.rename(source, destination, opts)

  @impl true
  @spec link(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def link(source, destination, opts), do: SystemFileSystem.link(source, destination, opts)

  @impl true
  @spec remove(String.t(), keyword()) :: :ok | {:error, term()}
  def remove(path, opts), do: SystemFileSystem.remove(path, opts)
end
