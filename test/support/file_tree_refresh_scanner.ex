defmodule Minga.Test.FileTreeRefreshScanner do
  @moduledoc "Deterministic scanner used by typed file-tree refresh scheduler tests."

  @behaviour MingaEditor.FileTree.Refresh.Scanner

  alias Minga.Project.FileTree

  @type action ::
          :wait | :refresh | {:return, FileTree.t()} | {:error, term()} | {:raise, String.t()}
  @type context :: {pid(), term(), action()}

  @doc "Notifies the test and performs or waits for its data-only instruction."
  @impl true
  @spec scan(FileTree.t(), context()) :: FileTree.t() | {:error, term()}
  def scan(%FileTree{} = tree, {test_pid, label, action}) when is_pid(test_pid) do
    send(test_pid, {:file_tree_scan_started, label, self()})
    perform(tree, label, action)
  end

  @spec perform(FileTree.t(), term(), action()) :: FileTree.t() | {:error, term()}
  defp perform(tree, label, :wait) do
    receive do
      {:release_file_tree_scan, ^label, action} -> perform(tree, label, action)
    end
  end

  defp perform(tree, _label, :refresh), do: FileTree.refresh(tree)
  defp perform(_tree, _label, {:return, %FileTree{} = result}), do: result
  defp perform(_tree, _label, {:error, reason}), do: {:error, reason}
  defp perform(_tree, _label, {:raise, message}), do: raise(message)
end
