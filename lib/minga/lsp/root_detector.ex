defmodule Minga.LSP.RootDetector do
  @moduledoc """
  Detects the project root for a language server by walking up from a file
  path and looking for root marker files.

  Each language server defines `root_markers` — files whose presence signals
  the project root (e.g., `mix.exs` for Elixir, `go.mod` for Go). This
  module walks up the directory tree from the given file until it finds a
  directory containing one of those markers.

  Falls back to the current working directory if no marker is found.

  Pure functions — no process state.
  """

  @doc """
  Finds the project root for a file given a list of root marker filenames.

  Walks up from `file_path`'s parent directory, checking each directory for
  the presence of any file in `root_markers`. Returns the first directory
  that contains a marker, or `File.cwd!/0` if none is found.

  ## Examples

      iex> # Assuming mix.exs exists at the project root
      iex> root = Minga.LSP.RootDetector.find_root("lib/minga/editor.ex", ["mix.exs"])
      iex> File.exists?(Path.join(root, "mix.exs"))
      true

      iex> Minga.LSP.RootDetector.find_root("/tmp/no_markers_here.txt", [])
      File.cwd!()
  """
  @spec find_root(String.t(), [String.t()]) :: String.t()
  def find_root(file_path, root_markers)
      when is_binary(file_path) and is_list(root_markers) do
    file_path
    |> Path.expand()
    |> Path.dirname()
    |> walk_up(root_markers)
  end

  @spec walk_up(String.t(), [String.t()]) :: String.t()
  defp walk_up(_dir, []), do: File.cwd!()

  defp walk_up(dir, root_markers) do
    if has_marker?(dir, root_markers) do
      dir
    else
      parent = Path.dirname(dir)

      if parent == dir do
        # Reached filesystem root without finding a marker
        File.cwd!()
      else
        walk_up(parent, root_markers)
      end
    end
  end

  @spec has_marker?(String.t(), [String.t()]) :: boolean()
  defp has_marker?(dir, root_markers) do
    Enum.any?(root_markers, fn marker ->
      dir
      |> Path.join(marker)
      |> File.exists?()
    end)
  end
end
