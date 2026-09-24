defmodule Minga.Session.Swap do
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

  @behaviour Minga.Session.Swap.Backend

  alias Minga.Session.Swap.Prepared

  @magic "MINGA_SWAP_V1\n"
  @temporary_name_regex ~r/\A[0-9a-v]{52}\.(\d+)\.swap\.\d+\.\d+\.tmp\z/

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
    Keyword.get_lazy(opts, :swap_dir, fn ->
      Path.join(System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"), "minga/swap")
    end)
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
    case prepare(file_path, content, opts) do
      {:ok, prepared} -> publish(prepared)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Writes a complete swap to a uniquely named temporary file.

  The returned value is not visible to recovery until `publish/1` atomically
  promotes it. Each preparation uses its own temporary target, so obsolete
  generations cannot overwrite one another before publication.
  """
  @impl Minga.Session.Swap.Backend
  @spec prepare(String.t(), binary(), keyword()) :: {:ok, Prepared.t()} | {:error, term()}
  def prepare(file_path, content, opts \\ [])
      when is_binary(file_path) and is_binary(content) do
    dir = swap_dir(opts)
    os_pid_val = Keyword.get(opts, :os_pid, os_pid())
    target = swap_path(file_path, opts)
    tmp = temporary_path(target, Keyword.get(opts, :generation))

    header = "path=#{file_path}\nos_pid=#{os_pid_val}\nmtime=#{System.os_time(:second)}"
    header_len = byte_size(header)
    data = <<@magic, header_len::32-big, header::binary, content::binary>>

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, data) do
      {:ok, %Prepared{temporary_path: tmp, target_path: target}}
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  @doc "Atomically publishes a fully prepared swap file."
  @impl Minga.Session.Swap.Backend
  @spec publish(Prepared.t()) :: :ok | {:error, term()}
  def publish(%Prepared{temporary_path: tmp, target_path: target} = prepared) do
    case File.rename(tmp, target) do
      :ok ->
        :ok

      {:error, reason} ->
        publish_error(reason, discard(prepared))
    end
  end

  @doc "Discards an obsolete prepared swap file."
  @impl Minga.Session.Swap.Backend
  @spec discard(Prepared.t()) :: :ok | {:error, term()}
  def discard(%Prepared{temporary_path: tmp}) do
    remove_file(tmp)
  end

  @doc "Deletes the swap file for the given source file path, if it exists."
  @impl Minga.Session.Swap.Backend
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(file_path, opts \\ []) when is_binary(file_path) do
    target = swap_path(file_path, opts)

    case temporary_paths(target) do
      {:ok, temporary_paths} -> remove_files([target | temporary_paths])
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the owner OS PID encoded in a recognized generation temporary filename."
  @spec temporary_owner_pid(String.t()) :: {:ok, pos_integer()} | :error
  def temporary_owner_pid(path) when is_binary(path) do
    case Regex.run(@temporary_name_regex, Path.basename(path), capture: :all_but_first) do
      [pid_string] -> parse_positive_pid(pid_string)
      nil -> :error
    end
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

  @spec temporary_path(String.t(), term()) :: String.t()
  defp temporary_path(target, generation) do
    generation = if is_integer(generation), do: generation, else: 0
    unique = System.unique_integer([:positive, :monotonic])
    "#{target}.#{generation}.#{unique}.tmp"
  end

  @spec publish_error(term(), :ok | {:error, term()}) :: {:error, term()}
  defp publish_error(reason, :ok), do: {:error, reason}

  defp publish_error(reason, {:error, discard_reason}) do
    {:error, {:publish_failed, reason, {:discard_failed, discard_reason}}}
  end

  @spec temporary_paths(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  defp temporary_paths(target) do
    directory = Path.dirname(target)
    target_name = Path.basename(target)
    regex = Regex.compile!("\\A#{Regex.escape(target_name)}\\.\\d+\\.\\d+\\.tmp\\z")

    case File.ls(directory) do
      {:ok, names} ->
        paths =
          names
          |> Enum.filter(&Regex.match?(regex, &1))
          |> Enum.map(&Path.join(directory, &1))

        {:ok, paths}

      {:error, :enoent} ->
        {:ok, []}

      {:error, _reason} = error ->
        error
    end
  end

  @spec remove_files([String.t()]) :: :ok | {:error, term()}
  defp remove_files(paths) do
    Enum.reduce(paths, :ok, fn path, result ->
      case {result, remove_file(path)} do
        {:ok, next_result} -> next_result
        {{:error, _reason} = error, _next_result} -> error
      end
    end)
  end

  @spec remove_file(String.t()) :: :ok | {:error, term()}
  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec parse_positive_pid(String.t()) :: {:ok, pos_integer()} | :error
  defp parse_positive_pid(pid_string) do
    case Integer.parse(pid_string) do
      {pid, ""} when pid > 0 -> {:ok, pid}
      _ -> :error
    end
  end

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
