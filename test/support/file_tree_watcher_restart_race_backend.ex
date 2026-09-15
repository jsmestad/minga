defmodule Minga.Test.FileTreeWatcherRestartRaceBackend do
  @moduledoc "Deterministic backend that blocks before mutating the current production FileWatcher."

  @behaviour MingaEditor.FileTree.WatcherSync.Backend

  @type context :: {pid(), term()}

  @impl true
  @spec watch_directory(String.t(), context()) :: :ok | {:error, term()}
  def watch_directory(path, {test_pid, label}) do
    send(test_pid, {:restart_race_watcher_blocked, label, path, self()})

    receive do
      {:release_restart_race_watcher, ^label} -> Minga.FileWatcher.watch_directory(path)
    end
  catch
    :exit, reason -> {:error, {:watch_failed, path, reason}}
  end

  @impl true
  @spec unwatch_directory_tree(String.t(), context()) :: :ok | {:error, term()}
  def unwatch_directory_tree(path, _context) do
    Minga.FileWatcher.unwatch_directory_tree(path)
  catch
    :exit, reason -> {:error, {:unwatch_failed, path, reason}}
  end
end
