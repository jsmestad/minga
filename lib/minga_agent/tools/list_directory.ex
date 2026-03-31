defmodule MingaAgent.Tools.ListDirectory do
  @moduledoc """
  Lists files and directories at a given path.

  Directories are displayed with a trailing `/` to distinguish them from files.
  Entries are sorted alphabetically with directories first.
  """

  @doc """
  Lists the contents of the directory at `path`.

  Returns entries one per line, with directories suffixed by `/`.
  """
  @spec execute(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(path) when is_binary(path) do
    case File.ls(path) do
      {:ok, entries} ->
        {:ok, format_entries(path, entries)}

      {:error, :enoent} ->
        {:error, "directory not found: #{path}"}

      {:error, :enotdir} ->
        {:error, "#{path} is a file, not a directory. Use read_file instead."}

      {:error, reason} ->
        {:error, "failed to list #{path}: #{reason}"}
    end
  end

  @spec format_entries(String.t(), [String.t()]) :: String.t()
  defp format_entries(path, entries) do
    entries
    |> Enum.sort()
    |> Enum.map(&label_entry(path, &1))
    |> Enum.sort_by(fn entry -> if String.ends_with?(entry, "/"), do: 0, else: 1 end)
    |> Enum.join("\n")
  end

  @spec label_entry(String.t(), String.t()) :: String.t()
  defp label_entry(path, entry) do
    full = Path.join(path, entry)
    if File.dir?(full), do: entry <> "/", else: entry
  end
end
