defmodule Minga.Test.FileTreeWatcherBackend do
  @moduledoc "Deterministic watcher backend for serialized file-tree watcher effect tests."

  @behaviour MingaEditor.FileTree.WatcherSync.Backend

  @type operation :: :watch | :unwatch
  @type mode :: :immediate | :wait | {:fail, operation(), String.t(), term()}
  @type context :: {pid(), term(), mode()}

  @impl true
  @spec watch_directory(String.t(), context()) :: :ok | {:error, term()}
  def watch_directory(path, context), do: perform(:watch, path, context)

  @impl true
  @spec unwatch_directory_tree(String.t(), context()) :: :ok | {:error, term()}
  def unwatch_directory_tree(path, context), do: perform(:unwatch, path, context)

  @spec perform(operation(), String.t(), context()) :: :ok | {:error, term()}
  defp perform(operation, path, {test_pid, label, mode}) do
    send(test_pid, {:file_tree_watcher_call, label, operation, path, self()})
    complete(operation, path, label, mode)
  end

  @spec complete(operation(), String.t(), term(), mode()) :: :ok | {:error, term()}
  defp complete(_operation, _path, _label, :immediate), do: :ok

  defp complete(operation, path, _label, {:fail, operation, path, reason}),
    do: {:error, reason}

  defp complete(_operation, _path, _label, {:fail, _other_operation, _other_path, _reason}),
    do: :ok

  defp complete(operation, path, label, :wait) do
    receive do
      {:release_file_tree_watcher_call, ^label, ^operation, ^path, :ok} ->
        :ok

      {:release_file_tree_watcher_call, ^label, ^operation, ^path, {:error, reason}} ->
        {:error, reason}
    end
  end
end
