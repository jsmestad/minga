defmodule Minga.Buffer.Persistence do
  @moduledoc """
  Stateless file persistence operations for buffers.

  `Minga.Buffer.Process` owns the process transaction: undo state, dirty state, events, timers, and registry updates. This module owns the file-system and remote-storage details that make those transactions possible: reading content, writing content, collecting file metadata, fingerprinting saved content, and deciding whether the backing file changed since the buffer last saved or loaded it.
  """

  alias Minga.Buffer.State, as: BufState

  @type storage :: BufState.storage()
  @type metadata :: {mtime :: integer() | nil, size :: non_neg_integer() | nil}
  @type state_or_storage :: BufState.t() | storage()
  @type saved_content_status :: :same | :changed | :unknown

  @doc "Loads initial buffer content from storage or returns the supplied scratch content when no path is set."
  @spec load_content(storage(), String.t() | nil, String.t()) ::
          {:ok, String.t(), String.t() | nil, metadata()} | {:error, term()}
  def load_content(_storage, nil, initial_content), do: {:ok, initial_content, nil, {nil, nil}}

  def load_content(storage, file_path, _initial_content) do
    case read_content(storage, file_path) do
      {:ok, text} -> {:ok, text, file_path, file_metadata(storage, file_path)}
      {:error, :enoent} -> {:ok, "", file_path, {nil, nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reads file content through the buffer's storage backend."
  @spec read_content(state_or_storage(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_content(%BufState{storage: storage}, path), do: read_content(storage, path)
  def read_content(:local, path), do: File.read(path)

  def read_content({:remote, node, _base_path}, path) do
    :erpc.call(
      node,
      Minga.Distribution.File,
      :read_local,
      [path, Minga.Distribution.File.max_file_bytes()],
      5_000
    )
  catch
    :exit, reason -> remote_unavailable(reason)
    :error, {:erpc, _reason} = reason -> remote_unavailable(reason)
  end

  @doc "Writes file content through the buffer's storage backend."
  @spec write_content(BufState.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def write_content(%BufState{storage: :local}, file_path, content) do
    file_path
    |> Path.dirname()
    |> File.mkdir_p()
    |> case do
      :ok -> File.write(file_path, content)
      error -> error
    end
  end

  def write_content(%BufState{storage: {:remote, node, _base_path}}, file_path, content) do
    :erpc.call(node, File, :write, [file_path, content], 10_000)
  catch
    :exit, reason -> remote_unavailable(reason)
    :error, {:erpc, _reason} = reason -> remote_unavailable(reason)
  end

  @doc "Returns `{mtime, size}` for a file, or `{nil, nil}` when metadata cannot be read."
  @spec file_metadata(state_or_storage(), String.t() | nil) :: metadata()
  def file_metadata(_state_or_storage, nil), do: {nil, nil}

  def file_metadata(state_or_storage, path) do
    case file_info(state_or_storage, path) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      {:error, _} -> {nil, nil}
    end
  end

  @doc "Returns file information through the buffer's storage backend."
  @spec file_info(state_or_storage(), String.t()) :: {:ok, File.Stat.t()} | {:error, term()}
  def file_info(%BufState{storage: storage}, path), do: file_info(storage, path)
  def file_info(:local, path), do: File.stat(path, time: :posix)

  def file_info({:remote, node, _base_path}, path) do
    :erpc.call(node, File, :stat, [path, [time: :posix]], 5_000)
  catch
    :exit, reason -> remote_unavailable(reason)
    :error, {:erpc, _reason} = reason -> remote_unavailable(reason)
  end

  @doc "Returns true when the backing file differs from the buffer's saved baseline."
  @spec changed_since_saved?(BufState.t(), integer() | nil, non_neg_integer() | nil) :: boolean()
  def changed_since_saved?(%BufState{mtime: nil}, nil, _disk_size), do: false
  def changed_since_saved?(%BufState{mtime: nil}, _disk_mtime, _disk_size), do: true
  def changed_since_saved?(_state, nil, _disk_size), do: false

  def changed_since_saved?(%BufState{} = state, disk_mtime, disk_size) do
    metadata_changed? = disk_mtime != state.mtime or disk_size != state.file_size

    case saved_content_status(state) do
      :same -> false
      :changed -> true
      :unknown -> metadata_changed?
    end
  end

  @doc "Fingerprints content with the algorithm used to track saved file baselines."
  @spec content_fingerprint(String.t()) :: binary()
  def content_fingerprint(content), do: :crypto.hash(:sha256, content)

  @doc "Returns a saved-content fingerprint only when a path and concrete mtime make the baseline meaningful."
  @spec saved_content_fingerprint(String.t() | nil, integer() | nil, String.t()) :: binary() | nil
  def saved_content_fingerprint(path, mtime, content)
      when is_binary(path) and is_integer(mtime) do
    content_fingerprint(content)
  end

  def saved_content_fingerprint(_path, _mtime, _content), do: nil

  @spec saved_content_status(BufState.t()) :: saved_content_status()
  defp saved_content_status(%BufState{file_path: path, file_hash: hash} = state)
       when is_binary(path) and is_binary(hash) do
    case read_content(state, path) do
      {:ok, content} -> if content_fingerprint(content) == hash, do: :same, else: :changed
      {:error, _reason} -> :changed
    end
  end

  defp saved_content_status(_state), do: :unknown

  @spec remote_unavailable(term()) :: {:error, {:remote_unavailable, term()}}
  defp remote_unavailable(reason), do: {:error, {:remote_unavailable, reason}}
end
