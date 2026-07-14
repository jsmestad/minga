defmodule MingaEditor.FileTree.WatcherSync.FileWatcherBackend do
  @moduledoc "Production watcher backend that isolates FileWatcher calls inside effect workers."

  @behaviour MingaEditor.FileTree.WatcherSync.Backend

  @impl true
  @spec watch_directory(String.t(), term()) :: :ok | {:error, term()}
  def watch_directory(path, _context) when is_binary(path) do
    Minga.FileWatcher.watch_directory(path)
  catch
    :exit, reason -> {:error, {:watch_failed, path, reason}}
  end

  @impl true
  @spec unwatch_directory_tree(String.t(), term()) :: :ok | {:error, term()}
  def unwatch_directory_tree(path, _context) when is_binary(path) do
    Minga.FileWatcher.unwatch_directory_tree(path)
  catch
    :exit, reason -> {:error, {:unwatch_failed, path, reason}}
  end
end
