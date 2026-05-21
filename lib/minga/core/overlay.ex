defmodule Minga.Core.Overlay do
  @moduledoc """
  Filesystem overlay using file copies for copy-on-write isolation.

  Mirrors a project directory by copying every source file into a
  temporary overlay directory. Unmodified files are regular writable
  files that appear to shell commands, compilers, and test runners.
  When a file is modified, the overlay copy changes and the original
  project file stays untouched.

  Build artifact directories (`_build`, `.git`, `.elixir_ls`) are skipped
  entirely. `deps` is symlinked for read-only sharing. Shell commands run
  with `MIX_BUILD_PATH` set to an isolated build directory inside the
  overlay, preventing contamination of the real project's `_build`.
  """

  @typedoc "Overlay state."
  @type t :: %__MODULE__{
          overlay_dir: String.t(),
          project_root: String.t(),
          build_dir: String.t(),
          link_mode: :hardlink | :copy
        }

  @enforce_keys [:overlay_dir, :project_root, :build_dir, :link_mode]
  defstruct [:overlay_dir, :project_root, :build_dir, :link_mode]

  @tombstone_suffix ".__changeset_deleted__"

  # Directories skipped entirely during mirroring.
  # _build gets its own isolated path. deps is symlinked for sharing.
  @skip_dirs MapSet.new(~w(_build .git .elixir_ls node_modules .hex))

  # Directories symlinked wholesale (read-only sharing).
  @symlink_dirs MapSet.new(~w(deps))

  @doc """
  Creates a new overlay directory mirroring the project.

  Walks the project tree, creating real directories and copying every
  source file. Returns `{:ok, overlay}` or `{:error, reason}`.
  """
  @spec create(String.t()) :: {:ok, t()} | {:error, term()}
  def create(project_root) do
    if File.dir?(project_root) do
      create_overlay(project_root)
    else
      {:error, {:invalid_project_root, project_root}}
    end
  end

  @spec create_overlay(String.t()) :: {:ok, t()} | {:error, term()}
  defp create_overlay(project_root) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    overlay_dir = Path.join(System.tmp_dir!(), "minga-overlay-#{id}")
    build_dir = Path.join(overlay_dir, "_build")

    case File.mkdir_p(overlay_dir) do
      :ok ->
        link_mode = detect_link_mode(project_root, overlay_dir)

        overlay = %__MODULE__{
          overlay_dir: overlay_dir,
          project_root: project_root,
          build_dir: build_dir,
          link_mode: link_mode
        }

        mirror_directory(overlay, project_root, overlay_dir)
        {:ok, overlay}

      {:error, reason} ->
        {:error, {:mkdir_failed, overlay_dir, reason}}
    end
  end

  @doc """
  Writes a file into the overlay, replacing the copied content with real content.

  Deletes the existing file first, then writes the new content. Creates
  parent directories as needed.
  """
  @spec materialize_file(t(), String.t(), binary()) :: :ok | {:error, term()}
  def materialize_file(%__MODULE__{} = overlay, relative_path, content) do
    with {:ok, target} <- safe_target(overlay, relative_path),
         :ok <- File.mkdir_p(Path.dirname(target)) do
      # Must delete before writing. Writing to the copied file is what
      # keeps the original project file untouched.
      File.rm(tombstone_path(target))
      File.rm(target)
      File.write(target, content)
    end
  end

  @doc """
  Deletes a file from the overlay.

  Removes the copy and writes a tombstone marker so the overlay can
  distinguish "intentionally deleted" from "never existed".
  """
  @spec delete_file(t(), String.t()) :: :ok | {:error, term()}
  def delete_file(%__MODULE__{} = overlay, relative_path) do
    with {:ok, target} <- safe_target(overlay, relative_path) do
      case File.rm(target) do
        :ok ->
          File.write!(tombstone_path(target), "")
          :ok

        {:error, :enoent} ->
          {:error, :file_not_found}
      end
    end
  end

  @doc "Returns true if a file was explicitly deleted in this overlay."
  @spec deleted?(t(), String.t()) :: boolean()
  def deleted?(%__MODULE__{} = overlay, relative_path) do
    marker = safe_target!(overlay, tombstone_relative_path(relative_path))
    File.exists?(marker)
  end

  @doc """
  Returns true if the overlay's copy of a file differs from the project's.

  Compares file contents directly. A file that exists only in the overlay
  (new file) is also considered modified.
  """
  @spec modified?(t(), String.t()) :: boolean()
  def modified?(%__MODULE__{} = overlay, relative_path) do
    overlay_file = safe_target!(overlay, relative_path)
    project_file = Path.join(overlay.project_root, relative_path)

    case {File.read(overlay_file), File.read(project_file)} do
      {{:ok, overlay_content}, {:ok, project_content}} -> overlay_content != project_content
      {{:ok, _}, {:error, _}} -> true
      _ -> false
    end
  end

  @doc """
  Environment variables for running shell commands inside the overlay.

  Sets `MIX_BUILD_PATH` to an isolated build directory so compilation
  inside the overlay doesn't contaminate the real project's `_build`.
  """
  @spec command_env(t()) :: [{String.t(), String.t()}]
  def command_env(%__MODULE__{} = overlay) do
    [
      {"MIX_BUILD_PATH", overlay.build_dir},
      {"MIX_DEPS_PATH", Path.join(overlay.project_root, "deps")},
      {"PAGER", "cat"},
      {"GIT_PAGER", "cat"},
      {"TERM", "dumb"}
    ]
  end

  @doc """
  Removes the overlay directory and all its contents.

  Symlinks are removed first (to avoid following them into the real
  project during recursive deletion).
  """
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{overlay_dir: dir}) do
    remove_symlinks_recursive(dir)
    File.rm_rf!(dir)
    :ok
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec safe_target(t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal | :symlink_traversal}
  defp safe_target(%__MODULE__{overlay_dir: overlay_dir}, relative_path) do
    root = Path.expand(overlay_dir)
    target = Path.join(root, relative_path) |> Path.expand()
    validate_target(root, target)
  end

  @spec validate_target(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal | :symlink_traversal}
  defp validate_target(root, root), do: {:error, :invalid_path}

  defp validate_target(root, target) do
    if inside_directory?(target, root) do
      reject_symlink_traversal(root, target)
    else
      {:error, :path_traversal}
    end
  end

  @spec reject_symlink_traversal(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :symlink_traversal}
  defp reject_symlink_traversal(root, target) do
    if symlink_traversal?(root, target) do
      {:error, :symlink_traversal}
    else
      {:ok, target}
    end
  end

  @spec tombstone_path(String.t()) :: String.t()
  defp tombstone_path(path), do: path <> @tombstone_suffix

  @spec tombstone_relative_path(String.t()) :: String.t()
  defp tombstone_relative_path(relative_path), do: tombstone_path(relative_path)

  @spec safe_target!(t(), String.t()) :: String.t() | no_return()
  defp safe_target!(%__MODULE__{} = overlay, relative_path) do
    case safe_target(overlay, relative_path) do
      {:ok, target} ->
        target

      {:error, reason} ->
        raise ArgumentError, "unsafe overlay path #{inspect(relative_path)}: #{reason}"
    end
  end

  @spec inside_directory?(String.t(), String.t()) :: boolean()
  defp inside_directory?(path, root), do: String.starts_with?(path, root <> "/")

  @spec symlink_traversal?(String.t(), String.t()) :: boolean()
  defp symlink_traversal?(root, target) do
    target
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn component, parent ->
      path = Path.join(parent, component)

      case File.lstat(path) do
        {:ok, %{type: :symlink}} -> {:halt, true}
        _ -> {:cont, path}
      end
    end)
    |> case do
      true -> true
      _path -> false
    end
  end

  @spec detect_link_mode(String.t(), String.t()) :: :hardlink | :copy
  defp detect_link_mode(_project_root, _overlay_dir), do: :copy

  @spec mirror_directory(t(), String.t(), String.t()) :: :ok
  defp mirror_directory(%__MODULE__{} = overlay, source_dir, target_dir) do
    case File.ls(source_dir) do
      {:ok, entries} ->
        Enum.each(entries, &mirror_entry(overlay, source_dir, target_dir, &1))

      {:error, _} ->
        :ok
    end
  end

  @spec mirror_entry(t(), String.t(), String.t(), String.t()) :: :ok
  defp mirror_entry(overlay, source_dir, target_dir, entry) do
    if MapSet.member?(@skip_dirs, entry) do
      :ok
    else
      source_path = Path.join(source_dir, entry)
      target_path = Path.join(target_dir, entry)
      classify_and_mirror(overlay, source_path, target_path, entry)
    end
  end

  @spec classify_and_mirror(t(), String.t(), String.t(), String.t()) :: :ok
  defp classify_and_mirror(overlay, source_path, target_path, entry) do
    case entry_type(source_path, entry) do
      :symlink_dir ->
        File.ln_s!(source_path, target_path)

      :directory ->
        File.mkdir_p!(target_path)
        mirror_directory(overlay, source_path, target_path)

      :file ->
        link_or_copy(overlay, source_path, target_path)

      :skip ->
        :ok
    end
  end

  @spec entry_type(String.t(), String.t()) :: :symlink_dir | :directory | :file | :skip
  defp entry_type(source_path, entry) do
    is_dir = File.dir?(source_path)

    case {is_dir, MapSet.member?(@symlink_dirs, entry), File.regular?(source_path)} do
      {true, true, _} -> :symlink_dir
      {true, false, _} -> if symlink?(source_path), do: :skip, else: :directory
      {false, _, true} -> :file
      _ -> :skip
    end
  end

  @spec link_or_copy(t(), String.t(), String.t()) :: :ok
  defp link_or_copy(%__MODULE__{}, source, target) do
    File.cp!(source, target)
  end

  @spec symlink?(String.t()) :: boolean()
  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      _ -> false
    end
  end

  @spec remove_symlinks_recursive(String.t()) :: :ok
  defp remove_symlinks_recursive(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.each(entries, &remove_symlink_entry(dir, &1))

      {:error, _} ->
        :ok
    end
  end

  @spec remove_symlink_entry(String.t(), String.t()) :: :ok
  defp remove_symlink_entry(dir, entry) do
    path = Path.join(dir, entry)

    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> File.rm!(path)
      {:ok, %{type: :directory}} -> remove_symlinks_recursive(path)
      _ -> :ok
    end
  end
end
