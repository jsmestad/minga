defmodule MingaAgent.Changeset.Overlay do
  @moduledoc """
  Lazy filesystem overlay using copy-on-write isolation.

  The overlay starts as an empty writable directory. Reads can resolve from the project root through higher-level callers, while writes, deletes, and command preparation materialize only the affected paths into the overlay. Shell commands can request a writable materialized view without making session startup copy the whole project.

  Build artifact and cache directories are skipped. `MIX_BUILD_PATH` and `CARGO_TARGET_DIR` point inside the overlay, while `MIX_DEPS_PATH` reuses the project deps path. A Rust `target` directory is skipped only when it sits next to a `Cargo.toml`, because `target` is an ordinary source directory name in other ecosystems.

  Installed JavaScript dependencies are cloned, not copied. The first materialization clones each project `node_modules` tree into the overlay with one copy-on-write clone (`MingaAgent.Changeset.Overlay.Cloner`, `cp -c` on APFS or `cp --reflink=always` on Linux), which shares data blocks with the project until either side writes. Node's upward `node_modules` lookup resolves packages from the overlay, and every write inside the tree, including changes inside an installed package by a postinstall script or `patch-package`, lands in the overlay. Links inside the tree are copied as links, so pnpm's relative links resolve inside the clone; a link with an absolute target, such as an `npm link`, still reaches that target. A later materialization keeps the existing tree and adds only entries it is missing, cloning each one.

  When a tree cannot be cloned (the overlay and the project are on different volumes, or the filesystem cannot share blocks), the overlay never copies its bytes. It builds a real `node_modules` directory instead and symlinks each installed package to the project's copy. `.bin`, `@scope`, and pnpm's `.pnpm` directories are real overlay directories whose existing entries are linked or, for small regular files such as shims, copied one by one. Tool caches (`node_modules/.vite`, `node_modules/.cache`), package-manager metadata, and newly installed packages land in the overlay, but a command that writes inside an installed package follows its link into the project. Each materialization that falls back says so once in `*Messages*`.

  A tool write, delete, or commit under a project `node_modules` first gets the dependency tree a command would see. A package link on its path that points at the project's copy is then replaced with a clone of that package. When the package cannot be cloned, the write is refused with `:symlink_traversal`, so a tool never writes through a link and never leaves a partial package behind.

  Paths the changeset server deletes, writes, or renames for cleanup come from `artifact_path/3`, which refuses a path that passes through a symlink, so discard and undo never reach project files through a linked package.
  """

  import Bitwise, only: [band: 2]

  alias Minga.Buffer.Persistence.SystemFileSystem
  alias MingaAgent.Changeset.Overlay.SystemCloner
  alias MingaAgent.Changeset.PublicationTarget

  @typedoc "Overlay state."
  @type t :: %__MODULE__{
          overlay_dir: String.t(),
          project_root: String.t(),
          build_dir: String.t(),
          link_mode: :copy,
          cloner: module()
        }

  @typedoc "Why a project read was refused or failed. The refusal names the project-relative path."
  @type read_error ::
          {:outside_project_root, String.t()} | PublicationTarget.error() | File.posix()

  @typedoc "Project materialization metrics."
  @type materialization_stats :: %{
          copied_files: non_neg_integer(),
          copied_bytes: non_neg_integer(),
          skipped_dirs: non_neg_integer(),
          linked_entries: non_neg_integer(),
          cloned_entries: non_neg_integer(),
          clone_fallbacks: non_neg_integer(),
          clone_fallback_reason: term()
        }

  @typedoc "Creation options. `:cloner` replaces the `MingaAgent.Changeset.Overlay.Cloner` implementation."
  @type create_opt :: {:cloner, module()}

  @enforce_keys [:overlay_dir, :project_root, :build_dir, :link_mode, :cloner]
  defstruct [:overlay_dir, :project_root, :build_dir, :link_mode, :cloner]

  @tombstone_suffix ".__changeset_deleted__"

  @skip_dirs MapSet.new(
               ~w(_build .git .elixir_ls .expert .zig-cache zig-cache node_modules .hex .cache .gradle .swiftpm DerivedData deps)
             )

  @empty_stats %{
    copied_files: 0,
    copied_bytes: 0,
    skipped_dirs: 0,
    linked_entries: 0,
    cloned_entries: 0,
    clone_fallbacks: 0,
    clone_fallback_reason: nil
  }

  @doc """
  Creates a private lazy overlay directory for the project.

  The project tree is not copied during creation. Files are materialized when written or when command execution asks for a writable view.
  """
  @spec create(String.t(), [create_opt()]) :: {:ok, t()} | {:error, term()}
  def create(project_root, opts \\ []) do
    cloner = Keyword.get_lazy(opts, :cloner, &default_cloner/0)

    Minga.Telemetry.span_with_stop_metadata([:minga, :overlay, :create], %{lazy: true}, fn ->
      result = create_result(project_root, cloner)
      {result, create_metadata(result)}
    end)
  end

  @spec default_cloner() :: module()
  defp default_cloner, do: Application.get_env(:minga, :overlay_cloner, SystemCloner)

  @spec create_result(String.t(), module()) :: {:ok, t()} | {:error, term()}
  defp create_result(project_root, cloner) do
    if File.dir?(project_root) do
      create_overlay(project_root, cloner)
    else
      {:error, {:invalid_project_root, project_root}}
    end
  end

  @spec create_overlay(String.t(), module()) :: {:ok, t()} | {:error, term()}
  defp create_overlay(project_root, cloner) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    overlay_dir = Path.join(System.tmp_dir!(), "minga-overlay-#{id}")
    build_dir = Path.join(overlay_dir, "_build")

    case File.mkdir(overlay_dir) do
      :ok ->
        case File.chmod(overlay_dir, 0o700) do
          :ok ->
            {:ok,
             %__MODULE__{
               overlay_dir: overlay_dir,
               project_root: project_root,
               build_dir: build_dir,
               link_mode: :copy,
               cloner: cloner
             }}

          {:error, reason} ->
            cleanup = File.rmdir(overlay_dir)
            {:error, {:chmod_failed, overlay_dir, reason, cleanup}}
        end

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
         :ok <- unshare_dependencies(overlay, relative_path),
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

  @doc "Installs a prepared mutation without removing prior bytes on failure. Private copies retain overlay ownership and source access permissions, not ownership-dependent special bits."
  @spec commit_file(t(), String.t(), binary() | :deleted) :: :ok | {:error, term()}
  def commit_file(%__MODULE__{} = overlay, relative_path, prepared) do
    with :ok <- reject_tombstone_relative_path(relative_path),
         :ok <- unshare_dependencies(overlay, relative_path),
         {:ok, target} <- safe_target(overlay, relative_path),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- regular_or_absent(target),
         :ok <- regular_or_absent(tombstone_path(target)),
         {:ok, metadata} <- commit_metadata(overlay, relative_path, target, prepared) do
      commit_prepared(target, prepared, metadata)
    end
  end

  @spec commit_prepared(String.t(), binary() | :deleted, File.Stat.t() | nil) ::
          :ok | {:error, term()}
  defp commit_prepared(target, prepared, metadata) do
    {destination, retired, bytes} =
      case prepared do
        :deleted -> {tombstone_path(target), target, ""}
        content -> {target, tombstone_path(target), content}
      end

    suffix = ".#{System.unique_integer([:positive])}"
    temporary = destination <> suffix <> ".tmp"
    backup = retired <> suffix <> ".backup"

    result =
      with :ok <- File.write(temporary, bytes, [:binary, :exclusive]),
           :ok <- preserve_access_mode(temporary, metadata),
           {:ok, backed_up?} <- backup_retired(retired, backup) do
        case File.rename(temporary, destination) do
          :ok ->
            File.rm(backup)
            :ok

          {:error, reason} ->
            rollback_commit(reason, retired, backup, backed_up?)
        end
      end

    File.rm(temporary)
    result
  end

  @spec preserve_access_mode(String.t(), File.Stat.t() | nil) :: :ok | {:error, term()}
  defp preserve_access_mode(_path, nil), do: :ok

  defp preserve_access_mode(path, %File.Stat{mode: mode}) do
    File.chmod(path, band(mode, 0o777))
  end

  @spec rollback_commit(term(), String.t(), String.t(), boolean()) :: {:error, term()}
  defp rollback_commit(reason, retired, backup, backed_up?) do
    case rollback_retired(retired, backup, backed_up?) do
      :ok -> {:error, reason}
      {:error, rollback} -> {:error, {:commit_failed, reason, rollback}}
    end
  end

  @spec commit_metadata(t(), String.t(), String.t(), binary() | :deleted) ::
          {:ok, File.Stat.t() | nil} | {:error, term()}
  defp commit_metadata(_overlay, _relative_path, _target, :deleted), do: {:ok, nil}

  defp commit_metadata(overlay, relative_path, target, _content) do
    case File.stat(target) do
      {:ok, metadata} ->
        {:ok, metadata}

      {:error, :enoent} ->
        case File.stat(Path.join(overlay.project_root, relative_path)) do
          {:ok, metadata} -> {:ok, metadata}
          {:error, :enoent} -> {:ok, nil}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @spec regular_or_absent(String.t()) :: :ok | {:error, term()}
  defp regular_or_absent(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _} -> {:error, :invalid_overlay_target}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec backup_retired(String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  defp backup_retired(retired, backup) do
    case File.rename(retired, backup) do
      :ok -> {:ok, true}
      {:error, :enoent} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rollback_retired(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  defp rollback_retired(retired, backup, true), do: File.rename(backup, retired)
  defp rollback_retired(_retired, _backup, false), do: :ok

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

        report_clone_fallback(result)
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
         :ok <- unshare_dependencies(overlay, relative_path),
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

    modified_contents?(
      File.read(overlay_file),
      read_project_file(overlay, relative_path),
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
      {"CARGO_TARGET_DIR", Path.join(overlay.build_dir, "cargo")},
      {"PAGER", "cat"},
      {"GIT_PAGER", "cat"},
      {"TERM", "dumb"}
    ]
  end

  @doc """
  Reads a project file the way the overlay's lazy view does.

  Every symlink in `relative_path` is resolved first. When the real path leaves the project root, returns `{:error, {:outside_project_root, relative_path}}` and reads nothing.
  """
  @spec read_project_file(t(), String.t()) :: {:ok, binary()} | {:error, read_error()}
  def read_project_file(%__MODULE__{} = overlay, relative_path) do
    with {:ok, path} <- project_read_path(overlay, relative_path), do: File.read(path)
  end

  @doc """
  Returns the real path to open when reading `relative_path` from the project.

  Every symlink is resolved, and a missing tail is allowed so the caller's own read reports `:enoent`. A real path outside the project root returns `{:error, {:outside_project_root, relative_path}}`.
  """
  @spec project_read_path(t(), String.t()) :: {:ok, String.t()} | {:error, read_error()}
  def project_read_path(%__MODULE__{project_root: root}, relative_path) do
    resolve_project_read(Path.expand(root), relative_path)
  end

  @spec resolve_project_read(String.t(), String.t()) :: {:ok, String.t()} | {:error, read_error()}
  defp resolve_project_read(root, relative_path) do
    case PublicationTarget.read_path(root, relative_path, {SystemFileSystem, []}) do
      {:ok, path} -> {:ok, path}
      {:error, :outside_project_root} -> {:error, {:outside_project_root, relative_path}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the overlay path for `relative_path` plus an optional artifact `suffix`, such as a tombstone or backup suffix.

  The path is refused when it leaves the overlay or passes through a symlink. Materialized `node_modules` entries are symlinks into the project, so a caller that deletes, writes, or renames the returned path cannot reach a project file.
  """
  @spec artifact_path(t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal | :symlink_traversal}
  def artifact_path(%__MODULE__{} = overlay, relative_path, suffix \\ "") do
    safe_target(overlay, relative_path <> suffix)
  end

  @doc """
  Removes the overlay directory and all its contents.

  The directory is renamed aside at once, so the overlay is gone when this returns, and its contents are removed in the background. A cloned `node_modules` can hold tens of thousands of entries, and removing them must not hold up a publish or discard. Links inside the overlay are removed, never followed.
  """
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{overlay_dir: dir, cloner: cloner}) do
    removing = "#{dir}.#{System.unique_integer([:positive])}.removing"

    case File.rename(dir, removing) do
      :ok -> remove_in_background(cloner, removing)
      {:error, :enoent} -> :ok
      {:error, _reason} -> remove_now(cloner, dir)
    end
  end

  @spec remove_in_background(module(), String.t()) :: :ok
  defp remove_in_background(cloner, path) do
    case Task.Supervisor.start_child(Minga.Eval.TaskSupervisor, fn -> remove_now(cloner, path) end) do
      {:ok, _pid} -> :ok
      {:error, _reason} -> remove_now(cloner, path)
    end
  catch
    :exit, _reason -> remove_now(cloner, path)
  end

  @spec remove_now(module(), String.t()) :: :ok
  defp remove_now(cloner, path) do
    case cloner.remove(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Minga.Log.warning(
          :agent,
          "Agent overlay #{path} could not be removed: #{inspect(reason)}"
        )
    end
  end

  # A tool write under a project node_modules first gets the dependency tree a
  # command would see. Then every package link on the path that points at the
  # project's copy of that path is replaced by a clone, so the write stays in
  # the overlay. A link that cannot be cloned is left alone, and the write is
  # refused with :symlink_traversal.
  @spec unshare_dependencies(t(), String.t()) :: :ok | {:error, term()}
  defp unshare_dependencies(%__MODULE__{} = overlay, relative_path) do
    root = Path.expand(overlay.overlay_dir)
    target = root |> Path.join(relative_path) |> Path.expand()

    with {:ok, target} <- validate_target_without_symlink_check(root, target) do
      target |> Path.relative_to(root) |> Path.split() |> unshare_components(overlay)
    end
  end

  @spec unshare_components([String.t()], t()) :: :ok | {:error, term()}
  defp unshare_components(components, overlay) do
    case dependency_prefix(components) do
      nil ->
        :ok

      prefix ->
        with :ok <- place_enclosing_dependencies(overlay, Path.join(prefix)) do
          unshare_package_links(overlay, components)
        end
    end
  end

  # The outermost node_modules that the path lies inside, as path components.
  @spec dependency_prefix([String.t()]) :: [String.t()] | nil
  defp dependency_prefix(components) do
    case Enum.split_while(components, &(&1 != "node_modules")) do
      {outside, ["node_modules", _inside | _rest]} -> Enum.take(components, length(outside) + 1)
      _not_inside -> nil
    end
  end

  @spec place_enclosing_dependencies(t(), String.t()) :: :ok | {:error, term()}
  defp place_enclosing_dependencies(overlay, relative_dir) do
    project = Path.expand(overlay.project_root)
    source = Path.join(project, relative_dir)
    target = Path.join(Path.expand(overlay.overlay_dir), relative_dir)

    if absent?(target) and real_project_directory?(project, source) do
      result = place_dependencies(overlay, source, target, @empty_stats)
      report_clone_fallback(result)

      with {:ok, _stats} <- result, do: :ok
    else
      :ok
    end
  end

  @spec absent?(String.t()) :: boolean()
  defp absent?(path), do: match?({:error, :enoent}, File.lstat(path))

  # A project directory reached without following any symlink.
  @spec real_project_directory?(String.t(), String.t()) :: boolean()
  defp real_project_directory?(project, path) do
    match?({:ok, %{type: :directory}}, File.lstat(path)) and not symlink_traversal?(project, path)
  end

  # The written file itself is never unshared: only the directories above it.
  @spec unshare_package_links(t(), [String.t()]) :: :ok | {:error, term()}
  defp unshare_package_links(overlay, components) do
    start = {Path.expand(overlay.overlay_dir), Path.expand(overlay.project_root)}

    components
    |> Enum.drop(-1)
    |> Enum.reduce_while(start, fn component, {overlay_parent, project_parent} ->
      overlay_path = Path.join(overlay_parent, component)
      project_path = Path.join(project_parent, component)

      case unshare_link(overlay, overlay_path, project_path) do
        :ok -> {:cont, {overlay_path, project_path}}
        :stop -> {:halt, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> unshare_result()
  end

  @spec unshare_result({String.t(), String.t()} | :ok | {:error, term()}) ::
          :ok | {:error, term()}
  defp unshare_result({_overlay_path, _project_path}), do: :ok
  defp unshare_result(result), do: result

  # Only a link that points at the project's copy of the same path, as
  # materialization creates them, is replaced, and only by a clone of a real
  # project directory.
  @spec unshare_link(t(), String.t(), String.t()) :: :ok | :stop | {:error, term()}
  defp unshare_link(overlay, overlay_path, project_path) do
    case File.lstat(overlay_path) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, %{type: :symlink}} ->
        if File.read_link(overlay_path) == {:ok, project_path} and
             real_project_directory?(Path.expand(overlay.project_root), project_path),
           do: replace_link_with_clone(overlay, overlay_path, project_path),
           else: :stop

      _other ->
        :stop
    end
  end

  @spec replace_link_with_clone(t(), String.t(), String.t()) :: :ok | {:error, term()}
  defp replace_link_with_clone(overlay, link, project_path) do
    unique = System.unique_integer([:positive])
    clone = Path.join(Path.dirname(link), ".#{Path.basename(link)}.#{unique}.clone")

    case clone_entry(overlay, project_path, clone) do
      :ok -> swap_clone_for_link(clone, link, project_path)
      {:fallback, _reason} -> {:error, :symlink_traversal}
      {:error, _reason} = error -> error
    end
  end

  # A directory cannot be renamed over a symlink, so the link goes first. If
  # the rename fails, the link is put back.
  @spec swap_clone_for_link(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  defp swap_clone_for_link(clone, link, project_path) do
    with :ok <- File.rm(link) do
      case File.rename(clone, link) do
        :ok ->
          :ok

        {:error, reason} ->
          _ = File.ln_s(project_path, link)
          _ = File.rm_rf(clone)
          {:error, reason}
      end
    end
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

  # Staging a deletion refuses a project path that leaves the root through a
  # symlink, the same rule publication enforces before it unlinks the entry.
  @spec safe_project_path(t(), String.t()) ::
          {:ok, String.t()}
          | {:error, :invalid_path | :path_traversal | PublicationTarget.error()}
  defp safe_project_path(%__MODULE__{} = overlay, relative_path) do
    root = Path.expand(overlay.project_root)
    target = Path.join(root, relative_path) |> Path.expand()

    with {:ok, _lexical} <- validate_target_without_symlink_check(root, target) do
      PublicationTarget.remove_path(root, Path.relative_to(target, root), {SystemFileSystem, []})
    end
  end

  # Listing a project directory follows its symlinks only while they stay
  # inside the project root, the same rule staging applies to file reads.
  @spec safe_project_path_allow_root(t(), String.t()) ::
          {:ok, String.t()}
          | {:error, :path_traversal | read_error()}
  defp safe_project_path_allow_root(%__MODULE__{} = overlay, relative_path) do
    root = Path.expand(overlay.project_root)
    target = Path.join(root, relative_path) |> Path.expand()

    case validate_path_allow_root(root, target) do
      {:ok, ^root} -> {:ok, root}
      {:ok, _target} -> resolve_project_read(root, Path.relative_to(target, root))
      {:error, _reason} = error -> error
    end
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
    reduce_stats(entries, stats, &materialize_entry(overlay, source_dir, target_dir, &1, &2))
  end

  @spec materialize_entry(t(), String.t(), String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp materialize_entry(overlay, source_dir, target_dir, entry, stats) do
    source_path = Path.join(source_dir, entry)
    target_path = Path.join(target_dir, entry)

    case entry_disposition(entry, source_dir) do
      :link_dependencies -> link_dependencies(overlay, source_path, target_path, stats)
      :skip -> {:ok, increment_skipped(stats)}
      :copy -> materialize_path(overlay, source_path, target_path, stats)
    end
  end

  @spec entry_disposition(String.t(), String.t()) :: :link_dependencies | :skip | :copy
  defp entry_disposition("node_modules", _source_dir), do: :link_dependencies

  defp entry_disposition("target", source_dir) do
    if File.regular?(Path.join(source_dir, "Cargo.toml")), do: :skip, else: :copy
  end

  defp entry_disposition(entry, _source_dir) do
    if MapSet.member?(@skip_dirs, entry), do: :skip, else: :copy
  end

  # Builds an overlay-owned node_modules. A node_modules that is not a real
  # directory in the project is skipped.
  @spec link_dependencies(t(), String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp link_dependencies(overlay, source_path, target_path, stats) do
    case File.lstat(source_path) do
      {:ok, %{type: :directory}} ->
        place_dependencies(overlay, source_path, target_path, increment_skipped(stats))

      {:ok, _other} ->
        {:ok, increment_skipped(stats)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A node_modules the overlay does not have yet is cloned whole, with one
  # cloner call. When cloning fails, it becomes a link farm instead: package
  # entries link to the project's installed packages, while every directory a
  # package manager or tool adds entries to stays a real overlay directory.
  # An existing tree is kept, and only entries it is missing are added.
  @spec place_dependencies(t(), String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp place_dependencies(overlay, source_path, target_path, stats) do
    case File.lstat(target_path) do
      {:error, :enoent} ->
        clone_or_farm(overlay, :node_modules, source_path, target_path, stats)

      _existing ->
        build_link_farm(overlay, :node_modules, :clone, source_path, target_path, stats)
    end
  end

  @typep link_farm_kind :: :node_modules | :entries | :pnpm_store

  # How a missing entry is added: `:clone` tries the cloner first, `:link`
  # goes straight to links, after cloning the enclosing tree already failed.
  @typep placement :: :clone | :link

  @spec build_link_farm(
          t(),
          link_farm_kind(),
          placement(),
          String.t(),
          String.t(),
          materialization_stats()
        ) :: {:ok, materialization_stats()} | {:error, term()}
  defp build_link_farm(overlay, kind, placement, source_dir, target_dir, stats) do
    with :ok <- reject_materialization_symlink(overlay, target_dir),
         :ok <- File.mkdir_p(target_dir),
         {:ok, entries} <- File.ls(source_dir) do
      reduce_stats(
        entries,
        stats,
        &link_farm_entry(overlay, {kind, placement}, source_dir, target_dir, &1, &2)
      )
    end
  end

  @spec clone_or_farm(t(), link_farm_kind(), String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp clone_or_farm(overlay, kind, source_path, target_path, stats) do
    case clone_entry(overlay, source_path, target_path) do
      :ok ->
        {:ok, %{stats | cloned_entries: stats.cloned_entries + 1}}

      {:fallback, reason} ->
        stats = record_clone_fallback(stats, reason)
        build_link_farm(overlay, kind, :link, source_path, target_path, stats)

      {:error, _reason} = error ->
        error
    end
  end

  @spec clone_or_link(t(), String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp clone_or_link(overlay, source_path, target_path, stats) do
    case clone_entry(overlay, source_path, target_path) do
      :ok ->
        {:ok, %{stats | cloned_entries: stats.cloned_entries + 1}}

      {:fallback, reason} ->
        link_entry(source_path, target_path, record_clone_fallback(stats, reason))

      {:error, _reason} = error ->
        error
    end
  end

  # Clones a project entry to an overlay path that does not exist yet. Every
  # overlay ancestor is checked first, so a clone never lands outside the
  # overlay. A failed clone's partial output is removed; removal deletes links
  # inside it, never their targets.
  @spec clone_entry(t(), String.t(), String.t()) ::
          :ok | {:fallback, term()} | {:error, term()}
  defp clone_entry(overlay, source_path, target_path) do
    with :ok <- reject_materialization_symlink(overlay, target_path),
         :ok <- File.mkdir_p(Path.dirname(target_path)) do
      case overlay.cloner.clone(source_path, target_path) do
        :ok -> :ok
        {:error, reason} -> discard_partial_clone(target_path, reason)
      end
    end
  end

  @spec discard_partial_clone(String.t(), term()) :: {:fallback, term()} | {:error, term()}
  defp discard_partial_clone(target_path, reason) do
    case File.rm_rf(target_path) do
      {:ok, _removed} -> {:fallback, reason}
      {:error, cleanup, _path} -> {:error, {:clone_cleanup_failed, reason, cleanup}}
    end
  end

  @spec record_clone_fallback(materialization_stats(), term()) :: materialization_stats()
  defp record_clone_fallback(stats, reason) do
    %{
      stats
      | clone_fallbacks: stats.clone_fallbacks + 1,
        clone_fallback_reason: stats.clone_fallback_reason || reason
    }
  end

  # Said once per materialization, however many trees fell back.
  @spec report_clone_fallback({:ok, materialization_stats()} | {:error, term()}) :: :ok
  defp report_clone_fallback({:ok, %{clone_fallbacks: count, clone_fallback_reason: reason}})
       when count > 0 do
    Minga.Log.warning(
      :agent,
      "Agent overlay: installed JavaScript packages could not be cloned (#{inspect(reason)}), so they are linked to the project. A command that writes inside an installed package changes the project's copy."
    )
  end

  defp report_clone_fallback(_result), do: :ok

  @spec link_farm_entry(
          t(),
          {link_farm_kind(), placement()},
          String.t(),
          String.t(),
          String.t(),
          materialization_stats()
        ) :: {:ok, materialization_stats()} | {:error, term()}
  defp link_farm_entry(overlay, {kind, placement}, source_dir, target_dir, entry, stats) do
    case link_farm_disposition(kind, entry) do
      :skip ->
        {:ok, stats}

      disposition ->
        source_path = Path.join(source_dir, entry)
        target_path = Path.join(target_dir, entry)

        with {:ok, %{type: source_type}} <- File.lstat(source_path) do
          place_link_farm_entry(
            overlay,
            {disposition, placement},
            source_type,
            source_path,
            target_path,
            stats
          )
        end
    end
  end

  # An existing overlay entry wins whatever the source entry is now, so a
  # source that changed type between materializations never fails a command.
  # One exception: an owned directory must be a real overlay directory, so a
  # link that materialization made to the project's entry is replaced once that
  # entry is a real directory. A link a command made is kept. A kept symlink is
  # never written through, because nothing is copied or created at its path.
  # A missing entry is cloned when the placement allows, and otherwise linked;
  # small regular files such as shims are copied.
  @spec place_link_farm_entry(
          t(),
          {:link | {:own, link_farm_kind()}, placement()},
          :device | :directory | :regular | :symlink | :other,
          String.t(),
          String.t(),
          materialization_stats()
        ) :: {:ok, materialization_stats()} | {:error, term()}
  defp place_link_farm_entry(overlay, entry, source_type, source_path, target_path, stats) do
    case {entry, source_type, File.lstat(target_path)} do
      {{{:own, child_kind}, placement}, :directory, {:ok, %{type: :directory}}} ->
        build_link_farm(overlay, child_kind, placement, source_path, target_path, stats)

      {{{:own, child_kind}, :clone}, :directory, {:error, :enoent}} ->
        clone_or_farm(overlay, child_kind, source_path, target_path, stats)

      {{{:own, child_kind}, :link}, :directory, {:error, :enoent}} ->
        build_link_farm(overlay, child_kind, :link, source_path, target_path, stats)

      {{{:own, child_kind}, placement}, :directory, {:ok, %{type: :symlink}}} ->
        own_linked_directory(overlay, {child_kind, placement}, source_path, target_path, stats)

      {_entry, _source_type, {:ok, _existing}} ->
        {:ok, stats}

      {_entry, :regular, {:error, :enoent}} ->
        materialize_regular_file(overlay, source_path, target_path, stats)

      {{_disposition, :clone}, _source_type, {:error, :enoent}} ->
        clone_or_link(overlay, source_path, target_path, stats)

      {{_disposition, :link}, _source_type, {:error, :enoent}} ->
        link_entry(source_path, target_path, stats)

      {_entry, _source_type, {:error, reason}} ->
        {:error, reason}
    end
  end

  @spec own_linked_directory(
          t(),
          {link_farm_kind(), placement()},
          String.t(),
          String.t(),
          materialization_stats()
        ) :: {:ok, materialization_stats()} | {:error, term()}
  defp own_linked_directory(overlay, {kind, placement}, source_path, target_path, stats) do
    if File.read_link(target_path) == {:ok, Path.expand(source_path)} do
      with :ok <- File.rm(target_path) do
        own_directory(overlay, {kind, placement}, source_path, target_path, stats)
      end
    else
      {:ok, stats}
    end
  end

  @spec own_directory(
          t(),
          {link_farm_kind(), placement()},
          String.t(),
          String.t(),
          materialization_stats()
        ) :: {:ok, materialization_stats()} | {:error, term()}
  defp own_directory(overlay, {kind, :clone}, source_path, target_path, stats),
    do: clone_or_farm(overlay, kind, source_path, target_path, stats)

  defp own_directory(overlay, {kind, :link}, source_path, target_path, stats),
    do: build_link_farm(overlay, kind, :link, source_path, target_path, stats)

  # `.bin` (package executables), `@scope` directories, `.pnpm` (pnpm's package
  # tree), and its hoisted `.pnpm/node_modules` are owned by the overlay; their
  # existing entries are linked one by one. Other dot entries in node_modules
  # are tool caches and package-manager metadata such as `.vite`, `.cache`,
  # `.package-lock.json`, and pnpm's `.modules.yaml`. They are not carried over,
  # so their writes land in the overlay. Without `.modules.yaml`, pnpm treats
  # the overlay's node_modules as not installed by pnpm and reinstalls into the
  # overlay instead of incrementally relinking packages inside linked
  # directories that belong to the project.
  @spec link_farm_disposition(link_farm_kind(), String.t()) ::
          :skip | :link | {:own, link_farm_kind()}
  defp link_farm_disposition(:node_modules, "@" <> _), do: {:own, :entries}
  defp link_farm_disposition(:node_modules, ".bin"), do: {:own, :entries}
  defp link_farm_disposition(:node_modules, ".pnpm"), do: {:own, :pnpm_store}
  defp link_farm_disposition(:node_modules, "." <> _), do: :skip
  defp link_farm_disposition(:pnpm_store, "node_modules"), do: {:own, :node_modules}
  defp link_farm_disposition(_kind, _entry), do: :link

  # An existing overlay entry wins, so repeated materialization keeps links,
  # replacements made by earlier commands, and overlay-installed packages.
  @spec link_entry(String.t(), String.t(), materialization_stats()) ::
          {:ok, materialization_stats()} | {:error, term()}
  defp link_entry(source_path, target_path, stats) do
    case File.lstat(target_path) do
      {:ok, _existing} ->
        {:ok, stats}

      {:error, :enoent} ->
        with :ok <- File.ln_s(Path.expand(source_path), target_path) do
          {:ok, %{stats | linked_entries: stats.linked_entries + 1}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec reduce_stats(
          [String.t()],
          materialization_stats(),
          (String.t(), materialization_stats() ->
             {:ok, materialization_stats()} | {:error, term()})
        ) :: {:ok, materialization_stats()} | {:error, term()}
  defp reduce_stats(entries, stats, fun) do
    Enum.reduce_while(entries, {:ok, stats}, fn entry, {:ok, acc} ->
      case fun.(entry, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
    if regular_target_or_tombstoned?(target_path) do
      {:ok, stats}
    else
      with :ok <- reject_materialization_symlink(overlay, target_path) do
        copy_regular_file(source_path, target_path, stats)
      end
    end
  end

  # A regular file or tombstone at the target means a previous materialization
  # already placed this entry. Symlinks are not treated as existing so the
  # symlink traversal check still catches malicious overlay links.
  @spec regular_target_or_tombstoned?(String.t()) :: boolean()
  defp regular_target_or_tombstoned?(target_path) do
    match?({:ok, %{type: :regular}}, File.lstat(target_path)) or
      match?({:ok, _}, File.lstat(tombstone_path(target_path)))
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
