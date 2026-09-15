defmodule MingaEditor.FileWatcherHelpers do
  @moduledoc """
  File watcher event handling for the Editor.

  Processes file system change notifications and determines whether
  to silently reload a buffer, prompt the user about a conflict, or
  ignore the event. It also restores the editor's declarative watch intent
  after FileWatcher starts.
  """

  alias Minga.Buffer
  alias Minga.Buffer.State, as: BufState
  alias Minga.FileWatcher
  alias MingaEditor.BufferFileIdentity
  alias MingaEditor.EffectScheduler
  alias MingaEditor.FileTree.WatcherSync
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.ModalOverlay.Conflict, as: ConflictPayload

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
        case safe_buffer_state(buf) do
          {:ok, buf_state} ->
            {disk_mtime, disk_size} = file_stat(path)
            handle_change(state, buf, path, buf_state, disk_mtime, disk_size)

          :unavailable ->
            state
        end
    end
  end

  @doc "Restores the watcher subscriber and complete intent from the current editor snapshot."
  @spec restore_authority(state(), pid() | nil) :: state()
  def restore_authority(%EditorState{} = state, nil), do: state

  def restore_authority(%EditorState{} = state, watcher) when is_pid(watcher) do
    case cancel_stale_watcher_sync(state.effect_scheduler) do
      :ok ->
        files = open_file_paths(state)
        project_dirs = project_watch_dirs(state)
        :ok = FileWatcher.restore_authority(watcher, self(), files, project_dirs)
        state

      {:error, reason} ->
        Minga.Log.warning(
          :editor,
          "File watcher authority restore skipped: watcher sync cancellation failed: #{inspect(reason)}"
        )

        state
    end
  catch
    :exit, reason ->
      Minga.Log.warning(:editor, "File watcher authority restore failed: #{inspect(reason)}")
      state
  end

  @doc "Registers one newly opened file path with the current watcher."
  @spec watch_opened_path(state(), String.t()) :: state()
  def watch_opened_path(%EditorState{} = state, path) when is_binary(path) do
    call_current_watcher(state, &FileWatcher.watch_path(&1, path))
  end

  @doc "Unregisters one closed file path from the current watcher."
  @spec unwatch_closed_path(state(), String.t() | :scratch) :: state()
  def unwatch_closed_path(%EditorState{} = state, :scratch), do: state

  def unwatch_closed_path(%EditorState{} = state, path) when is_binary(path) do
    call_current_watcher(state, &FileWatcher.unwatch_path(&1, path))
  end

  @doc """
  Returns the file watcher PID, or nil if not running.
  """
  @spec watcher_pid() :: pid() | nil
  def watcher_pid do
    Process.whereis(FileWatcher)
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  @spec cancel_stale_watcher_sync(EffectScheduler.server() | nil) ::
          :ok | {:error, :scheduler_unavailable}
  defp cancel_stale_watcher_sync(nil), do: :ok

  defp cancel_stale_watcher_sync(scheduler) do
    EffectScheduler.cancel_resource(scheduler, WatcherSync.resource())
  end

  @spec open_file_paths(state()) :: [String.t()]
  defp open_file_paths(%EditorState{} = state) do
    state
    |> BufferFileIdentity.known_open_pids()
    |> Enum.flat_map(fn buffer ->
      case safe_file_path(buffer) do
        nil -> []
        path -> [path]
      end
    end)
  end

  @spec project_watch_dirs(state()) :: [String.t()]
  defp project_watch_dirs(%EditorState{workspace: %{file_tree: file_tree}}) do
    file_tree
    |> FileTreeState.watcher_intent()
    |> Map.fetch!(:expanded_dirs)
    |> MapSet.to_list()
  end

  @spec safe_file_path(pid()) :: String.t() | nil
  defp safe_file_path(buffer) do
    Buffer.file_path(buffer)
  catch
    :exit, _ -> nil
  end

  @spec call_current_watcher(state(), (pid() -> :ok)) :: state()
  defp call_current_watcher(%EditorState{} = state, callback) do
    case watcher_pid() do
      nil -> state
      watcher -> call_watcher(state, watcher, callback)
    end
  end

  @spec call_watcher(state(), pid(), (pid() -> :ok)) :: state()
  defp call_watcher(%EditorState{} = state, watcher, callback) do
    :ok = callback.(watcher)
    state
  catch
    :exit, reason ->
      Minga.Log.warning(:editor, "File watcher registration failed: #{inspect(reason)}")
      state
  end

  @spec handle_change(
          state(),
          pid(),
          String.t(),
          BufState.t(),
          integer() | nil,
          non_neg_integer() | nil
        ) ::
          state()
  defp handle_change(state, _buf, _path, _buf_state, nil, _size), do: state

  defp handle_change(state, buf, path, buf_state, disk_mtime, disk_size) do
    handle_known_change(
      state,
      buf,
      path,
      disk_mtime,
      disk_size,
      BufState.mtime(buf_state),
      BufState.file_size(buf_state),
      BufState.dirty?(buf_state)
    )
  end

  @spec handle_known_change(
          state(),
          pid(),
          String.t(),
          integer(),
          non_neg_integer() | nil,
          integer() | nil,
          non_neg_integer() | nil,
          boolean()
        ) :: state()
  defp handle_known_change(state, _buf, _path, _disk_mtime, _disk_size, nil, _saved_size, _dirty),
    do: state

  defp handle_known_change(state, _buf, _path, mtime, size, mtime, size, _dirty), do: state

  defp handle_known_change(
         state,
         buf,
         path,
         _disk_mtime,
         _disk_size,
         _saved_mtime,
         _saved_size,
         false
       ) do
    Buffer.reload(buf)
    name = Path.basename(path)

    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      state,
      "#{name} reloaded (changed on disk)"
    )
  end

  defp handle_known_change(
         state,
         buf,
         path,
         _disk_mtime,
         _disk_size,
         _saved_mtime,
         _saved_size,
         true
       ) do
    name = Path.basename(path)

    state =
      MingaEditor.Shell.Traditional.ModalWorkflow.open(
        state,
        {:conflict, ConflictPayload.new(buf, path)}
      )

    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
      state,
      "#{name} changed on disk. [r]eload / [k]eep"
    )
  end

  @spec safe_buffer_state(pid()) :: {:ok, BufState.t()} | :unavailable
  defp safe_buffer_state(buf) do
    {:ok, :sys.get_state(buf)}
  catch
    :exit, _ -> :unavailable
  end

  @spec find_buffer_for_path(state(), String.t()) :: pid() | nil
  defp find_buffer_for_path(%{workspace: %{buffers: %{list: buffers}}}, path) do
    expanded = Path.expand(path)

    Enum.find(buffers, fn buf ->
      try do
        Buffer.file_path(buf) == expanded
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
