defmodule MingaAgent.Tools.ListDirectory do
  @moduledoc """
  Lists files and directories at a given path.

  Directories are displayed with a trailing `/` to distinguish them from files.
  Entries are sorted alphabetically with directories first.
  """

  alias MingaAgent.Tools.DirectoryListing

  @doc """
  Lists the contents of the directory at `path`.

  Returns entries one per line, with directories suffixed by `/`.
  """
  @spec execute(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path) when is_binary(path) do
    case File.ls(path) do
      {:ok, entries} ->
        {:ok, DirectoryListing.from_filesystem(path, entries)}

      {:error, :enoent} ->
        {:error, "directory not found: #{path}"}

      {:error, :enotdir} ->
        {:error, "#{path} is a file, not a directory. Use read_file instead."}

      {:error, reason} ->
        {:error, "failed to list #{path}: #{reason}"}
    end
  end
end
