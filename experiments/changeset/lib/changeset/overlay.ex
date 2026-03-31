defmodule Changeset.Overlay do
  @moduledoc """
  Manages the overlay directory for a changeset.

  The overlay mirrors the project's directory structure. All directories
  are real. Unmodified files are **hardlinks** to the originals (not
  symlinks, because grep -r, rg, and other recursive search tools skip
  symlinks). Hardlinks appear as regular files to every tool.

  On filesystems where hardlinks fail (cross-device, e.g. tmpfs /tmp
  with ext4 /home on Linux), falls back to file copies automatically.

  When a file is modified, its hardlink is replaced with a real file
  containing the new content. The original project file is untouched.

  Build artifact directories (_build, deps, .git) are NOT symlinked.
  Instead, shell commands run with `MIX_BUILD_PATH` set to an isolated
  build directory inside the overlay, preventing contamination of the
  real project's _build.
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
  """
  @spec create(String.t()) :: {:ok, t()} | {:error, term()}
  def create(project_root) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    overlay_dir = Path.join(System.tmp_dir!(), "changeset-#{id}")
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

  The hardlink (or copy) is removed. A marker file is written so the
  overlay knows this file was intentionally deleted (not just absent).
  """
  @spec delete_file(t(), String.t()) :: :ok | {:error, term()}
  def delete_file(%__MODULE__{} = overlay, relative_path) do
    target = Path.join(overlay.overlay_dir, relative_path)

    case File.rm(target) do
      :ok ->
        # Write a tombstone marker so we know this deletion is intentional
        marker = target <> ".__changeset_deleted__"
        File.write!(marker, "")
        :ok

      {:error, :enoent} ->
        {:error, :file_not_found}
    end
  end

  @doc "Returns true if a file was explicitly deleted in this changeset."
  @spec deleted?(t(), String.t()) :: boolean()
  def deleted?(%__MODULE__{} = overlay, relative_path) do
    marker = Path.join(overlay.overlay_dir, relative_path <> ".__changeset_deleted__")
    File.exists?(marker)
  end

  @doc "Returns true if the file has been modified (different inode or new file)."
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

  @doc "Environment variables for running commands in the overlay."
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

  @doc "Removes the overlay directory."
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{overlay_dir: dir}) do
    remove_symlinks_recursive(dir)
    File.rm_rf!(dir)
    :ok
  end

  # -- Private --

  # Detect whether hardlinks work between project and overlay.
  # Falls back to copy mode if they don't (cross-filesystem).
  defp detect_link_mode(project_root, overlay_dir) do
    # Find any file in the project to test with
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
      # Empty project, default to hardlink (will fail gracefully per-file if needed)
      :hardlink
    end
  end

  defp find_any_file(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.find_value(entries, fn entry ->
          path = Path.join(dir, entry)
          if File.regular?(path), do: path, else: nil
        end)

      _ ->
        nil
    end
  end

  defp mirror_directory(%__MODULE__{} = overlay, source_dir, target_dir) do
    case File.ls(source_dir) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          source_path = Path.join(source_dir, entry)
          target_path = Path.join(target_dir, entry)

          cond do
            MapSet.member?(@skip_dirs, entry) ->
              :ok

            MapSet.member?(@symlink_dirs, entry) and File.dir?(source_path) ->
              File.ln_s!(source_path, target_path)

            File.dir?(source_path) and not symlink?(source_path) ->
              File.mkdir_p!(target_path)
              mirror_directory(overlay, source_path, target_path)

            File.regular?(source_path) ->
              link_or_copy(overlay, source_path, target_path)

            true ->
              :ok
          end
        end)

      {:error, _} ->
        :ok
    end
  end

  defp link_or_copy(%__MODULE__{link_mode: :hardlink}, source, target) do
    case File.ln(source, target) do
      :ok -> :ok
      {:error, _} -> File.cp!(source, target)
    end
  end

  defp link_or_copy(%__MODULE__{link_mode: :copy}, source, target) do
    File.cp!(source, target)
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      _ -> false
    end
  end

  defp remove_symlinks_recursive(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          path = Path.join(dir, entry)

          case File.lstat(path) do
            {:ok, %{type: :symlink}} -> File.rm!(path)
            {:ok, %{type: :directory}} -> remove_symlinks_recursive(path)
            _ -> :ok
          end
        end)

      {:error, _} ->
        :ok
    end
  end
end
