defmodule Minga.Swap do
  @moduledoc """
  Swap file management for crash recovery.

  Dirty buffers periodically write their content to swap files at
  `~/.local/share/minga/swap/`. If Minga crashes, orphaned swap files
  are detected on next startup and the user is offered recovery.

  Swap files use a SHA-256 hash of the absolute file path plus the OS PID
  as the filename: `{hash}.{os_pid}.swap`. Including the OS PID in the
  filename prevents silent overwrites when multiple Minga instances edit
  the same file.

  ## File format (binary)

  The swap file uses a binary length-prefixed format to avoid content
  collision. A text delimiter like `\\n---\\n` would break on files
  containing that exact string.

      <<magic::14 bytes, header_len::32-big, header::header_len bytes, content::rest>>

  Where `magic` is `"MINGA_SWAP_V1\\n"` (14 bytes including newline),
  `header_len` is a 4-byte big-endian integer, `header` is a UTF-8
  encoded string with key=value lines, and `content` is the raw buffer
  content (arbitrary bytes, preserved exactly).

  ## Header fields

      path=/absolute/path/to/file.ex
      os_pid=12345
      mtime=1711234567
  """

  @default_swap_dir Path.expand("~/.local/share/minga/swap")
  @magic "MINGA_SWAP_V1\n"

  @typedoc "Metadata parsed from a swap file header."
  @type metadata :: %{
          path: String.t(),
          os_pid: integer(),
          mtime: integer(),
          swap_path: String.t()
        }

  @doc "Returns the swap directory path."
  @spec swap_dir(keyword()) :: String.t()
  def swap_dir(opts \\ []) do
    Keyword.get(opts, :swap_dir, @default_swap_dir)
  end

  @doc """
  Returns the swap file path for a given source file path.

  Includes the OS PID in the filename so multiple Minga instances
  editing the same file each get their own swap file.
  """
  @spec swap_path(String.t(), keyword()) :: String.t()
  def swap_path(file_path, opts \\ []) when is_binary(file_path) do
    dir = swap_dir(opts)
    hash = :crypto.hash(:sha256, file_path) |> Base.hex_encode32(case: :lower, padding: false)
    os_pid = Keyword.get(opts, :os_pid, os_pid())
    Path.join(dir, "#{hash}.#{os_pid}.swap")
  end

  @doc """
  Writes a swap file for the given source file path and buffer content.

  Creates the swap directory if it doesn't exist. The write is atomic:
  content is written to a temporary file, then renamed to avoid partial
  writes on crash.
  """
  @spec write(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def write(file_path, content, opts \\ [])
      when is_binary(file_path) and is_binary(content) do
    dir = swap_dir(opts)
    os_pid_val = Keyword.get(opts, :os_pid, os_pid())
    target = swap_path(file_path, opts)
    tmp = target <> ".tmp"

    header = "path=#{file_path}\nos_pid=#{os_pid_val}\nmtime=#{System.os_time(:second)}"
    header_len = byte_size(header)
    data = <<@magic, header_len::32-big, header::binary, content::binary>>

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, data),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  @doc "Deletes the swap file for the given source file path, if it exists."
  @spec delete(String.t(), keyword()) :: :ok
  def delete(file_path, opts \\ []) when is_binary(file_path) do
    path = swap_path(file_path, opts)
    File.rm(path)
    :ok
  end

  @doc """
  Reads and parses a swap file, returning the metadata and buffer content.

  Returns `{:ok, metadata, content}` or `{:error, reason}`.
  """
  @spec read(String.t()) :: {:ok, metadata(), binary()} | {:error, term()}
  def read(swap_path) when is_binary(swap_path) do
    case File.read(swap_path) do
      {:ok, data} -> parse_swap_file(data, swap_path)
      error -> error
    end
  end

  @doc "Checks whether the given OS PID is still running."
  @spec pid_alive?(integer()) :: boolean()
  def pid_alive?(os_pid) when is_integer(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)],
           stderr_to_stdout: true,
           into: ""
         ) do
      {_, 0} -> true
      _ -> false
    end
  end

  @doc "Returns the current OS process ID as an integer."
  @spec os_pid() :: integer()
  def os_pid do
    System.pid() |> String.to_integer()
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec parse_swap_file(binary(), String.t()) ::
          {:ok, metadata(), binary()} | {:error, :invalid_format}
  defp parse_swap_file(
         <<@magic, header_len::32-big, header::binary-size(header_len), content::binary>>,
         swap_path
       ) do
    case parse_header(header) do
      {:ok, meta} -> {:ok, Map.put(meta, :swap_path, swap_path), content}
      error -> error
    end
  end

  defp parse_swap_file(_, _), do: {:error, :invalid_format}

  @spec parse_header(binary()) :: {:ok, map()} | {:error, :invalid_format}
  defp parse_header(header) do
    fields =
      header
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    with {:ok, path} <- Map.fetch(fields, "path"),
         {:ok, pid_str} <- Map.fetch(fields, "os_pid"),
         {:ok, mtime_str} <- Map.fetch(fields, "mtime"),
         {os_pid, ""} <- Integer.parse(pid_str),
         {mtime, ""} <- Integer.parse(mtime_str) do
      {:ok, %{path: path, os_pid: os_pid, mtime: mtime}}
    else
      _ -> {:error, :invalid_format}
    end
  end
end
