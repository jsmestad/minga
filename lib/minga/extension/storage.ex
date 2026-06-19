defmodule Minga.Extension.Storage do
  @moduledoc """
  Sanctioned per-extension persistent storage.

  Each extension gets a private data directory under
  `~/.local/share/minga/extensions/<name>/data/` plus atomic read/write
  helpers, so extensions persist durable state without reinventing
  (often non-atomic) file I/O. The `data` subdirectory keeps extension
  state separate from a git-sourced extension's checkout at
  `~/.local/share/minga/extensions/<name>/`.
  """

  @default_base Path.expand("~/.local/share/minga/extensions")

  @doc """
  Returns the extension's private data directory, creating it if needed.
  """
  @spec data_dir(atom()) :: String.t()
  def data_dir(name) when is_atom(name) do
    dir = Path.join([base(), Atom.to_string(name), "data"])
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Reads a file from the extension's data directory.

  `rel` is a path relative to `data_dir/1`. Paths that try to escape the
  directory (containing a `..` segment) are rejected with `:invalid_path`.
  """
  @spec read(atom(), Path.t()) :: {:ok, binary()} | {:error, File.posix() | :invalid_path}
  def read(name, rel) when is_atom(name) do
    with {:ok, path} <- safe_path(name, rel) do
      File.read(path)
    end
  end

  @doc """
  Atomically writes `contents` to a file in the extension's data directory.

  Writes to a temp file in the same directory and renames it into place, so
  a crash mid-write cannot corrupt existing data.
  """
  @spec write(atom(), Path.t(), iodata()) :: :ok | {:error, File.posix() | :invalid_path}
  def write(name, rel, contents) when is_atom(name) do
    with {:ok, path} <- safe_path(name, rel) do
      File.mkdir_p!(Path.dirname(path))
      atomic_write(path, contents)
    end
  end

  @spec atomic_write(String.t(), iodata()) :: :ok | {:error, File.posix()}
  defp atomic_write(path, contents) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, contents),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  # The data root is overridable via application env so tests don't touch
  # the real home directory.
  @spec base() :: String.t()
  defp base, do: Application.get_env(:minga, :extension_data_dir, @default_base)

  @spec safe_path(atom(), Path.t()) :: {:ok, String.t()} | {:error, :invalid_path}
  defp safe_path(name, rel) do
    if ".." in Path.split(rel) do
      {:error, :invalid_path}
    else
      {:ok, Path.join(data_dir(name), rel)}
    end
  end
end
