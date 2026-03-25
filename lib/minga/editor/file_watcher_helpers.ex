defmodule Minga.Editor.FileWatcherHelpers do
  @moduledoc """
  File watcher event handling for the Editor.

  Processes file system change notifications and determines whether
  to silently reload a buffer, prompt the user about a conflict, or
  ignore the event. Also provides helpers for watching new buffers.
  """

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.FileWatcher

  @type state :: EditorState.t()

  @doc """
  Handles a file change notification from the file watcher.

  Determines the appropriate action based on whether the buffer is
  dirty and whether the file actually changed on disk.
  """
  @spec handle_file_change(state(), String.t()) :: state()
  def handle_file_change(state, path) do
    case find_buffer_for_path(state, path) do
      nil ->
        state

      buf ->
        buf_state = :sys.get_state(buf)
        {disk_mtime, disk_size} = file_stat(path)

        handle_change(state, buf, path, buf_state, disk_mtime, disk_size)
    end
  end

  @doc """
  Watches a buffer's file path with the file watcher, if both exist.
  """
  @spec maybe_watch_buffer(pid() | nil) :: :ok
  def maybe_watch_buffer(nil), do: :ok

  def maybe_watch_buffer(buf) do
    case {watcher_pid(), BufferServer.file_path(buf)} do
      {nil, _} -> :ok
      {_, nil} -> :ok
      {watcher, path} -> FileWatcher.watch_path(watcher, path)
    end
  end

  @doc """
  Returns the file watcher PID, or nil if not running.
  """
  @spec watcher_pid() :: pid() | nil
  def watcher_pid do
    Process.whereis(FileWatcher)
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec handle_change(state(), pid(), String.t(), map(), integer() | nil, non_neg_integer() | nil) ::
          state()
  defp handle_change(state, _buf, _path, _buf_state, nil, _size), do: state
  defp handle_change(state, _buf, _path, %{mtime: nil}, _mtime, _size), do: state

  defp handle_change(state, _buf, _path, %{mtime: mtime, file_size: size}, mtime, size), do: state

  defp handle_change(state, buf, path, %{dirty: false}, _mtime, _size) do
    BufferServer.reload(buf)
    name = Path.basename(path)
    %{state | status_msg: "#{name} reloaded (changed on disk)"}
  end

  defp handle_change(state, buf, path, _buf_state, _mtime, _size) do
    name = Path.basename(path)

    %{
      state
      | workspace: %{state.workspace | pending_conflict: {buf, path}},
        status_msg: "#{name} changed on disk. [r]eload / [k]eep"
    }
  end

  @spec find_buffer_for_path(state(), String.t()) :: pid() | nil
  defp find_buffer_for_path(%{workspace: %{buffers: %{list: buffers}}}, path) do
    expanded = Path.expand(path)

    Enum.find(buffers, fn buf ->
      try do
        BufferServer.file_path(buf) == expanded
      catch
        :exit, _ -> false
      end
    end)
  end

  @spec file_stat(String.t()) :: {integer() | nil, non_neg_integer() | nil}
  defp file_stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      {:error, _} -> {nil, nil}
    end
  end
end
