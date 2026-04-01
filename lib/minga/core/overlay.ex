defmodule Minga.Core.Overlay do
  @moduledoc """
  Filesystem overlay using hardlinks for copy-on-write isolation.

  Mirrors a project directory by hardlinking every source file into a
  temporary overlay directory. Unmodified files are zero-cost hardlinks
  that appear as regular files to every tool (grep, compilers, test
  runners). When a file is modified, the hardlink is replaced with a
  real file containing new content. The original project file stays
  untouched.

  On filesystems where hardlinks fail (cross-device mounts), falls back
  to file copies automatically.

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

  # Directories skipped entirely during mirroring.
  # _build gets its own isolated path. deps is symlinked for sharing.
  @skip_dirs MapSet.new(~w(_build .git .elixir_ls node_modules .hex))

  # Directories symlinked wholesale (read-only sharing).
  @symlink_dirs MapSet.new(~w(deps))

  @doc """
  Creates a new overlay directory mirroring the project.

  Walks the project tree, creating real directories and hardlinking (or
  copying) every source file. Returns `{:ok, overlay}` or `{:error, reason}`.
  """
  @spec create(String.t()) :: {:ok, t()} | {:error, term()}
  def create(project_root) do
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
  Writes a file into the overlay, replacing any hardlink with real content.

  Deletes the existing file first (to break the hardlink), then writes
  the new content. Creates parent directories as needed.
  """
  @spec materialize_file(t(), String.t(), binary()) :: :ok | {:error, term()}
  def materialize_file(%__MODULE__{} = overlay, relative_path, content) do
    target = Path.join(overlay.overlay_dir, relative_path)
    File.mkdir_p!(Path.dirname(target))

    # Must delete before writing. Writing through a hardlink would
    # modify the original file.
    File.rm(target)
    File.write(target, content)
  end

  @doc """
  Deletes a file from the overlay.

  Removes the hardlink (or copy) and writes a tombstone marker so the
  overlay can distinguish "intentionally deleted" from "never existed".
  """
  @spec delete_file(t(), String.t()) :: :ok | {:error, term()}
  def delete_file(%__MODULE__{} = overlay, relative_path) do
    target = Path.join(overlay.overlay_dir, relative_path)

    case File.rm(target) do
      :ok ->
        marker = target <> ".__changeset_deleted__"
        File.write!(marker, "")
        :ok

      {:error, :enoent} ->
        {:error, :file_not_found}
    end
  end

  @doc "Returns true if a file was explicitly deleted in this overlay."
  @spec deleted?(t(), String.t()) :: boolean()
  def deleted?(%__MODULE__{} = overlay, relative_path) do
    marker = Path.join(overlay.overlay_dir, relative_path <> ".__changeset_deleted__")
    File.exists?(marker)
  end

  @doc """
  Returns true if the overlay's copy of a file differs from the project's.

  Compares inodes: a hardlink shares the project file's inode, so a
  different inode means the overlay has a modified copy. A file that
  exists only in the overlay (new file) is also considered modified.
  """
  @spec modified?(t(), String.t()) :: boolean()
  def modified?(%__MODULE__{} = overlay, relative_path) do
    overlay_file = Path.join(overlay.overlay_dir, relative_path)
    project_file = Path.join(overlay.project_root, relative_path)

    case {File.stat(overlay_file), File.stat(project_file)} do
      {{:ok, o}, {:ok, p}} -> o.inode != p.inode
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

  @spec detect_link_mode(String.t(), String.t()) :: :hardlink | :copy
  defp detect_link_mode(project_root, overlay_dir) do
    test_source = find_any_file(project_root)

    if test_source do
      test_target = Path.join(overlay_dir, ".link_test")

      case File.ln(test_source, test_target) do
        :ok ->
          File.rm!(test_target)
          :hardlink

        {:error, _} ->
          :copy
      end
    else
      # Empty project, default to hardlink (will fail gracefully per-file)
      :hardlink
    end
  end

  @spec find_any_file(String.t()) :: String.t() | nil
  defp find_any_file(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.find_value(entries, &regular_file(dir, &1))
      _ -> nil
    end
  end

  @spec regular_file(String.t(), String.t()) :: String.t() | nil
  defp regular_file(dir, entry) do
    path = Path.join(dir, entry)
    if File.regular?(path), do: path, else: nil
  end

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
  defp link_or_copy(%__MODULE__{link_mode: :hardlink}, source, target) do
    case File.ln(source, target) do
      :ok -> :ok
      {:error, _} -> File.cp!(source, target)
    end
  end

  defp link_or_copy(%__MODULE__{link_mode: :copy}, source, target) do
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
