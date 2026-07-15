defmodule Minga.Extension.Instance.Source do
  @moduledoc """
  Sole source preparation path for every extension lifecycle policy.

  Committed current-generation artifacts are always reused first. Path and
  resolved Git declarations use `CompileCache`; deterministic JSON bundles use
  `JsonLoader`; module, bundled, and Hex declarations adopt trusted resident
  inventories without replacing code in this VM.
  """

  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.BundledApplications
  alias Minga.Extension.CompileCache
  alias Minga.Extension.Entry
  alias Minga.Extension.Instance.Artifact
  alias Minga.Extension.Manifest

  @doc "Prepares the exact admitted artifact for one declaration."
  @spec prepare(atom(), Entry.t(), keyword()) :: {:ok, Artifact.t()} | {:error, term()}
  def prepare(name, %Entry{} = declaration, opts) when is_atom(name) and is_list(opts) do
    source = {:extension, name}
    admission = admission(opts)

    with {:ok, module, owned_modules} <- resolve(name, declaration, source, admission, opts),
         :ok <- validate_behaviour(module, name),
         {:ok, manifest} <- manifest(module, declaration.source_type) do
      Artifact.build(name, module, manifest, owned_modules, declaration.config)
    end
  end

  @doc "Discovers a declaration's load policy through the same admitted artifact path."
  @spec discover_load_policy(atom(), Entry.t(), keyword()) ::
          {:ok, Minga.Extension.load_policy(), Artifact.t()} | {:error, term()}
  def discover_load_policy(name, declaration, opts) do
    with {:ok, artifact} <- prepare(name, declaration, opts) do
      policy =
        if function_exported?(artifact.module, :__load_policy__, 0) do
          artifact.module.__load_policy__()
        else
          :eager
        end

      {:ok, policy, artifact}
    end
  end

  @doc "Reports a staged path/Git source change without loading new code."
  @spec pending_restart?(atom(), Entry.t(), keyword()) :: boolean()
  def pending_restart?(name, %{source_type: source_type, path: path}, opts)
      when source_type in [:path, :git] and is_binary(path) do
    expanded = Path.expand(path)
    files = source_files(expanded)
    report_staged_source_change(name, expanded, files, {:extension, name}, opts)
  end

  def pending_restart?(_name, _declaration, _opts), do: false

  @spec resolve(atom(), Entry.t(), term(), GenServer.server(), keyword()) ::
          {:ok, module(), [module()]} | {:error, term()}
  defp resolve(name, declaration, source, admission, opts) do
    case ArtifactAdmission.source_modules(source, server: admission) do
      {:ok, [_module | _rest] = modules} -> reuse_committed(name, declaration, modules, opts)
      {:ok, []} -> {:error, {:source_artifact_unavailable, source}}
      :error -> admit_initial(name, declaration, source, admission, opts)
    end
  end

  @spec reuse_committed(atom(), Entry.t(), [module()], keyword()) ::
          {:ok, module(), [module()]} | {:error, term()}
  defp reuse_committed(name, declaration, modules, opts) do
    _changed? = pending_restart?(name, declaration, opts)

    with :ok <- ensure_modules_loaded(modules),
         {:ok, module} <- find_extension_module(modules) do
      {:ok, module, modules}
    end
  end

  @spec admit_initial(atom(), Entry.t(), term(), GenServer.server(), keyword()) ::
          {:ok, module(), [module()]} | {:error, term()}
  defp admit_initial(name, %{source_type: :module, module: module}, source, admission, opts) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         {:ok, application} <- runtime_application(module, opts),
         {:ok, modules} <- declared_runtime_modules(module, application, opts),
         :ok <- ensure_modules_loaded(modules),
         :ok <- admit_resident(source, modules, application, admission) do
      {:ok, module, modules}
    else
      {:error, _reason} = error -> error
      other -> {:error, {:module_load_failed, name, other}}
    end
  end

  defp admit_initial(_name, %{source_type: :hex, hex: %{app: app}}, source, admission, _opts) do
    with :ok <- ensure_hex_application_started(app),
         {:ok, modules} <- application_modules(app),
         :ok <- ensure_modules_loaded(modules),
         {:ok, module} <- find_extension_module(modules),
         :ok <- admit_resident(source, modules, app, admission) do
      {:ok, module, modules}
    end
  end

  defp admit_initial(_name, %{source_type: :git, path: nil}, _source, _admission, _opts),
    do: {:error, :clone_failed}

  defp admit_initial(name, %{source_type: source_type, path: path}, source, admission, opts)
       when source_type in [:path, :git] and is_binary(path) do
    expanded = Path.expand(path)

    if File.dir?(expanded) do
      compile_path(name, expanded, source, admission, opts)
    else
      {:error, "extension path does not exist: #{expanded}"}
    end
  end

  @spec compile_path(atom(), String.t(), term(), GenServer.server(), keyword()) ::
          {:ok, module(), [module()]} | {:error, term()}
  defp compile_path(name, expanded, source, admission, opts) do
    case source_files(expanded) do
      [] -> load_json(name, expanded, source, admission, opts)
      files -> load_compiled(name, expanded, files, source, admission, opts)
    end
  end

  @spec load_json(atom(), String.t(), term(), GenServer.server(), keyword()) ::
          {:ok, module(), [module()]} | {:error, term()}
  defp load_json(name, expanded, source, admission, _opts) do
    with {:ok, module} <-
           Minga.Extension.JsonLoader.load(expanded, name, artifact_admission: admission),
         {:ok, modules} <- ArtifactAdmission.source_modules(source, server: admission) do
      {:ok, module, modules}
    end
  end

  @spec load_compiled(atom(), String.t(), [String.t()], term(), GenServer.server(), keyword()) ::
          {:ok, module(), [module()]} | {:error, term()}
  defp load_compiled(name, expanded, files, source, admission, _opts) do
    compile_opts = [
      source: source,
      artifact_admission: admission,
      trusted_application: BundledApplications.trusted_application(name)
    ]

    with {:ok, %{modules: compiled, diagnostics: diagnostics}} <-
           CompileCache.load_or_compile(expanded, files, compile_opts),
         :ok <- log_diagnostics(diagnostics),
         {:ok, modules} <- committed_modules(source, admission, compiled),
         {:ok, module} <- find_extension_module(modules) do
      {:ok, module, modules}
    end
  end

  @spec committed_modules(term(), GenServer.server(), [module()]) ::
          {:ok, [module()]} | {:error, term()}
  defp committed_modules(source, admission, fallback) do
    case ArtifactAdmission.source_modules(source, server: admission) do
      {:ok, [_module | _rest] = modules} -> {:ok, modules}
      _ -> {:ok, fallback}
    end
  end

  @spec admit_resident(term(), [module()], atom(), GenServer.server()) :: :ok | {:error, term()}
  defp admit_resident(source, modules, application, admission) do
    fingerprint = resident_fingerprint(application, modules)

    with {:ok, claim} <-
           ArtifactAdmission.claim_source_modules(source, modules, fingerprint,
             server: admission,
             trusted_application: application,
             exclusive_adoption: true,
             source_fingerprint: fingerprint
           ),
         :ok <- verify_adoption(claim, modules, admission) do
      ArtifactAdmission.commit_attempt(claim, server: admission)
    end
  end

  @spec verify_adoption(ArtifactAdmission.claim(), [module()], GenServer.server()) ::
          :ok | {:error, term()}
  defp verify_adoption(claim, modules, admission) do
    if claim.load_modules == [] and claim.adopted_modules == Enum.sort(modules) do
      :ok
    else
      _ = ArtifactAdmission.abort_attempt(claim, server: admission)

      {:error,
       {:runtime_inventory_not_adopted, claim.source, claim.load_modules, claim.adopted_modules}}
    end
  end

  @spec runtime_application(module(), keyword()) :: {:ok, atom()} | {:error, term()}
  defp runtime_application(module, opts) do
    case Keyword.fetch(opts, :runtime_application) do
      {:ok, application} when is_atom(application) ->
        {:ok, application}

      {:ok, invalid} ->
        {:error, {:invalid_runtime_application, invalid}}

      :error ->
        case :application.get_application(module) do
          {:ok, application} -> {:ok, application}
          :undefined -> {:error, {:runtime_application_unavailable, module}}
        end
    end
  end

  @spec declared_runtime_modules(module(), atom(), keyword()) ::
          {:ok, [module()]} | {:error, term()}
  defp declared_runtime_modules(module, application, opts) when is_list(opts) do
    if Keyword.has_key?(opts, :runtime_application) do
      application_modules(application)
    else
      {:ok, runtime_owned_modules(module, opts)}
    end
  end

  @spec runtime_owned_modules(module(), keyword()) :: [module()]
  defp runtime_owned_modules(module, opts) do
    command_modules =
      for {_name, _description, command_opts} <- schema(module, :__command_schema__),
          is_list(command_opts),
          Keyword.keyword?(command_opts),
          {callback_module, callback_function} <- [Keyword.get(command_opts, :execute)],
          is_atom(callback_module) and is_atom(callback_function),
          do: callback_module

    modeline_modules =
      for {_name, _segment_opts, {callback_module, callback_function}} <-
            schema(module, :__modeline_segment_schema__),
          is_atom(callback_module) and is_atom(callback_function),
          do: callback_module

    event_modules =
      for {callback_module, _families, _handler_opts} <-
            schema(module, :__editor_event_handler_schema__),
          is_atom(callback_module),
          do: callback_module

    [
      module
      | command_modules ++
          modeline_modules ++ event_modules ++ Keyword.get(opts, :runtime_owned_modules, [])
    ]
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec schema(module(), atom()) :: [term()]
  defp schema(module, function),
    do: if(function_exported?(module, function, 0), do: apply(module, function, []), else: [])

  @spec application_modules(atom()) :: {:ok, [module()]} | {:error, term()}
  defp application_modules(application) do
    case :application.get_key(application, :modules) do
      {:ok, [_module | _rest] = modules} -> {:ok, Enum.sort(Enum.uniq(modules))}
      {:ok, []} -> {:error, {:runtime_application_has_no_modules, application}}
      :undefined -> {:error, {:invalid_runtime_application, application}}
    end
  end

  @spec ensure_hex_application_started(atom()) :: :ok | {:error, term()}
  defp ensure_hex_application_started(app) do
    case Application.ensure_all_started(app) do
      {:ok, _applications} -> :ok
      {:error, reason} -> {:error, {:hex_application_start_failed, app, reason}}
    end
  end

  @spec ensure_modules_loaded([module()]) :: :ok | {:error, term()}
  defp ensure_modules_loaded(modules) do
    Enum.reduce_while(modules, :ok, fn module, :ok ->
      case Code.ensure_loaded(module) do
        {:module, ^module} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:runtime_module_unavailable, module, reason}}}
      end
    end)
  end

  @spec find_extension_module([module()]) :: {:ok, module()} | {:error, String.t()}
  defp find_extension_module(modules) do
    case Enum.find(modules, &implements_extension?/1) do
      nil -> {:error, "no module implementing Minga.Extension behaviour found"}
      module -> {:ok, module}
    end
  end

  @spec implements_extension?(module()) :: boolean()
  defp implements_extension?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :name, 0) and
      function_exported?(module, :description, 0) and
      function_exported?(module, :version, 0) and
      function_exported?(module, :init, 1)
  end

  @spec validate_behaviour(module(), atom()) :: :ok | {:error, String.t()}
  defp validate_behaviour(module, name) do
    missing =
      Enum.reject([:name, :description, :version, :init], fn
        :init -> function_exported?(module, :init, 1)
        function -> function_exported?(module, function, 0)
      end)

    case missing do
      [] -> :ok
      functions -> {:error, "extension #{name} missing callbacks: #{inspect(functions)}"}
    end
  end

  @spec manifest(module(), Manifest.source_type()) :: {:ok, Manifest.t()} | {:error, term()}
  defp manifest(module, source_type) do
    {:ok, Manifest.from_module(module, source_type)}
  rescue
    error -> {:error, "manifest introspection failed: #{Exception.message(error)}"}
  catch
    kind, reason -> {:error, "manifest introspection failed: #{inspect(kind)} #{inspect(reason)}"}
  end

  @spec source_files(String.t()) :: [String.t()]
  defp source_files(expanded),
    do: expanded |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.sort()

  @spec report_staged_source_change(atom(), String.t(), [String.t()], term(), keyword()) ::
          boolean()
  defp report_staged_source_change(name, expanded, files, source, opts) do
    admission = admission(opts)

    with {:ok, admitted} <- ArtifactAdmission.source_fingerprint(source, server: admission),
         {:ok, current} <- current_source_fingerprint(name, expanded, files, opts),
         false <- admitted == current do
      Minga.Events.broadcast(
        :extension_restart_required,
        %Minga.Events.ExtensionRestartRequiredEvent{
          extension: name,
          reason: :source_changed,
          old_ref: Base.encode16(admitted, case: :lower),
          new_ref: Base.encode16(current, case: :lower)
        }
      )

      true
    else
      _unchanged_or_unavailable -> false
    end
  end

  @spec current_source_fingerprint(atom(), String.t(), [String.t()], keyword()) ::
          {:ok, binary()} | {:error, term()}
  defp current_source_fingerprint(name, expanded, [], _opts) do
    json_path = Path.join(expanded, "plugin.json")

    with {:ok, raw} <- File.read(json_path),
         {:ok, manifest} when is_map(manifest) <- JSON.decode(raw) do
      substituted = substitute_json_root(manifest, expanded)

      module_name =
        name
        |> Atom.to_string()
        |> String.replace("-", "_")
        |> Macro.camelize()
        |> then(&Module.concat(Minga.Extension.Plugin, &1))

      payload =
        :erlang.term_to_binary(
          {Atom.to_string(module_name), Path.expand(expanded), substituted},
          [:deterministic]
        )

      {:ok, :crypto.hash(:sha256, payload)}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_plugin_json}
    end
  end

  defp current_source_fingerprint(_name, expanded, files, opts) do
    CompileCache.source_fingerprint(expanded, files, opts)
  end

  @spec substitute_json_root(term(), String.t()) :: term()
  defp substitute_json_root(value, root) when is_binary(value),
    do: String.replace(value, "${MINGA_PLUGIN_ROOT}", root)

  defp substitute_json_root(value, root) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, substitute_json_root(item, root)} end)

  defp substitute_json_root(value, root) when is_list(value),
    do: Enum.map(value, &substitute_json_root(&1, root))

  defp substitute_json_root(value, _root), do: value

  @spec resident_fingerprint(atom(), [module()]) :: binary()
  defp resident_fingerprint(application, modules) do
    digests = Enum.map(modules, &{&1, &1.module_info(:md5)})
    :crypto.hash(:sha256, :erlang.term_to_binary({:runtime_inventory_v1, application, digests}))
  end

  @spec log_diagnostics([map()]) :: :ok
  defp log_diagnostics(diagnostics) do
    Enum.each(diagnostics, fn diagnostic ->
      message = Map.get(diagnostic, :message, "")
      Minga.Log.warning(:editor, "[ext] #{message}")
    end)
  end

  @spec admission(keyword()) :: GenServer.server()
  defp admission(opts), do: Keyword.get(opts, :artifact_admission, ArtifactAdmission)
end
