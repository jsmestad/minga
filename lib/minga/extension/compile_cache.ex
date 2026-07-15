defmodule Minga.Extension.CompileCache do
  @moduledoc """
  Isolated compiler and authoritative BEAM cache for path and Git extensions.

  Source is compiled only in a standalone disposable BEAM OS process. Its complete
  staged artifact inventory is bounded and validated, atomically admitted to one
  source for the current VM generation, and only then loaded into the host.
  Cache hits pass through the identical inventory and ownership checks. A failed
  candidate never prunes the previous good cache entry.

  The trust boundary admits at most 128 artifacts, 64 MiB total BEAM data, and
  16,384 total BEAM atom-table entries by default. Individual limits are lower,
  atom names are capped at the VM's 255-byte limit, and 65,536 host atom slots
  remain reserved before `:beam_lib` is allowed to create metadata atoms.
  """

  alias Minga.Extension.Artifact
  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ArtifactInventory
  alias Minga.Extension.IsolatedCompiler
  alias Minga.Extension.SourceSnapshot

  @type result ::
          {:ok, %{modules: [module()], diagnostics: [map()], source: :cache | :compiled}}
          | {:error, String.t() | term()}

  @typep load_result :: {:ok, [module()], [module()]} | {:error, term(), [module()]}

  @doc """
  Loads the source's admitted artifact set, compiling in a standalone process on a
  cache miss.

  `:source` is required and must be the stable extension contribution source.
  Disabling persistence with `enabled: false` still uses isolated compilation,
  validation, admission, and loading; it only skips the on-disk cache.
  """
  @spec load_or_compile(String.t(), [String.t()], keyword()) :: result()
  def load_or_compile(root, files, opts \\ [])

  def load_or_compile(_root, [], _opts), do: {:error, "no source files to compile"}

  def load_or_compile(root, files, opts) when is_binary(root) and is_list(files) do
    with {:ok, source} <- fetch_source(opts),
         {:ok, snapshot} <- SourceSnapshot.create(root, files, opts) do
      try do
        key = content_key(snapshot)
        attempt_opts = Keyword.put(opts, :source_fingerprint, snapshot.fingerprint)

        if Keyword.get(opts, :enabled, enabled?()) do
          load_cached_or_compile(root, snapshot.files, key, source, attempt_opts)
        else
          compile_without_cache(snapshot.files, source, attempt_opts)
        end
      after
        SourceSnapshot.cleanup(snapshot)
      end
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @doc "Returns the bounded immutable source fingerprint used for generation comparisons."
  @spec source_fingerprint(String.t(), [String.t()], keyword()) ::
          {:ok, binary()} | {:error, term()}
  def source_fingerprint(root, files, opts \\ []) do
    case SourceSnapshot.create(root, files, opts) do
      {:ok, snapshot} ->
        fingerprint = snapshot.fingerprint
        SourceSnapshot.cleanup(snapshot)
        {:ok, fingerprint}

      {:error, _reason} = error ->
        error
    end
  end

  @spec fetch_source(keyword()) ::
          {:ok, Minga.Extension.ContributionCleanup.contribution_source()}
          | {:error, String.t()}
  defp fetch_source(opts) do
    case Keyword.fetch(opts, :source) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, "extension artifact source is required"}
    end
  end

  @spec load_cached_or_compile(String.t(), [String.t()], String.t(), term(), keyword()) ::
          result()
  defp load_cached_or_compile(root, files, key, source, opts) do
    cache_root = Keyword.get(opts, :cache_dir, default_cache_dir())
    ext_dir = Path.join(cache_root, ext_id(root))
    dir = Path.join(ext_dir, key)

    case ensure_cache_extension_dir(ext_dir) do
      :ok -> load_validated_cache(files, ext_dir, dir, source, opts)
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @spec load_validated_cache([String.t()], String.t(), String.t(), term(), keyword()) :: result()
  defp load_validated_cache(files, ext_dir, dir, source, opts) do
    case ArtifactInventory.validate_cache(dir, inventory_opts(opts)) do
      {:ok, inventory} ->
        admit_and_load(inventory, source, [], :cache, opts)

      :miss ->
        compile_and_cache(files, ext_dir, dir, source, opts)

      {:error, {:host_atom_capacity_exceeded, _current, _required, _reserve, _limit} = reason} ->
        {:error, format_error(reason)}

      {:error, _corrupt_cache} ->
        compile_and_cache(files, ext_dir, dir, source, opts)
    end
  end

  @spec ensure_cache_extension_dir(String.t()) :: :ok | {:error, term()}
  defp ensure_cache_extension_dir(ext_dir) do
    case File.lstat(ext_dir) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsafe_extension_cache_directory, ext_dir, type}}

      {:error, :enoent} ->
        File.mkdir_p(ext_dir)

      {:error, reason} ->
        {:error, {:extension_cache_directory_failed, ext_dir, reason}}
    end
  end

  @spec compile_and_cache([String.t()], String.t(), String.t(), term(), keyword()) :: result()
  defp compile_and_cache(files, ext_dir, dir, source, opts) do
    staging = staging_dir(ext_dir)

    try do
      with :ok <- mkdir_clean(staging),
           {:ok, report} <- compile_isolated(files, staging, opts),
           {:ok, inventory} <-
             ArtifactInventory.validate_staging(
               staging,
               report.expected_modules,
               inventory_opts(opts)
             ),
           :ok <- ArtifactInventory.write_manifest(inventory.snapshot_dir, inventory, opts),
           {:ok, claim} <- claim_compiled_inventory(source, inventory, opts) do
        promote_and_load(
          inventory,
          claim,
          report.diagnostics,
          ext_dir,
          inventory.snapshot_dir,
          dir,
          opts
        )
      else
        {:error, reason} -> {:error, format_error(reason)}
      end
    after
      File.rm_rf(staging)
    end
  rescue
    error -> {:error, "extension artifact preparation failed: #{Exception.message(error)}"}
  catch
    kind, reason ->
      {:error, "extension artifact preparation failed: #{inspect(kind)} #{inspect(reason)}"}
  end

  @spec compile_without_cache([String.t()], term(), keyword()) :: result()
  defp compile_without_cache(files, source, opts) do
    staging = Path.join(System.tmp_dir!(), "minga-extension-stage-#{unique_suffix()}")

    try do
      with :ok <- mkdir_clean(staging),
           {:ok, report} <- compile_isolated(files, staging, opts),
           {:ok, inventory} <-
             ArtifactInventory.validate_staging(
               staging,
               report.expected_modules,
               inventory_opts(opts)
             ),
           {:ok, claim} <- claim_compiled_inventory(source, inventory, opts) do
        finalize_ephemeral_load(inventory, claim, report.diagnostics, opts)
      else
        {:error, reason} -> {:error, format_error(reason)}
      end
    after
      File.rm_rf(staging)
    end
  rescue
    error -> {:error, "extension artifact preparation failed: #{Exception.message(error)}"}
  catch
    kind, reason ->
      {:error, "extension artifact preparation failed: #{inspect(kind)} #{inspect(reason)}"}
  end

  @spec compile_isolated([String.t()], String.t(), keyword()) ::
          {:ok, IsolatedCompiler.report()} | {:error, term()}
  defp compile_isolated(files, staging, opts) do
    case Keyword.get(opts, :compiler, IsolatedCompiler) do
      compiler when is_function(compiler, 3) -> compiler.(files, staging, opts)
      compiler when is_atom(compiler) -> compiler.compile(files, staging, opts)
    end
  end

  @spec claim_compiled_inventory(term(), ArtifactInventory.t(), keyword()) ::
          {:ok, ArtifactAdmission.claim()} | {:error, term()}
  defp claim_compiled_inventory(source, inventory, opts) do
    case claim_inventory(source, inventory, opts) do
      {:ok, claim} ->
        {:ok, claim}

      {:error, _reason} = error ->
        ArtifactInventory.cleanup(inventory)
        error
    end
  end

  @spec claim_inventory(term(), ArtifactInventory.t(), keyword()) ::
          {:ok, ArtifactAdmission.claim()} | {:error, term()}
  defp claim_inventory(source, inventory, opts) do
    admission = Keyword.get(opts, :artifact_admission, ArtifactAdmission)

    ArtifactAdmission.claim_inventory(source, inventory,
      server: admission,
      trusted_application: Keyword.get(opts, :trusted_application),
      source_fingerprint: Keyword.fetch!(opts, :source_fingerprint)
    )
  end

  @spec promote_and_load(
          ArtifactInventory.t(),
          ArtifactAdmission.claim(),
          [map()],
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: result()
  defp promote_and_load(inventory, claim, diagnostics, ext_dir, staging, dir, opts) do
    case promote_staging(staging, dir) do
      {:ok, backup} ->
        promoted = ArtifactInventory.rebase(inventory, dir)
        finalize_promoted_load(promoted, claim, diagnostics, ext_dir, dir, backup, opts)

      {:error, reason} ->
        release_claim(claim, opts)
        ArtifactInventory.cleanup(inventory)
        {:error, format_error(reason)}
    end
  end

  @spec finalize_promoted_load(
          ArtifactInventory.t(),
          ArtifactAdmission.claim(),
          [map()],
          String.t(),
          String.t(),
          String.t() | nil,
          keyword()
        ) :: result()
  defp finalize_promoted_load(inventory, claim, diagnostics, ext_dir, dir, backup, opts) do
    case load_inventory(inventory, claim, opts) do
      {:ok, modules, loaded} ->
        case commit_claim(claim, opts) do
          :ok ->
            remove_backup(backup)
            prune_stale_keys(ext_dir, dir)
            {:ok, %{modules: modules, diagnostics: diagnostics, source: :compiled}}

          {:error, reason} ->
            rollback_loaded(loaded)
            rollback_promotion(dir, backup)
            release_claim(claim, opts)
            {:error, format_error({:artifact_admission_commit_failed, reason})}
        end

      {:error, reason, loaded} ->
        rollback_loaded(loaded)
        rollback_promotion(dir, backup)
        release_claim(claim, opts)
        {:error, format_error(reason)}
    end
  end

  @spec finalize_ephemeral_load(
          ArtifactInventory.t(),
          ArtifactAdmission.claim(),
          [map()],
          keyword()
        ) :: result()
  defp finalize_ephemeral_load(inventory, claim, diagnostics, opts) do
    case load_inventory(inventory, claim, opts) do
      {:ok, modules, loaded} ->
        case commit_claim(claim, opts) do
          :ok ->
            {:ok, %{modules: modules, diagnostics: diagnostics, source: :compiled}}

          {:error, reason} ->
            rollback_loaded(loaded)
            release_claim(claim, opts)
            {:error, format_error({:artifact_admission_commit_failed, reason})}
        end

      {:error, reason, loaded} ->
        rollback_loaded(loaded)
        release_claim(claim, opts)
        {:error, format_error(reason)}
    end
  after
    ArtifactInventory.cleanup(inventory)
  end

  @spec admit_and_load(ArtifactInventory.t(), term(), [map()], :cache, keyword()) :: result()
  defp admit_and_load(inventory, source, diagnostics, origin, opts) do
    case claim_inventory(source, inventory, opts) do
      {:ok, claim} -> finalize_admitted_load(inventory, claim, diagnostics, origin, opts)
      {:error, reason} -> {:error, format_error(reason)}
    end
  after
    ArtifactInventory.cleanup(inventory)
  end

  @spec finalize_admitted_load(
          ArtifactInventory.t(),
          ArtifactAdmission.claim(),
          [map()],
          :cache,
          keyword()
        ) :: result()
  defp finalize_admitted_load(inventory, claim, diagnostics, origin, opts) do
    case load_inventory(inventory, claim, opts) do
      {:ok, modules, loaded} ->
        case commit_claim(claim, opts) do
          :ok ->
            {:ok, %{modules: modules, diagnostics: diagnostics, source: origin}}

          {:error, reason} ->
            rollback_loaded(loaded)
            release_claim(claim, opts)
            {:error, format_error({:artifact_admission_commit_failed, reason})}
        end

      {:error, reason, loaded} ->
        rollback_loaded(loaded)
        release_claim(claim, opts)
        {:error, format_error(reason)}
    end
  end

  @spec load_inventory(ArtifactInventory.t(), ArtifactAdmission.claim(), keyword()) ::
          load_result()
  defp load_inventory(%ArtifactInventory{} = inventory, claim, opts) do
    admission = Keyword.get(opts, :artifact_admission, ArtifactAdmission)

    case ArtifactAdmission.mark_loading(claim, server: admission) do
      :ok -> do_load_inventory(inventory, claim, opts)
      {:error, reason} -> {:error, {:artifact_admission_load_marker_failed, reason}, []}
    end
  end

  @spec do_load_inventory(ArtifactInventory.t(), ArtifactAdmission.claim(), keyword()) ::
          load_result()
  defp do_load_inventory(%ArtifactInventory{} = inventory, claim, opts) do
    artifacts_by_module = Map.new(inventory.artifacts, &{&1.module, &1})
    loader = Keyword.get(opts, :artifact_loader, &:code.load_binary/3)

    claim.load_modules
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, loaded} ->
      artifact = Map.fetch!(artifacts_by_module, module)

      case load_artifact(artifact, claim.acquired?, loader) do
        {:ok, :already_loaded} -> {:cont, {:ok, loaded}}
        {:ok, :loaded} -> {:cont, {:ok, [module | loaded]}}
        {:error, reason} -> {:halt, {:error, reason, loaded}}
      end
    end)
    |> case do
      {:ok, newly_loaded} -> {:ok, claim.modules, newly_loaded}
      {:error, reason, loaded} -> {:error, reason, loaded}
    end
  end

  @spec load_artifact(Artifact.t(), boolean(), function()) ::
          {:ok, :loaded | :already_loaded} | {:error, term()}
  defp load_artifact(%Artifact{} = artifact, acquired?, loader) do
    case :code.is_loaded(artifact.module) do
      false ->
        load_unloaded_artifact(artifact, loader)

      {_file, _path} when acquired? ->
        {:error, {:artifact_became_loaded_after_admission, artifact.module}}

      {_file, _path} ->
        {:ok, :already_loaded}
    end
  end

  @spec load_unloaded_artifact(Artifact.t(), function()) ::
          {:ok, :loaded} | {:error, term()}
  defp load_unloaded_artifact(%Artifact{} = artifact, loader) do
    with {:module, loaded} <-
           loader.(artifact.module, String.to_charlist(artifact.path), artifact.bytecode),
         true <- loaded == artifact.module do
      {:ok, :loaded}
    else
      error -> {:error, {:artifact_load_failed, artifact.module, error}}
    end
  rescue
    error -> {:error, {:artifact_load_failed, artifact.module, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:artifact_load_failed, artifact.module, {kind, reason}}}
  end

  @spec rollback_loaded([module()]) :: :ok
  defp rollback_loaded(modules) do
    Enum.each(modules, fn module ->
      :code.delete(module)
      :code.purge(module)
      :code.delete(module)
    end)

    :ok
  end

  @spec commit_claim(ArtifactAdmission.claim(), keyword()) :: :ok | {:error, term()}
  defp commit_claim(claim, opts) do
    ArtifactAdmission.commit_attempt(claim,
      server: Keyword.get(opts, :artifact_admission, ArtifactAdmission)
    )
  end

  @spec release_claim(ArtifactAdmission.claim(), keyword()) :: :ok | {:error, term()}
  defp release_claim(claim, opts) do
    ArtifactAdmission.abort_attempt(claim,
      server: Keyword.get(opts, :artifact_admission, ArtifactAdmission)
    )
  end

  @spec mkdir_clean(String.t()) :: :ok | {:error, term()}
  defp mkdir_clean(dir) do
    File.rm_rf(dir)
    File.mkdir_p(dir)
  end

  @spec promote_staging(String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  defp promote_staging(staging, dir) do
    backup = if path_exists?(dir), do: dir <> ".replaced-#{unique_suffix()}", else: nil

    with :ok <- File.mkdir_p(Path.dirname(dir)),
         :ok <- maybe_backup(dir, backup),
         :ok <- File.rename(staging, dir) do
      {:ok, backup}
    else
      {:error, reason} = error ->
        restore_backup(dir, backup)
        {:error, {:cache_promotion_failed, reason, error}}
    end
  end

  @spec maybe_backup(String.t(), String.t() | nil) :: :ok | {:error, File.posix()}
  defp maybe_backup(_dir, nil), do: :ok
  defp maybe_backup(dir, backup), do: File.rename(dir, backup)

  @spec rollback_promotion(String.t(), String.t() | nil) :: :ok
  defp rollback_promotion(dir, backup) do
    File.rm_rf(dir)
    restore_backup(dir, backup)
  end

  @spec restore_backup(String.t(), String.t() | nil) :: :ok
  defp restore_backup(_dir, nil), do: :ok

  defp restore_backup(dir, backup) do
    if path_exists?(backup), do: File.rename(backup, dir)
    :ok
  end

  @spec path_exists?(String.t()) :: boolean()
  defp path_exists?(path) do
    match?({:ok, %File.Stat{}}, File.lstat(path))
  end

  @spec remove_backup(String.t() | nil) :: :ok
  defp remove_backup(nil), do: :ok
  defp remove_backup(backup), do: File.rm_rf(backup) |> then(fn _ -> :ok end)

  @spec prune_stale_keys(String.t(), String.t()) :: :ok
  defp prune_stale_keys(ext_dir, keep_dir) do
    keep = Path.basename(keep_dir)

    case File.ls(ext_dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 == keep or String.starts_with?(&1, ".staging-")))
        |> Enum.each(&File.rm_rf(Path.join(ext_dir, &1)))

        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @spec staging_dir(String.t()) :: String.t()
  defp staging_dir(ext_dir), do: Path.join(ext_dir, ".staging-#{unique_suffix()}")

  @spec unique_suffix() :: String.t()
  defp unique_suffix do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @spec inventory_opts(keyword()) :: keyword()
  defp inventory_opts(opts) do
    Keyword.take(opts, [
      :max_artifacts,
      :max_artifact_bytes,
      :max_total_bytes,
      :max_atoms_per_artifact,
      :max_total_atoms,
      :max_atom_name_bytes,
      :host_atom_reserve,
      :max_manifest_bytes,
      :max_decompressed_bytes,
      :max_total_decompressed_bytes
    ])
  end

  @spec format_error(term()) :: String.t()
  defp format_error(message) when is_binary(message), do: message
  defp format_error(reason), do: "extension artifact rejected: #{inspect(reason)}"

  @spec ext_id(String.t()) :: String.t()
  defp ext_id(root) do
    :sha256
    |> :crypto.hash(Path.expand(root))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  @spec content_key(SourceSnapshot.t()) :: String.t()
  defp content_key(snapshot), do: Base.url_encode64(snapshot.fingerprint, padding: false)

  @spec enabled?() :: boolean()
  defp enabled?, do: Application.get_env(:minga, :extension_compile_cache, true)

  @spec default_cache_dir() :: String.t()
  defp default_cache_dir do
    Application.get_env(
      :minga,
      :extension_compile_cache_dir,
      Path.join(Path.expand("~/.local/share/minga"), "extension_cache")
    )
  end
end
