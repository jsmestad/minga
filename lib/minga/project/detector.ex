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

  A `.minga` file marks a root anywhere. A `.minga` directory marks one too, because a project keeps its own instructions and skills there (`.minga/AGENTS.md`, `.minga/skills`), except in a folder that is too broad to be a project: the home directory, the filesystem root or a volume root (`Minga.Project.Root.broad_path?/1`). Minga keeps its own data in a `.minga` directory in the home directory, and that must not make the home directory a project.

  `.git` marks a root as a directory or as a file, which is what a worktree has. Language markers match as files or directories, because some are directories (`.dart_tool`, `_opam`).
  """

  alias Minga.Project.Root

  @typedoc "Project type inferred from the marker that matched."
  @type project_type :: atom()

  @typedoc "Detection result."
  @type result :: {:ok, root :: String.t(), project_type()} | :none

  # Non-language sentinel markers (always present regardless of Language registry)
  @sentinel_markers [
    {".git", :git},
    {".minga", :minga}
  ]

  # Markers that mean a directory is under version control.
  @version_control_markers [".git"]

  # A directory with this name is Minga's own data when the folder is too broad to be a project.
  @own_directory_marker ".minga"

  @typedoc "Tells whether a folder is too broad to be a project. A test supplies its own home directory this way."
  @type broad :: (String.t() -> boolean())

  @doc """
  Returns the default marker list as `{filename, project_type}` tuples.

  Combines sentinel markers (`.git`, `.minga`) with root markers from registered languages. Before the registry starts, use the enabled bundled language definitions so launch-time detection sees the same built-in markers.
  """
  @spec default_markers() :: [{String.t(), project_type()}]
  def default_markers do
    lang_markers =
      marker_languages()
      |> Enum.flat_map(fn lang ->
        type = lang.project_type || :unknown
        Enum.map(lang.root_markers, fn marker -> {marker, type} end)
      end)
      |> Enum.uniq_by(fn {marker, _} -> marker end)

    @sentinel_markers ++ lang_markers
  end

  @spec marker_languages() :: [Minga.Language.t()]
  defp marker_languages do
    registry = Minga.Language.Registry

    if :ets.whereis(registry.default_table()) == :undefined do
      disabled = Minga.Extensions.PackLoader.disabled_pack_names(:disabled_language_packs)

      for pack <- Minga.Extensions.LanguagePacks.packs(),
          pack.name() not in disabled,
          language <- pack.language_modules() do
        language.definition()
      end
    else
      registry.all()
    end
  end

  @doc """
  Tells whether `dir` itself is the root of a version-controlled tree.

  The agent trusts a root as broad as the home directory only on this evidence. Any other marker there, a stray `package.json` for one, says nothing about whether the whole folder is one project.
  """
  @spec version_controlled?(String.t()) :: boolean()
  def version_controlled?(dir) when is_binary(dir) do
    Enum.any?(@version_control_markers, &File.exists?(Path.join(dir, &1)))
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
  @spec detect(String.t(), [{String.t(), project_type()}], broad()) :: result()
  def detect(file_path, markers, broad? \\ &broad_folder?/1)
      when is_binary(file_path) and is_list(markers) and is_function(broad?, 1) do
    file_path
    |> Path.expand()
    |> Path.dirname()
    |> walk_up(markers, broad?)
  end

  @doc """
  Finds the project root for a file given a flat list of marker filenames.

  This is the compatibility API used by `Minga.LSP.RootDetector`. It returns
  just the root path (no project type), falling back to the file's own folder when
  no marker is found. The process working directory is never the fallback: it is not where the file is.
  """
  @spec find_root(String.t(), [String.t()]) :: String.t()
  def find_root(file_path, root_markers)
      when is_binary(file_path) and is_list(root_markers) do
    typed_markers = Enum.map(root_markers, fn m -> {m, :unknown} end)

    case detect(file_path, typed_markers) do
      {:ok, root, _type} -> root
      :none -> file_path |> Path.expand() |> Path.dirname()
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec walk_up(String.t(), [{String.t(), project_type()}], broad()) :: result()
  defp walk_up(_dir, [], _broad?), do: :none

  defp walk_up(dir, markers, broad?) do
    case find_marker(dir, markers, broad?) do
      {:ok, type} ->
        {:ok, dir, type}

      :none ->
        parent = Path.dirname(dir)

        if parent == dir do
          :none
        else
          walk_up(parent, markers, broad?)
        end
    end
  end

  @spec find_marker(String.t(), [{String.t(), project_type()}], broad()) ::
          {:ok, project_type()} | :none
  defp find_marker(dir, markers, broad?) do
    Enum.find_value(markers, :none, fn {marker, type} ->
      if marker_present?(dir, marker, broad?), do: {:ok, type}
    end)
  end

  @spec marker_present?(String.t(), String.t(), broad()) :: boolean()
  defp marker_present?(dir, @own_directory_marker = marker, broad?) do
    path = Path.join(dir, marker)
    File.regular?(path) or (File.dir?(path) and not broad?.(dir))
  end

  defp marker_present?(dir, marker, _broad?), do: File.exists?(Path.join(dir, marker))

  # The folder is judged by where it really is, so a link to the home directory is as broad as the home directory.
  @spec broad_folder?(String.t()) :: boolean()
  defp broad_folder?(dir) do
    case Root.canonical_path(dir) do
      {:ok, canonical} -> Root.broad_path?(canonical)
      {:error, _reason} -> Root.broad_path?(dir)
    end
  end
end
