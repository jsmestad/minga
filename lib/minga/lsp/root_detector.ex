defmodule Minga.LSP.RootDetector do
  @moduledoc """
  Detects the project root for a language server by walking up from a file
  path and looking for root marker files.

  Delegates to `Minga.Project.Detector` for the actual walk-up logic.
  This module exists as a stable API for the LSP subsystem.

  Pure functions, no process state.
  """

  alias Minga.Project.Detector

  @doc """
  Finds the project root for a file given a list of root marker filenames.

  Walks up from `file_path`'s parent directory, checking each directory for
  the presence of any file in `root_markers`. Returns the first directory
  that contains a marker, or `File.cwd!/0` if none is found.

  ## Examples

      iex> root = Minga.LSP.RootDetector.find_root("lib/minga/editor.ex", ["mix.exs"])
      iex> File.exists?(Path.join(root, "mix.exs"))
      true

      iex> Minga.LSP.RootDetector.find_root("/tmp/no_markers_here.txt", [])
      File.cwd!()
  """
  @spec find_root(String.t(), [String.t()]) :: String.t()
  def find_root(file_path, root_markers)
      when is_binary(file_path) and is_list(root_markers) do
    Detector.find_root(file_path, root_markers)
  end
end
