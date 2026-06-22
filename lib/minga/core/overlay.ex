defmodule Minga.Core.Overlay do
  @moduledoc """
  Lazy filesystem overlay using copy-on-write isolation.

  The overlay starts as an empty writable directory. Reads can resolve from the project root through higher-level callers, while writes, deletes, and command preparation materialize only the affected paths into the overlay. Shell commands can request a writable materialized view without making session startup copy the whole project.

  Build artifact and cache directories are skipped. `MIX_BUILD_PATH` points inside the overlay, while `MIX_DEPS_PATH` reuses the project deps path.
  """

  @typedoc "Overlay state."
  @type t :: %__MODULE__{
          overlay_dir: String.t(),
          project_root: String.t(),
          build_dir: String.t(),
          link_mode: :copy
        }

  @typedoc "Project materialization metrics."
  @type materialization_stats :: %{
          copied_files: non_neg_integer(),
          copied_bytes: non_neg_integer(),
          skipped_dirs: non_neg_integer()
        }

  @enforce_keys [:overlay_dir, :project_root, :build_dir, :link_mode]
  defstruct [:overlay_dir, :project_root, :build_dir, :link_mode]

  @tombstone_suffix ".__changeset_deleted__"

  @skip_dirs MapSet.new(
               ~w(_build .git .elixir_ls .expert .zig-cache zig-cache node_modules .hex .cache .gradle .swiftpm DerivedData deps)
             )

  @empty_stats %{copied_files: 0, copied_bytes: 0, skipped_dirs: 0}

  @doc """
  Creates a new lazy overlay directory for the project.

  The project tree is not copied during creation. Files are materialized when written or when command execution asks for a writable view.
  """
  @spec create(String.t()) :: {:ok, t()} | {:error, term()}
  def create(project_root) do
    Minga.Telemetry.span_with_stop_metadata([:minga, :overlay, :create], %{lazy: true}, fn ->
      result = create_result(project_root)
      {result, create_metadata(result)}
    end)
  end

  @spec create_result(String.t()) :: {:ok, t()} | {:error, term()}
  defp create_result(project_root) do
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
        {:ok,
         %__MODULE__{
           overlay_dir: overlay_dir,
           project_root: project_root,
           build_dir: build_dir,
           link_mode: :copy
         }}

      {:error, reason} ->
        {:error, {:mkdir_failed, overlay_dir, reason}}
    end
  end

  @spec create_metadata({:ok, t()} | {:error, term()}) :: map()
  defp create_metadata({:ok, %__MODULE__{overlay_dir: overlay_dir}}) do
    %{overlay_dir: overlay_dir, lazy: true, materialized: false, copied_files: 0, copied_bytes: 0}
  end

  defp create_metadata({:error, reason}) do
    %{lazy: true, materialized: false, error: inspect(reason)}
  end

  @doc """
  Writes a file into the overlay, replacing any overlay copy with real content.

  Creates parent directories as needed and never writes through to the project root.
  """
  @spec materialize_file(t(), String.t(), binary()) :: :ok | {:error, term()}
  def materialize_file(%__MODULE__{} = overlay, relative_path, content) do
    with :ok <- reject_tombstone_relative_path(relative_path),
         {:ok, target} <- safe_target(overlay, relative_path),
         :ok <- File.mkdir_p(Path.dirname(target)) do
      File.rm(tombstone_path(target))
      File.rm(target)

      case File.write(target, content) do
        :ok ->
          Minga.Telemetry.execute(
            [:minga, :overlay, :materialize_file],
            %{copied_files: 1, copied_bytes: byte_size(content)},
            %{path: relative_path}
          )

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Materializes the project into the overlay for shell command execution.

  Existing overlay files and deletion tombstones win over project-root files, so agent edits stay isolated and visible to commands.
  """
  @spec materialize_project(t()) :: {:ok, materialization_stats()} | {:error, term()}
  def materialize_project(%__MODULE__{} = overlay) do
    Minga.Telemetry.span_with_stop_metadata(
      [:minga, :overlay, :materialize_project],
      %{lazy: false},
      fn ->
        result =
          materialize_directory(overlay, overlay.project_root, overlay.overlay_dir, @empty_stats)

        {result, materialize_metadata(result)}
      end
    )
  end

  @doc """
  Deletes a file from the overlay view.

  Removes any materialized copy and writes a tombstone marker so lazy reads and directory listings know the project-root file is hidden.
  """
  @spec delete_file(t(), String.t()) :: :ok | {:error, term()}
  def delete_file(%__MODULE__{} = overlay, relative_path) do
    with :ok <- reject_tombstone_relative_path(relative_path),
         {:ok, target} <- safe_target(overlay, relative_path),
         {:ok, source} <- safe_project_path(overlay, relative_path),
         :ok <- ensure_deletable(target, source),
         :ok <- File.mkdir_p(Path.dirname(target)) do
      File.rm(target)
      File.write(tombstone_path(target), "")
    end
  end

  @doc "Returns true if a file was explicitly deleted in this overlay."
  @spec deleted?(t(), String.t()) :: boolean()
  def deleted?(%__MODULE__{} = overlay, relative_path) do
    marker = safe_target!(overlay, tombstone_relative_path(relative_path))
    File.exists?(marker)
  end

  @doc "Returns true if the overlay's materialized file differs from the project's file."
  @spec modified?(t(), String.t()) :: boolean()
  def modified?(%__MODULE__{} = overlay, relative_path) do
    overlay_file = safe_target!(overlay, relative_path)
    project_file = Path.join(overlay.project_root, relative_path)

    modified_contents?(
      File.read(overlay_file),
      File.read(project_file),
      deleted?(overlay, relative_path)
    )
  end

  @doc "Lists a directory by merging project-root entries with overlay changes."
  @spec list_directory(t(), String.t()) ::
          {:ok, [%{name: String.t(), type: :directory | :file}]} | {:error, term()}
  def list_directory(%__MODULE__{} = overlay, relative_path) do
    with :ok <- reject_tombstone_relative_path(relative_path),
         {:ok, overlay_dir} <- safe_overlay_path(overlay, relative_path),
         {:ok, project_dir} <- safe_project_path_allow_root(overlay, relative_path),
         {:ok, project_entries, overlay_entries} <- list_merged_entries(project_dir, overlay_dir) do
      deleted = deleted_entry_names(overlay_entries)

      entries =
        project_entries
        |> MapSet.new()
        |> MapSet.union(MapSet.new(overlay_entries))
        |> MapSet.to_list()
        |> Enum.reject(&hidden_entry?(deleted, &1))
        |> Enum.sort()
        |> Enum.map(&directory_entry(overlay, relative_path, &1))

      {:ok, entries}
    end
  end

  @doc "Environment variables for running shell commands inside the overlay."
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

  @doc "Removes the overlay directory and all its contents."
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{overlay_dir: dir}) do
    File.rm_rf!(dir)
    :ok
  end

  @spec safe_target(t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal | :symlink_traversal}
  defp safe_target(%__MODULE__{overlay_dir: overlay_dir}, relative_path) do
    root = Path.expand(overlay_dir)
    target = Path.join(root, relative_path) |> Path.expand()
    validate_target(root, target)
  end

  @spec safe_overlay_path(t(), String.t()) :: {:ok, String.t()} | {:error, :path_traversal}
  defp safe_overlay_path(%__MODULE__{overlay_dir: overlay_dir}, relative_path) do
    root = Path.expand(overlay_dir)
    target = Path.join(root, relative_path) |> Path.expand()
    validate_path_allow_root(root, target)
  end

  @spec safe_project_path(t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal}
  defp safe_project_path(%__MODULE__{} = overlay, relative_path) do
    root = Path.expand(overlay.project_root)
    target = Path.join(root, relative_path) |> Path.expand()
    validate_target_without_symlink_check(root, target)
  end

  @spec safe_project_path_allow_root(t(), String.t()) ::
          {:ok, String.t()} | {:error, :path_traversal}
  defp safe_project_path_allow_root(%__MODULE__{} = overlay, relative_path) do
    root = Path.expand(overlay.project_root)
    target = Path.join(root, relative_path) |> Path.expand()
    validate_path_allow_root(root, target)
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

  @spec validate_target_without_symlink_check(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal}
  defp validate_target_without_symlink_check(root, root), do: {:error, :invalid_path}

  defp validate_target_without_symlink_check(root, target) do
    if inside_directory?(target, root), do: {:ok, target}, else: {:error, :path_traversal}
  end

  @spec validate_path_allow_root(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :path_traversal}
  defp validate_path_allow_root(root, root), do: {:ok, root}

  defp validate_path_allow_root(root, target) do
    if inside_directory?(target, root), do: {:ok, target}, else: {:error, :path_traversal}
  end

  @spec reject_symlink_traversal(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :symlink_traversal}
  defp reject_symlink_traversal(root, target) do
    if symlink_traversal?(root, target), do: {:error, :symlink_traversal}, else: {:ok, target}
  end

  @spec tombstone_path(String.t()) :: String.t()
  defp tombstone_path(path), do: path <> @tombstone_suffix

  @spec tombstone_relative_path(String.t()) :: String.t()
  defp tombstone_relative_path(relative_path), do: tombstone_path(relative_path)

  @spec reject_tombstone_relative_path(String.t()) :: :ok | {:error, :invalid_path}
  defp reject_tombstone_relative_path(relative_path) do
    if tombstone_component?(Path.split(relative_path)),
      do: {:error, :invalid_path},
      else: :ok
  end

  @spec tombstone_component?([String.t()]) :: boolean()
  defp tombstone_component?(components) do
    Enum.any?(components, &String.ends_with?(&1, @tombstone_suffix))
  end

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
    |> symlink_reduce_result?()
  end

  @spec symlink_reduce_result?(true | String.t()) :: boolean()
  defp symlink_reduce_result?(true), do: true
  defp symlink_reduce_result?(_path), do: false

  @spec ensure_deletable(String.t(), String.t()) :: :ok | {:error, :file_not_found}
  defp ensure_deletable(target, source) do
    if File.exists?(target) or File.exists?(source), do: :ok, else: {:error, :file_not_found}
  end

  @spec modified_contents?(
          {:ok, binary()} | {:error, term()},
          {:ok, binary()} | {:error, term()},
          boolean()
        ) :: boolean()
  defp modified_contents?(_overlay, _project, true), do: true

  defp modified_contents?({:ok, overlay_content}, {:ok, project_content}, false),
    do: overlay_content != project_content

  defp modified_contents?({:ok, _overlay_content}, {:error, _}, false), do: true
  defp modified_contents?(_overlay, _project, false), do: false

  @spec materialize_directory(t(), String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp materialize_directory(%__MODULE__{} = overlay, source_dir, target_dir, stats) do
    case File.ls(source_dir) do
      {:ok, entries} -> materialize_entries(entries, overlay, source_dir, target_dir, stats)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec materialize_entries([String.t()], t(), String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp materialize_entries(entries, overlay, source_dir, target_dir, stats) do
    Enum.reduce_while(entries, {:ok, stats}, fn entry, {:ok, acc} ->
      case materialize_entry(overlay, source_dir, target_dir, entry, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec materialize_entry(t(), String.t(), String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp materialize_entry(overlay, source_dir, target_dir, entry, stats) do
    if MapSet.member?(@skip_dirs, entry) do
      {:ok, increment_skipped(stats)}
    else
      source_path = Path.join(source_dir, entry)
      target_path = Path.join(target_dir, entry)
      materialize_path(overlay, source_path, target_path, stats)
    end
  end

  @spec materialize_path(t(), String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp materialize_path(overlay, source_path, target_path, stats) do
    case File.lstat(source_path) do
      {:ok, %{type: :directory}} ->
        materialize_directory_path(overlay, source_path, target_path, stats)

      {:ok, %{type: :regular}} ->
        materialize_regular_file(overlay, source_path, target_path, stats)

      {:ok, _other} ->
        {:ok, stats}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec materialize_directory_path(t(), String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp materialize_directory_path(overlay, source_path, target_path, stats) do
    with :ok <- reject_materialization_symlink(overlay, target_path) do
      materialize_directory_after_symlink_check(overlay, source_path, target_path, stats)
    end
  end

  @spec materialize_directory_after_symlink_check(
          t(),
          String.t(),
          String.t(),
          materialization_stats()
        ) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp materialize_directory_after_symlink_check(overlay, source_path, target_path, stats) do
    if File.regular?(target_path) or File.exists?(tombstone_path(target_path)) do
      {:ok, stats}
    else
      mkdir_and_materialize_directory(overlay, source_path, target_path, stats)
    end
  end

  @spec mkdir_and_materialize_directory(t(), String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp mkdir_and_materialize_directory(overlay, source_path, target_path, stats) do
    with :ok <- File.mkdir_p(target_path) do
      materialize_directory(overlay, source_path, target_path, stats)
    end
  end

  @spec materialize_regular_file(t(), String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp materialize_regular_file(overlay, source_path, target_path, stats) do
    with :ok <- reject_materialization_symlink(overlay, target_path) do
      if File.exists?(target_path) or File.exists?(tombstone_path(target_path)) do
        {:ok, stats}
      else
        copy_regular_file(source_path, target_path, stats)
      end
    end
  end

  @spec copy_regular_file(String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp copy_regular_file(source_path, target_path, stats) do
    with {:ok, stat} <- File.stat(source_path),
         :ok <- File.mkdir_p(Path.dirname(target_path)),
         :ok <- File.cp(source_path, target_path) do
      {:ok,
       %{
         stats
         | copied_files: stats.copied_files + 1,
           copied_bytes: stats.copied_bytes + stat.size
       }}
    end
  end

  @spec reject_materialization_symlink(t(), String.t()) ::
          :ok | {:error, :path_traversal | :symlink_traversal}
  defp reject_materialization_symlink(%__MODULE__{} = overlay, target_path) do
    root = Path.expand(overlay.overlay_dir)
    target = Path.expand(target_path)

    with {:ok, _target} <- validate_path_allow_root(root, target),
         {:ok, _target} <- reject_symlink_traversal(root, target) do
      :ok
    end
  end

  @spec increment_skipped(materialization_stats()) :: materialization_stats()
  defp increment_skipped(stats), do: %{stats | skipped_dirs: stats.skipped_dirs + 1}

  @spec materialize_metadata({:ok, materialization_stats()} | {:error, term()}) :: map()
  defp materialize_metadata({:ok, stats}), do: Map.merge(stats, %{materialized: true})
  defp materialize_metadata({:error, reason}), do: %{materialized: false, error: inspect(reason)}

  @spec list_merged_entries(String.t(), String.t()) ::
          {:ok, [String.t()], [String.t()]} | {:error, term()}
  defp list_merged_entries(project_dir, overlay_dir) do
    list_result(File.ls(project_dir), File.ls(overlay_dir))
  end

  @spec list_result(
          {:ok, [String.t()]} | {:error, term()},
          {:ok, [String.t()]} | {:error, term()}
        ) :: {:ok, [String.t()], [String.t()]} | {:error, term()}
  defp list_result({:ok, project_entries}, {:ok, overlay_entries}),
    do: {:ok, project_entries, overlay_entries}

  defp list_result({:ok, project_entries}, {:error, :enoent}), do: {:ok, project_entries, []}
  defp list_result({:error, :enoent}, {:ok, overlay_entries}), do: {:ok, [], overlay_entries}
  defp list_result({:error, reason}, {:error, :enoent}), do: {:error, reason}
  defp list_result({:error, :enoent}, {:error, reason}), do: {:error, reason}
  defp list_result({:error, reason}, _overlay_result), do: {:error, reason}
  defp list_result(_project_result, {:error, reason}), do: {:error, reason}

  @spec deleted_entry_names([String.t()]) :: MapSet.t(String.t())
  defp deleted_entry_names(entries) do
    entries
    |> Enum.filter(&tombstone_name?/1)
    |> Enum.map(&String.replace_suffix(&1, @tombstone_suffix, ""))
    |> MapSet.new()
  end

  @spec tombstone_name?(String.t()) :: boolean()
  defp tombstone_name?(name), do: String.ends_with?(name, @tombstone_suffix)

  @spec hidden_entry?(MapSet.t(String.t()), String.t()) :: boolean()
  defp hidden_entry?(deleted, entry) do
    tombstone_name?(entry) or MapSet.member?(deleted, entry) or MapSet.member?(@skip_dirs, entry)
  end

  @spec directory_entry(t(), String.t(), String.t()) :: %{
          name: String.t(),
          type: :directory | :file
        }
  defp directory_entry(%__MODULE__{} = overlay, relative_path, name) do
    overlay_path = Path.join([overlay.overlay_dir, relative_path, name])
    project_path = Path.join([overlay.project_root, relative_path, name])

    type =
      if File.dir?(overlay_path) or (not File.exists?(overlay_path) and File.dir?(project_path)),
        do: :directory,
        else: :file

    %{name: name, type: type}
  end
end
