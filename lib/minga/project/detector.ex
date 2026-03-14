defmodule Minga.Project.Detector do
  @moduledoc """
  Detects the project root by walking up from a file path and looking for
  root marker files or directories.

  This is the shared detection logic used by both `Minga.Project` (editor-wide
  project awareness) and `Minga.LSP.RootDetector` (per-language-server roots).

  Pure functions, no process state.

  ## Detection order

  Walks up from the file's parent directory. The first directory containing
  any marker wins. Markers are checked in the order given, but since we stop
  at the nearest directory, the marker list order only matters when multiple
  markers exist in the same directory.

  ## Default markers

  `default_markers/0` returns a broad set covering common project types:
  `.git`, `mix.exs`, `Cargo.toml`, `package.json`, `go.mod`, `pyproject.toml`,
  `.minga` (sentinel file users can drop into any directory to mark a project root).
  """

  @typedoc "Project type inferred from the marker that matched."
  @type project_type :: atom()

  @typedoc "Detection result."
  @type result :: {:ok, root :: String.t(), project_type()} | :none

  # Non-language sentinel markers (always present regardless of Language registry)
  @sentinel_markers [
    {".git", :git},
    {".minga", :minga}
  ]

  @doc """
  Returns the default marker list as `{filename, project_type}` tuples.

  Combines sentinel markers (`.git`, `.minga`) with root markers from
  all registered languages. Pass a custom list to `detect/2` if you
  need different markers.
  """
  @spec default_markers() :: [{String.t(), project_type()}]
  def default_markers do
    lang_markers =
      Minga.Language.Registry.all()
      |> Enum.flat_map(fn lang ->
        type = lang.project_type || :unknown
        Enum.map(lang.root_markers, fn marker -> {marker, type} end)
      end)
      |> Enum.uniq_by(fn {marker, _} -> marker end)

    @sentinel_markers ++ lang_markers
  end

  @doc """
  Detects the project root for a file using the default marker list.

  Returns `{:ok, root_path, project_type}` or `:none`.

  ## Examples

      iex> {:ok, root, _type} = Minga.Project.Detector.detect("lib/minga/editor.ex")
      iex> File.exists?(Path.join(root, "mix.exs"))
      true
  """
  @spec detect(String.t()) :: result()
  def detect(file_path) when is_binary(file_path) do
    detect(file_path, default_markers())
  end

  @doc """
  Detects the project root for a file using a custom marker list.

  Each marker is a `{filename, project_type}` tuple. The walk stops at the
  first directory containing any marker file.

  Returns `{:ok, root_path, project_type}` or `:none`.
  """
  @spec detect(String.t(), [{String.t(), project_type()}]) :: result()
  def detect(file_path, markers) when is_binary(file_path) and is_list(markers) do
    file_path
    |> Path.expand()
    |> Path.dirname()
    |> walk_up(markers)
  end

  @doc """
  Finds the project root for a file given a flat list of marker filenames.

  This is the compatibility API used by `Minga.LSP.RootDetector`. It returns
  just the root path (no project type), falling back to `File.cwd!/0` when
  no marker is found.
  """
  @spec find_root(String.t(), [String.t()]) :: String.t()
  def find_root(file_path, root_markers)
      when is_binary(file_path) and is_list(root_markers) do
    typed_markers = Enum.map(root_markers, fn m -> {m, :unknown} end)

    case detect(file_path, typed_markers) do
      {:ok, root, _type} -> root
      :none -> File.cwd!()
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec walk_up(String.t(), [{String.t(), project_type()}]) :: result()
  defp walk_up(_dir, []), do: :none

  defp walk_up(dir, markers) do
    case find_marker(dir, markers) do
      {:ok, type} ->
        {:ok, dir, type}

      :none ->
        parent = Path.dirname(dir)

        if parent == dir do
          :none
        else
          walk_up(parent, markers)
        end
    end
  end

  @spec find_marker(String.t(), [{String.t(), project_type()}]) :: {:ok, project_type()} | :none
  defp find_marker(dir, markers) do
    Enum.find_value(markers, :none, fn {marker, type} ->
      path = Path.join(dir, marker)

      if File.exists?(path) do
        {:ok, type}
      else
        nil
      end
    end)
  end
end
