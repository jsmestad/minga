defmodule MingaEditor.FileTree.WatcherSync.Backend do
  @moduledoc "Contract for file-watcher operations executed by the watcher synchronization effect."

  @callback watch_directory(String.t(), term()) :: :ok | {:error, term()}
  @callback unwatch_directory_tree(String.t(), term()) :: :ok | {:error, term()}
end
