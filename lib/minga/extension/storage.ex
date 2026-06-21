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
    case data_dir_result(name) do
      {:ok, dir} ->
        dir

      {:error, :invalid_path} ->
        raise ArgumentError, "invalid extension storage name: #{inspect(name)}"

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "create extension data directory",
          path: Atom.to_string(name)
    end
  end

  @doc """
  Reads a file from the extension's data directory.

  `rel` is a path relative to `data_dir/1`. Absolute paths, traversal paths,
  and invalid extension names are rejected with `:invalid_path`.
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
    with {:ok, path} <- safe_path(name, rel),
         :ok <- ensure_private_dir(Path.dirname(path)) do
      atomic_write(path, contents)
    end
  end

  @spec atomic_write(String.t(), iodata()) :: :ok | {:error, File.posix()}
  defp atomic_write(path, contents) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, contents),
         :ok <- chmod_private_file(tmp),
         :ok <- File.rename(tmp, path),
         :ok <- chmod_private_file(path) do
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

  @spec safe_path(atom(), Path.t()) :: {:ok, String.t()} | {:error, File.posix() | :invalid_path}
  defp safe_path(name, rel) do
    with {:relative, true} <- {:relative, is_binary(rel) and Path.type(rel) == :relative},
         {:segments, false} <- {:segments, ".." in Path.split(rel)},
         {:ok, dir} <- data_dir_result(name) do
      path = Path.expand(rel, dir)

      if inside_dir?(path, dir) do
        {:ok, path}
      else
        {:error, :invalid_path}
      end
    else
      {:relative, false} -> {:error, :invalid_path}
      {:segments, true} -> {:error, :invalid_path}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec data_dir_result(atom()) :: {:ok, String.t()} | {:error, File.posix() | :invalid_path}
  defp data_dir_result(name) when is_atom(name) do
    with {:ok, extension_name} <- safe_extension_name(name) do
      extension_dir = Path.join(base(), extension_name)
      dir = Path.join(extension_dir, "data")

      with :ok <- ensure_private_dir(dir),
           :ok <- chmod_private_dir(extension_dir) do
        {:ok, dir}
      end
    end
  end

  @spec safe_extension_name(atom()) :: {:ok, String.t()} | {:error, :invalid_path}
  defp safe_extension_name(name) do
    name_string = Atom.to_string(name)

    if valid_extension_name?(name_string) do
      {:ok, name_string}
    else
      {:error, :invalid_path}
    end
  end

  @spec valid_extension_name?(String.t()) :: boolean()
  defp valid_extension_name?(""), do: false

  defp valid_extension_name?(name) do
    not String.contains?(name, ["/", "\\"]) and ".." not in Path.split(name)
  end

  @spec inside_dir?(String.t(), String.t()) :: boolean()
  defp inside_dir?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  @spec ensure_private_dir(String.t()) :: :ok | {:error, File.posix()}
  defp ensure_private_dir(path) do
    with :ok <- File.mkdir_p(path) do
      chmod_private_dir(path)
    end
  end

  @spec chmod_private_dir(String.t()) :: :ok
  defp chmod_private_dir(path), do: private_chmod(path, 0o700)

  @spec chmod_private_file(String.t()) :: :ok
  defp chmod_private_file(path), do: private_chmod(path, 0o600)

  @spec private_chmod(String.t(), non_neg_integer()) :: :ok
  defp private_chmod(path, mode) do
    _ = File.chmod(path, mode)
    :ok
  end
end
