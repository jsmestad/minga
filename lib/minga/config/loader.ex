defmodule Minga.Config.Loader do
  @moduledoc """
  Discovers and evaluates config files and user modules at startup.

  ## Load order (both startup and reload)

  1. `~/.config/minga/modules/*.ex` (compile at OS-process startup; retain on reload)
  2. `~/.config/minga/themes/*.exs` (load user themes, before config eval)
  3. `~/.config/minga/config.exs` (global config)
  4. `.minga.exs` in the current working directory (project-local config)
  5. `~/.config/minga/gui_settings.exs` (generated GUI settings overlay)
  6. `~/.config/minga/after.exs` (post-init hook)

  Later sources override earlier ones (last-writer-wins for options and
  keybindings). Errors at any stage are captured and stored for the
  editor to display as status bar warnings.

  ## Config file locations

  1. `$XDG_CONFIG_HOME/minga/config.exs` (if `$XDG_CONFIG_HOME` is set)
  2. `~/.config/minga/config.exs`

  If the file doesn't exist, the editor starts with defaults. No error,
  no warning.
  """

  use Agent

  alias Minga.Command
  alias Minga.Config.Advice
  alias Minga.Config.Hooks
  alias Minga.Config.ModelineSegments
  alias Minga.Config.Options
  alias Minga.Config.Writer
  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap
  alias Minga.Popup.Registry, as: PopupRegistry
  alias Minga.Log

  @type keymap_server :: Keymap.server()
  @type options_server :: Options.server()
  @typep user_module_mode :: :compile | {:reuse, [module()], [String.t()]}

  @typedoc "Loader state: stores paths, loaded modules, and any errors from each stage."
  @type state :: %{
          config_path: String.t(),
          load_error: String.t() | nil,
          loaded_modules: [module()],
          modules_errors: [String.t()],
          modules_fingerprint: binary(),
          extension_declarations_fingerprint: binary(),
          project_config_path: String.t() | nil,
          project_config_error: String.t() | nil,
          gui_settings_path: String.t(),
          gui_settings_error: String.t() | nil,
          after_error: String.t() | nil,
          lsp_settings: %{atom() => map()},
          keymap_server: keymap_server(),
          options_server: options_server(),
          cleanup_callbacks: %{atom() => ContributionCleanup.cleanup_fun()} | nil
        }

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc """
  Starts the loader, compiles user modules, and evaluates all config files.

  When the loader is started under the application supervisor, the caller
  process is the supervisor, so the `:minga_config_keymap` process-dict
  fallback below reads the supervisor's pdict (effectively unset) and
  resolves to `Keymap.default_server/0`. To target a non-default server at
  boot, pass `:keymap_server` explicitly. The chosen server is persisted in
  the loader's Agent state and re-read on `reload/1`.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    keymap_server =
      Keyword.get(
        opts,
        :keymap_server,
        Process.get(:minga_config_keymap, Keymap.default_server())
      )

    options_server =
      opts
      |> Keyword.get(
        :options_server,
        Process.get(:minga_config_options, Options.default_server())
      )
      |> Options.validate_server!()

    cleanup_callbacks = Keyword.get(opts, :cleanup_callbacks)
    config_home = Keyword.get(opts, :config_home)
    artifact_admission = Keyword.get(opts, :artifact_admission, ArtifactAdmission)

    Agent.start_link(
      fn ->
        state =
          load_all(
            keymap_server,
            options_server,
            Minga.SafeMode.active?(),
            cleanup_callbacks,
            config_home,
            :compile
          )

        :ok =
          maybe_seal_artifact_generation(
            artifact_admission,
            Application.get_env(:minga, :seal_extension_artifact_generation, true)
          )

        if config_home, do: Map.put(state, :config_home, config_home), else: state
      end,
      name: name
    )
  end

  @spec maybe_seal_artifact_generation(GenServer.server(), boolean()) :: :ok
  defp maybe_seal_artifact_generation(server, true) do
    :ok = ArtifactAdmission.seal(server: server)
  end

  defp maybe_seal_artifact_generation(_server, false), do: :ok

  @doc """
  Returns the resolved global config file path.

  This path is used by `SPC f p` to open the config file for editing.
  """
  @spec config_path() :: String.t()
  @spec config_path(GenServer.server()) :: String.t()
  def config_path, do: config_path(__MODULE__)
  def config_path(server), do: Agent.get(server, & &1.config_path)

  @doc """
  Returns the last global config load error, or `nil` if config loaded cleanly
  (or no config file exists).
  """
  @spec load_error() :: String.t() | nil
  @spec load_error(GenServer.server()) :: String.t() | nil
  def load_error, do: load_error(__MODULE__)
  def load_error(server), do: Agent.get(server, & &1.load_error)

  @doc "Returns the list of modules compiled from the user's modules directory."
  @spec loaded_modules() :: [module()]
  @spec loaded_modules(GenServer.server()) :: [module()]
  def loaded_modules, do: loaded_modules(__MODULE__)
  def loaded_modules(server), do: Agent.get(server, & &1.loaded_modules)

  @doc "Returns compilation errors from user modules, or an empty list if all compiled cleanly."
  @spec modules_errors() :: [String.t()]
  @spec modules_errors(GenServer.server()) :: [String.t()]
  def modules_errors, do: modules_errors(__MODULE__)
  def modules_errors(server), do: Agent.get(server, & &1.modules_errors)

  @doc "Returns the project-local config load error, or `nil` if clean (or no project config)."
  @spec project_config_error() :: String.t() | nil
  @spec project_config_error(GenServer.server()) :: String.t() | nil
  def project_config_error, do: project_config_error(__MODULE__)
  def project_config_error(server), do: Agent.get(server, & &1.project_config_error)

  @doc "Returns the generated GUI settings overlay path."
  @spec gui_settings_path() :: String.t()
  @spec gui_settings_path(GenServer.server()) :: String.t()
  def gui_settings_path, do: gui_settings_path(__MODULE__)

  def gui_settings_path(server) when is_atom(server) do
    case Process.whereis(server) do
      nil -> default_gui_settings_path()
      _pid -> Agent.get(server, & &1.gui_settings_path)
    end
  end

  def gui_settings_path(server), do: Agent.get(server, & &1.gui_settings_path)

  @doc "Returns the gui_settings.exs load error, or `nil` if clean (or no GUI overlay)."
  @spec gui_settings_error() :: String.t() | nil
  @spec gui_settings_error(GenServer.server()) :: String.t() | nil
  def gui_settings_error, do: gui_settings_error(__MODULE__)
  def gui_settings_error(server), do: Agent.get(server, & &1.gui_settings_error)

  @doc "Returns the after.exs load error, or `nil` if clean (or no after.exs)."
  @spec after_error() :: String.t() | nil
  @spec after_error(GenServer.server()) :: String.t() | nil
  def after_error, do: after_error(__MODULE__)
  def after_error(server), do: Agent.get(server, & &1.after_error)

  @doc "Returns LSP settings overrides loaded from user config."
  @spec lsp_settings() :: %{atom() => map()}
  @spec lsp_settings(GenServer.server()) :: %{atom() => map()}
  def lsp_settings, do: lsp_settings(__MODULE__)

  def lsp_settings(server) when is_atom(server) do
    case Process.whereis(server) do
      nil -> %{}
      _pid -> get_lsp_settings(server)
    end
  end

  def lsp_settings(server) when is_pid(server) do
    if Process.alive?(server), do: get_lsp_settings(server), else: %{}
  end

  def lsp_settings(server), do: get_lsp_settings(server)

  @doc """
  Reloads data declarations while keeping user modules resident.

  Resets Options, Hooks, Keymap.Active, and Command.Registry to defaults,
  then re-runs the config scripts. User module or extension source changes
  require a fresh Minga process. Returns `:ok` on success or `{:error, reason}`
  if something went wrong (errors are also stored in state).
  """
  @spec reload() :: :ok | {:error, String.t()}
  @spec reload(GenServer.server()) :: :ok | {:error, String.t()}
  def reload, do: reload(__MODULE__)

  def reload(server) do
    Writer.set_reloading(true)

    try do
      do_reload(server)
    after
      Writer.set_reloading(false)
    end
  end

  @spec do_reload(GenServer.server()) :: :ok | {:error, String.t()}
  defp do_reload(server) do
    with nil <- user_module_restart_required(server),
         nil <- extension_declaration_restart_required(server) do
      reload_current_extension_generation(server)
    else
      message when is_binary(message) -> reject_reload(server, message)
    end
  end

  @spec reload_current_extension_generation(GenServer.server()) :: :ok | {:error, String.t()}
  defp reload_current_extension_generation(server) do
    case ExtSupervisor.pending_artifact_restarts(Minga.Extension.Registry) do
      [] ->
        do_reload_unchanged_generation(server)

      changed ->
        names = Enum.map_join(changed, ", ", &Atom.to_string/1)
        reject_reload(server, "Extension restart required before config reload: #{names}")
    end
  end

  @spec user_module_restart_required(GenServer.server()) :: String.t() | nil
  defp user_module_restart_required(server) do
    {config_path, admitted_fingerprint} =
      Agent.get(server, fn state -> {state.config_path, state.modules_fingerprint} end)

    current_fingerprint = user_modules_fingerprint(Path.dirname(config_path))

    if current_fingerprint == admitted_fingerprint do
      nil
    else
      "User module restart required before config reload"
    end
  end

  @spec extension_declaration_restart_required(GenServer.server()) :: String.t() | nil
  defp extension_declaration_restart_required(server) do
    {config_path, gui_settings_path, admitted_fingerprint} =
      Agent.get(server, fn state ->
        {
          state.config_path,
          state.gui_settings_path,
          state.extension_declarations_fingerprint
        }
      end)

    current_fingerprint =
      extension_declarations_fingerprint(
        config_path,
        resolve_project_config_path(),
        gui_settings_path
      )

    if current_fingerprint == admitted_fingerprint do
      nil
    else
      "Extension declarations changed; restart Minga before config reload"
    end
  end

  @spec extension_declarations_fingerprint(String.t(), String.t() | nil, String.t()) :: binary()
  defp extension_declarations_fingerprint(config_path, project_config_path, gui_settings_path) do
    after_path = Path.join(Path.dirname(config_path), "after.exs")

    declarations =
      [config_path, project_config_path, gui_settings_path, after_path]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&extension_declarations/1)

    :crypto.hash(:sha256, :erlang.term_to_binary({File.cwd!(), declarations}))
  end

  @spec extension_declarations(String.t()) :: [term()]
  defp extension_declarations(path) do
    case File.read(path) do
      {:ok, source} -> extension_declarations(path, source)
      {:error, :enoent} -> []
      {:error, reason} -> [{path, {:read_error, reason}}]
    end
  end

  @spec extension_declarations(String.t(), String.t()) :: [term()]
  defp extension_declarations(path, source) do
    case Code.string_to_quoted(source, file: path) do
      {:ok, ast} ->
        {_ast, {declarations, dynamic?}} =
          Macro.prewalk(ast, {[], false}, fn
            {:extension, _meta, [name, opts]} = node, acc ->
              {node, collect_extension_declaration(path, name, opts, acc)}

            {:extension, _meta, [module]} = node, acc ->
              {node, collect_extension_declaration(path, module, [], acc)}

            {{:., _dot_meta, [_module, :extension]}, _meta, [name, opts]} = node, acc ->
              {node, collect_extension_declaration(path, name, opts, acc)}

            {{:., _dot_meta, [_module, :extension]}, _meta, [module]} = node, acc ->
              {node, collect_extension_declaration(path, module, [], acc)}

            node, acc ->
              {node, acc}
          end)

        if dynamic? do
          [{path, {:dynamic_source_file, :crypto.hash(:sha256, source)}}]
        else
          Enum.reverse(declarations)
        end

      {:error, _reason} ->
        [{path, {:invalid_config, :crypto.hash(:sha256, source)}}]
    end
  end

  @spec collect_extension_declaration(
          String.t(),
          Macro.t(),
          Macro.t(),
          {[term()], boolean()}
        ) :: {[term()], boolean()}
  defp collect_extension_declaration(path, name, opts, {declarations, dynamic?}) do
    case extension_source_identity(name, opts) do
      {:ok, identity} -> {[{path, identity} | declarations], dynamic?}
      :dynamic -> {declarations, true}
    end
  end

  @spec extension_source_identity(Macro.t(), Macro.t()) :: {:ok, term()} | :dynamic
  defp extension_source_identity(name_ast, opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, name} <- extension_name_identity(name_ast) do
      source_identity(name, opts)
    else
      _invalid -> :dynamic
    end
  end

  defp extension_source_identity(_name_ast, _opts), do: :dynamic

  @spec extension_name_identity(Macro.t()) :: {:ok, term()} | :dynamic
  defp extension_name_identity(name) when is_atom(name), do: {:ok, name}
  defp extension_name_identity({:__aliases__, _meta, parts}), do: {:ok, {:module, parts}}
  defp extension_name_identity(_name), do: :dynamic

  @spec source_identity(term(), keyword()) :: {:ok, term()} | :dynamic
  defp source_identity(name, opts) do
    source_keys = Enum.filter([:path, :git, :hex], &Keyword.has_key?(opts, &1))

    case source_keys do
      [] ->
        {:ok, {:module, name}}

      [:path] ->
        with {:ok, path} <- literal_source_value(Keyword.fetch!(opts, :path)) do
          {:ok, {:path, name, path}}
        end

      [:git] ->
        with {:ok, url} <- literal_source_value(Keyword.fetch!(opts, :git)),
             {:ok, branch} <- literal_source_value(Keyword.get(opts, :branch)),
             {:ok, ref} <- literal_source_value(Keyword.get(opts, :ref)) do
          {:ok, {:git, name, url, branch, ref}}
        end

      [:hex] ->
        with {:ok, package} <- literal_source_value(Keyword.fetch!(opts, :hex)),
             {:ok, version} <- literal_source_value(Keyword.get(opts, :version)),
             {:ok, app} <- literal_source_value(Keyword.get(opts, :app)) do
          {:ok, {:hex, name, package, version, app}}
        end

      _multiple_sources ->
        :dynamic
    end
  end

  @spec literal_source_value(Macro.t()) :: {:ok, term()} | :dynamic
  defp literal_source_value(value)
       when is_binary(value) or is_atom(value) or is_integer(value),
       do: {:ok, value}

  defp literal_source_value(_value), do: :dynamic

  @spec reject_reload(GenServer.server(), String.t()) :: {:error, String.t()}
  defp reject_reload(server, message) do
    Agent.update(server, fn state -> %{state | load_error: message} end)
    {:error, message}
  end

  @spec do_reload_unchanged_generation(GenServer.server()) :: :ok | {:error, String.t()}
  defp do_reload_unchanged_generation(server) do
    # Stop all running extensions first. If that fails, do not tear down
    # registries or start a new load, because the old extension tree is still
    # partially live and a reset would orphan it.
    cleanup_callbacks = Agent.get(server, &Map.get(&1, :cleanup_callbacks))
    stop_all_error = stop_all_extensions(cleanup_callbacks)

    if stop_all_error do
      Agent.update(server, fn state -> %{state | load_error: stop_all_error} end)
      {:error, stop_all_error}
    else
      # Reset all registries to defaults while preserving this VM's admitted user modules.
      {keymap_server, options_server, config_home, loaded_modules, modules_errors} =
        Agent.get(server, fn %{
                               keymap_server: keymap_server,
                               options_server: options_server,
                               loaded_modules: loaded_modules,
                               modules_errors: modules_errors
                             } = state ->
          {keymap_server, options_server, Map.get(state, :config_home), loaded_modules,
           modules_errors}
        end)

      maybe_reset_options(options_server)
      Hooks.reset()
      Advice.reset()
      Keymap.reset(keymap_server)
      Command.reset_registry()
      ExtRegistry.reset()
      PopupRegistry.clear()
      ModelineSegments.reset_warnings()

      # Re-run the full load sequence (includes starting extensions).
      # Reload deliberately ignores startup safe mode so fixed config can be loaded without restarting.
      new_state =
        load_all(
          keymap_server,
          options_server,
          false,
          cleanup_callbacks,
          config_home,
          {:reuse, loaded_modules, modules_errors}
        )

      Agent.update(server, fn _ -> new_state end)

      # Return error if any stage had problems
      errors =
        [
          new_state.load_error,
          new_state.project_config_error,
          new_state.gui_settings_error,
          new_state.after_error
        ]
        |> Enum.reject(&is_nil/1)

      all_errors = new_state.modules_errors ++ errors

      case all_errors do
        [] -> :ok
        msgs -> {:error, Enum.join(msgs, "; ")}
      end
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  # The process dictionary bridges per-loader state into config DSL functions,
  # which run synchronously while `.exs` configs evaluate. Code that calls those
  # helpers from a separate process (e.g., a GenServer started by an extension
  # callback) won't see this dict and will fall back to registered defaults.
  # Extensions are skipped in test mode, so this only affects long-lived runtime
  # callers.
  @spec load_all(
          keymap_server(),
          options_server(),
          boolean(),
          %{atom() => ContributionCleanup.cleanup_fun()} | nil,
          String.t() | nil,
          user_module_mode()
        ) :: state()
  defp load_all(
         keymap_server,
         options_server,
         safe_mode?,
         cleanup_callbacks,
         config_home,
         user_module_mode
       )
       when is_boolean(safe_mode?) do
    previous_keymap_server = Process.put(:minga_config_keymap, keymap_server)
    previous_options_server = Process.put(:minga_config_options, options_server)
    previous_lsp_settings = Process.put(:minga_config_lsp_settings, %{})

    try do
      config_cleanup_error =
        cleanup_source_owned_config_contributions(keymap_server, cleanup_callbacks)

      config_path = resolve_config_path(config_home)
      config_dir = Path.dirname(config_path)

      # 0. Register default popup rules (before user config so overrides work)
      register_default_popup_rules()

      if safe_mode? do
        safe_mode_state(config_path, config_dir, keymap_server, options_server, cleanup_callbacks)
      else
        alias Minga.Telemetry.StartupTimer

        StartupTimer.mark(:config_loader_start)

        # 1. Compile user modules only at OS-process startup. Reload reuses residents.
        {loaded_modules, modules_errors} = resolve_user_modules(config_dir, user_module_mode)
        modules_fingerprint = user_modules_fingerprint(config_dir)
        StartupTimer.mark(:config_user_modules)

        # 2. Load user themes (before config eval so `set :theme, :my_custom` works)
        load_user_themes()
        StartupTimer.mark(:config_user_themes)

        # 3. Eval global config
        custom_config? = cli_config_file() != nil

        load_error =
          case {custom_config?, File.exists?(config_path)} do
            {true, false} ->
              "Custom config not found: #{config_path} (using defaults)"

            _ ->
              eval_if_exists(config_path)
          end

        load_error =
          if custom_config? and load_error == nil and not String.ends_with?(config_path, ".exs") do
            "Custom config path does not end in .exs: #{config_path} (file was loaded, but may not be valid Elixir)"
          else
            load_error
          end

        StartupTimer.mark(:config_global_eval)

        # 4. Eval project-local config
        project_path = resolve_project_config_path()
        project_config_error = eval_if_exists(project_path)
        project_mcp_error = load_project_mcp_json()
        StartupTimer.mark(:config_project_eval)

        # 5. Eval generated GUI settings overlay
        gui_settings_path = Path.join(config_dir, "gui_settings.exs")

        gui_settings_error =
          with_config_source(:gui_settings, fn -> eval_if_exists(gui_settings_path) end)

        # 6. Eval after.exs
        after_path = Path.join(config_dir, "after.exs")
        after_error = eval_if_exists(after_path)

        # 7. Apply log level from config
        apply_log_level(options_server)

        StartupTimer.mark(:config_after_and_settings)

        # 8. Register bundled extensions, then discover plugins, then start extensions only after all
        # config sources have had a chance to declare them.
        register_bundled_extensions()
        plugin_error = discover_and_register_plugins(config_home)

        start_all_error =
          if Process.whereis(Minga.Extension.RootSupervisor) != nil &&
               Application.get_env(:minga, :load_extensions, true) do
            start_all_extensions(cleanup_callbacks)
          end

        StartupTimer.mark(:config_extensions_started)

        load_error =
          merge_error_messages([
            config_cleanup_error,
            load_error,
            project_mcp_error,
            plugin_error,
            start_all_error
          ])

        lsp_settings = Process.get(:minga_config_lsp_settings, %{})

        %{
          config_path: config_path,
          load_error: load_error,
          loaded_modules: loaded_modules,
          modules_errors: modules_errors,
          modules_fingerprint: modules_fingerprint,
          extension_declarations_fingerprint:
            extension_declarations_fingerprint(config_path, project_path, gui_settings_path),
          project_config_path: project_path,
          project_config_error: project_config_error,
          gui_settings_path: gui_settings_path,
          gui_settings_error: gui_settings_error,
          after_error: after_error,
          lsp_settings: lsp_settings,
          keymap_server: keymap_server,
          options_server: options_server,
          cleanup_callbacks: cleanup_callbacks
        }
      end
    after
      restore_pdict(:minga_config_keymap, previous_keymap_server)
      restore_pdict(:minga_config_options, previous_options_server)
      restore_pdict(:minga_config_lsp_settings, previous_lsp_settings)
    end
  end

  @spec safe_mode_state(
          String.t(),
          String.t(),
          keymap_server(),
          options_server(),
          %{atom() => ContributionCleanup.cleanup_fun()} | nil
        ) :: state()
  defp safe_mode_state(config_path, config_dir, keymap_server, options_server, cleanup_callbacks) do
    %{
      config_path: config_path,
      load_error: nil,
      loaded_modules: [],
      modules_errors: [],
      modules_fingerprint: user_modules_fingerprint(config_dir),
      extension_declarations_fingerprint:
        extension_declarations_fingerprint(
          config_path,
          nil,
          Path.join(config_dir, "gui_settings.exs")
        ),
      project_config_path: nil,
      project_config_error: nil,
      gui_settings_path: Path.join(config_dir, "gui_settings.exs"),
      gui_settings_error: nil,
      after_error: nil,
      lsp_settings: %{},
      keymap_server: keymap_server,
      options_server: options_server,
      cleanup_callbacks: cleanup_callbacks
    }
  end

  @spec register_bundled_extensions() :: :ok
  defp register_bundled_extensions do
    ExtRegistry.register(
      :minga_git_porcelain,
      bundled_extension_path("git_porcelain"),
      load_policy: :deferred
    )

    ExtRegistry.register(
      :minga_knowledge_graph,
      bundled_extension_path("knowledge_graph"),
      load_policy: :deferred
    )

    ExtRegistry.register(
      :minga_adversarial,
      bundled_extension_path("adversarial"),
      load_policy: :deferred
    )

    :ok
  end

  @spec bundled_extension_path(String.t()) :: String.t()
  defp bundled_extension_path(name) do
    priv_path = Application.app_dir(:minga, Path.join(["priv", "extensions", name, "lib"]))

    if File.dir?(priv_path) do
      priv_path
    else
      bundled_extension_fallback_path(name, priv_path)
    end
  end

  @spec bundled_extension_fallback_path(String.t(), String.t()) :: String.t()
  defp bundled_extension_fallback_path(name, priv_path) do
    source_path = Path.expand("../../../extensions/#{name}/lib", __DIR__)

    if source_extension_fallback_allowed?() and File.dir?(source_path) do
      source_path
    else
      Log.warning(
        :config,
        "Bundled extension #{name} is missing at #{priv_path}; source-tree fallback is disabled"
      )

      priv_path
    end
  end

  @spec source_extension_fallback_allowed?() :: boolean()
  defp source_extension_fallback_allowed? do
    Application.get_env(:minga, :allow_source_extension_fallback, false)
  end

  # ── Plugin Discovery ──────────────────────────────────────────────────────────

  @spec discover_and_register_plugins(String.t() | nil) :: String.t() | nil
  defp discover_and_register_plugins(config_home) do
    user_dir = user_plugins_dir(config_home)
    project_dir = project_plugins_dir()

    user_errors = register_plugins_from_dir(user_dir)
    project_errors = register_plugins_from_dir(project_dir)

    merge_error_messages(user_errors ++ project_errors)
  end

  @spec user_plugins_dir(String.t() | nil) :: String.t()
  defp user_plugins_dir(config_home) do
    Path.join([config_base_dir(config_home), "minga", "plugins"])
  end

  @spec project_plugins_dir() :: String.t()
  defp project_plugins_dir do
    Path.join([File.cwd!(), ".minga", "plugins"])
  end

  @spec register_plugins_from_dir(String.t()) :: [String.t()]
  defp register_plugins_from_dir(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce([], fn entry, errors ->
          plugin_path = Path.join(dir, entry)
          register_plugin_entry(plugin_path, entry, errors)
        end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        ["Plugin directory #{dir}: #{inspect(reason)}"]
    end
  end

  @plugin_name_pattern ~r/^[a-z][a-z0-9_-]*$/

  @spec register_plugin_entry(String.t(), String.t(), [String.t()]) :: [String.t()]
  defp register_plugin_entry(plugin_path, entry, errors) do
    register_plugin_dir(File.dir?(plugin_path), plugin_path, entry, errors)
  end

  @spec register_plugin_dir(boolean(), String.t(), String.t(), [String.t()]) :: [String.t()]
  defp register_plugin_dir(false, _plugin_path, _entry, errors), do: errors

  defp register_plugin_dir(true, plugin_path, entry, errors) do
    if Regex.match?(@plugin_name_pattern, entry) do
      ExtRegistry.register(String.to_atom(entry), plugin_path, [])
      errors
    else
      ["Plugin directory name must match [a-z][a-z0-9_-]*: #{entry}" | errors]
    end
  end

  @spec with_config_source(atom(), (-> term())) :: term()
  defp with_config_source(source, fun) when is_atom(source) and is_function(fun, 0) do
    previous = Process.put(:minga_config_source, source)

    try do
      fun.()
    after
      restore_pdict(:minga_config_source, previous)
    end
  end

  @spec restore_pdict(atom(), term() | nil) :: term() | nil
  defp restore_pdict(key, nil), do: Process.delete(key)
  defp restore_pdict(key, value), do: Process.put(key, value)

  @spec get_lsp_settings(GenServer.server()) :: %{atom() => map()}
  defp get_lsp_settings(server) do
    Agent.get(server, fn state -> Map.get(state, :lsp_settings, %{}) end)
  end

  # Skips the reset if the persisted options_server is no longer alive (anonymous
  # pid that crashed and was never restarted) or never registered. Otherwise
  # `Options.reset/1` exits with :noproc, taking the loader Agent down with it.
  @spec maybe_reset_options(options_server()) :: :ok
  defp maybe_reset_options(server) do
    if options_server_alive?(server) do
      Options.reset(server)
    else
      Log.warning(
        :config,
        "Loader.reload: options_server #{inspect(server)} not alive, skipping reset"
      )
    end

    :ok
  end

  @spec start_all_extensions(%{atom() => ContributionCleanup.cleanup_fun()} | nil) ::
          String.t() | nil
  defp start_all_extensions(cleanup_callbacks) do
    case ExtSupervisor.start_all(
           Minga.Extension.Supervisor,
           Minga.Extension.Registry,
           cleanup_opts(cleanup_callbacks)
         ) do
      :ok ->
        nil

      {:error, failures} ->
        msg = "Extension start_all failed: #{format_start_failures(failures)}"
        Log.warning(:config, msg)
        msg
    end
  end

  @spec stop_all_extensions(%{atom() => ContributionCleanup.cleanup_fun()} | nil) ::
          String.t() | nil
  defp stop_all_extensions(cleanup_callbacks) do
    case ExtSupervisor.stop_all(
           Minga.Extension.Supervisor,
           Minga.Extension.Registry,
           cleanup_opts(cleanup_callbacks)
         ) do
      :ok ->
        nil

      {:error, failures} ->
        msg = "Extension stop_all failed: #{format_stop_failures(failures)}"
        Log.warning(:config, msg)
        msg
    end
  end

  @spec cleanup_source_owned_config_contributions(
          keymap_server(),
          %{atom() => ContributionCleanup.cleanup_fun()} | nil
        ) :: String.t() | nil
  defp cleanup_source_owned_config_contributions(keymap_server, cleanup_callbacks) do
    cleanup_opts = Keyword.merge([keymap: keymap_server], cleanup_opts(cleanup_callbacks))

    case ContributionCleanup.unregister_source(:config, cleanup_opts) do
      :ok ->
        nil

      {:error, failures} ->
        msg = "Config reload cleanup for :config failed: #{format_cleanup_failures(failures)}"
        Log.warning(:config, msg)
        msg
    end
  end

  @spec cleanup_opts(%{atom() => ContributionCleanup.cleanup_fun()} | nil) :: keyword()
  defp cleanup_opts(nil), do: []
  defp cleanup_opts(callbacks) when is_map(callbacks), do: [callbacks: callbacks]

  @spec merge_error_messages([String.t() | nil]) :: String.t() | nil
  defp merge_error_messages(messages) do
    messages
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      [msg] -> msg
      msgs -> Enum.join(msgs, "; ")
    end
  end

  @spec format_cleanup_failures([map()]) :: String.t()
  defp format_cleanup_failures(failures) do
    Enum.map_join(failures, "; ", &format_cleanup_failure/1)
  end

  @spec format_cleanup_failure(map()) :: String.t()
  defp format_cleanup_failure(%{family: family, source: source, reason: reason}) do
    "#{inspect(family)} source=#{inspect(source)} reason=#{inspect(reason)}"
  end

  @spec format_start_failures([map()]) :: String.t()
  defp format_start_failures(failures) do
    Enum.map_join(failures, "; ", fn %{extension: extension, reason: reason} ->
      "#{inspect(extension)} reason=#{inspect(reason)}"
    end)
  end

  @spec format_stop_failures([map()]) :: String.t()
  defp format_stop_failures(failures) do
    Enum.map_join(failures, "; ", fn %{extension: extension, reason: reason} ->
      "#{inspect(extension)} reason=#{inspect(reason)}"
    end)
  end

  @spec options_server_alive?(options_server()) :: boolean()
  defp options_server_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp options_server_alive?(name) when is_atom(name), do: Process.whereis(name) != nil

  @spec load_user_themes() :: :ok
  defp load_user_themes do
    Minga.Events.broadcast(
      :load_user_themes,
      %Minga.Events.LoadUserThemesEvent{},
      Minga.Events.default_registry()
    )

    :ok
  end

  @spec apply_log_level(options_server()) :: :ok
  defp apply_log_level(options_server) do
    level = Options.get(options_server, :log_level)

    # Only apply the Minga log level if it is more restrictive than what
    # Mix config already set. This prevents the default :info from
    # overriding config/test.exs {:logger, level: :warning}.
    current = Logger.level()

    if Logger.compare_levels(level, current) == :gt do
      Logger.configure(level: level)
    end

    :ok
  rescue
    # The Options ETS table is not registered yet (typically the suite-wide
    # singleton hasn't booted under test). Other failure modes — wrong
    # log_level value, Logger crashes — are real bugs and should propagate.
    ArgumentError -> :ok
  end

  @spec resolve_user_modules(String.t(), user_module_mode()) :: {[module()], [String.t()]}
  defp resolve_user_modules(config_dir, :compile), do: compile_user_modules(config_dir)

  defp resolve_user_modules(_config_dir, {:reuse, loaded_modules, modules_errors}),
    do: {loaded_modules, modules_errors}

  @spec user_modules_fingerprint(String.t()) :: binary()
  defp user_modules_fingerprint(config_dir) do
    modules_dir = Path.join(config_dir, "modules")

    snapshot =
      case File.ls(modules_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".ex"))
          |> Enum.sort()
          |> Enum.map(fn file -> {file, File.read(Path.join(modules_dir, file))} end)

        {:error, reason} ->
          {:directory_error, reason}
      end

    :crypto.hash(:sha256, :erlang.term_to_binary(snapshot, [:deterministic]))
  end

  @spec compile_user_modules(String.t()) :: {[module()], [String.t()]}
  defp compile_user_modules(config_dir) do
    modules_dir = Path.join(config_dir, "modules")

    case File.ls(modules_dir) do
      {:ok, files} ->
        compile_module_files(modules_dir, files)

      {:error, :enoent} ->
        {[], []}

      {:error, reason} ->
        msg = "Could not read modules directory #{modules_dir}: #{inspect(reason)}"
        Log.warning(:config, msg)
        {[], [msg]}
    end
  end

  @spec compile_module_files(String.t(), [String.t()]) :: {[module()], [String.t()]}
  defp compile_module_files(modules_dir, files) do
    {mods, errs} =
      files
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn file, {mods_acc, errs_acc} ->
        path = Path.join(modules_dir, file)

        case compile_module(path) do
          {:ok, modules} -> {mods_acc ++ modules, errs_acc}
          {:error, msg} -> {mods_acc, [msg | errs_acc]}
        end
      end)

    {mods, Enum.reverse(errs)}
  end

  @spec compile_module(String.t()) :: {:ok, [module()]} | {:error, String.t()}
  defp compile_module(path) do
    modules =
      path
      |> Code.compile_file()
      |> Enum.map(&elem(&1, 0))

    {:ok, modules}
  rescue
    e in [SyntaxError, TokenMissingError, CompileError] ->
      msg = "Module compile error in #{path}: #{Exception.message(e)}"
      Log.warning(:config, msg)
      {:error, msg}

    e ->
      msg = "Module error in #{path}: #{Exception.message(e)}"
      Log.warning(:config, msg)
      {:error, msg}
  catch
    kind, reason ->
      msg = "Module error in #{path}: #{inspect(kind)} #{inspect(reason)}"
      Log.warning(:config, msg)
      {:error, msg}
  end

  @spec resolve_config_path(String.t() | nil) :: String.t()
  defp resolve_config_path(config_home) do
    case cli_config_file() do
      path when is_binary(path) -> path
      nil -> default_config_path(config_home)
    end
  end

  # Checks CLI startup flags for a --config override.
  @spec cli_config_file() :: String.t() | nil
  defp cli_config_file do
    case Application.get_env(:minga, :cli_startup_flags) do
      %{config_file: path} when is_binary(path) -> path
      _ -> nil
    end
  end

  @spec default_gui_settings_path(String.t() | nil) :: String.t()
  defp default_gui_settings_path(config_home \\ nil) do
    default_config_path(config_home)
    |> Path.dirname()
    |> Path.join("gui_settings.exs")
  end

  @spec default_config_path(String.t() | nil) :: String.t()
  defp default_config_path(config_home) do
    Path.join([config_base_dir(config_home), "minga", "config.exs"])
  end

  @spec config_base_dir(String.t() | nil) :: String.t()
  defp config_base_dir(config_home) do
    case config_home do
      dir when is_binary(dir) ->
        dir

      _ ->
        case System.get_env("XDG_CONFIG_HOME") do
          nil -> Path.expand("~/.config")
          "" -> Path.expand("~/.config")
          dir -> dir
        end
    end
  end

  @spec load_project_mcp_json() :: String.t() | nil
  defp load_project_mcp_json do
    path = Path.join([File.cwd!(), ".minga", "mcp.json"])

    if File.exists?(path) do
      path
      |> File.read()
      |> parse_project_mcp_json(path)
    end
  end

  @spec parse_project_mcp_json({:ok, String.t()} | {:error, term()}, String.t()) ::
          String.t() | nil
  defp parse_project_mcp_json({:ok, content}, path) do
    case JSON.decode(content) do
      {:ok, decoded} -> register_project_mcp_servers(decoded)
      {:error, reason} -> "#{path}: invalid JSON: #{inspect(reason)}"
    end
  end

  defp parse_project_mcp_json({:error, reason}, path), do: "#{path}: #{inspect(reason)}"

  @spec register_project_mcp_servers(term()) :: String.t() | nil
  defp register_project_mcp_servers(%{"mcpServers" => servers}) when is_map(servers) do
    case normalize_project_mcp_server_entries(servers) do
      {:ok, entries} -> append_project_mcp_servers(entries)
      {:error, reason} -> reason
    end
  end

  defp register_project_mcp_servers(%{"servers" => servers}) when is_list(servers),
    do: append_project_mcp_servers(servers)

  defp register_project_mcp_servers(servers) when is_list(servers),
    do: append_project_mcp_servers(servers)

  defp register_project_mcp_servers(_decoded) do
    ".minga/mcp.json must contain a mcpServers object, servers list, or server list"
  end

  @spec normalize_project_mcp_server_entries(map()) :: {:ok, [map()]} | {:error, String.t()}
  defp normalize_project_mcp_server_entries(servers) when is_map(servers) do
    Enum.reduce_while(servers, {:ok, []}, fn {name, config}, {:ok, acc} ->
      if is_map(config) do
        {:cont, {:ok, [Map.put(config, "name", name) | acc]}}
      else
        {:halt,
         {:error, ".minga/mcp.json mcpServers.#{name} must be a map, got: #{inspect(config)}"}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec append_project_mcp_servers([map()]) :: String.t() | nil
  defp append_project_mcp_servers(servers) do
    case MingaAgent.MCP.ServerConfig.normalize_list(servers) do
      {:ok, normalized} ->
        server = Process.get(:minga_config_options, Options.default_server())
        existing = Options.get(server, :agent_mcp_servers)
        configs = Enum.map(normalized, &Map.from_struct/1)

        case Options.set(server, :agent_mcp_servers, existing ++ configs) do
          {:ok, _servers} -> nil
          {:error, message} -> message
        end

      {:error, reason} ->
        reason
    end
  end

  @spec resolve_project_config_path() :: String.t() | nil
  defp resolve_project_config_path do
    path = Path.join(File.cwd!(), ".minga.exs")

    if File.exists?(path) do
      path
    else
      nil
    end
  end

  @spec eval_if_exists(String.t() | nil) :: String.t() | nil
  defp eval_if_exists(nil), do: nil

  defp eval_if_exists(path) do
    if File.exists?(path) do
      eval_config_file(path)
    else
      nil
    end
  end

  @spec register_default_popup_rules() :: :ok
  defp register_default_popup_rules do
    alias Minga.Popup.Rule

    PopupRegistry.init()

    defaults = [
      Rule.new("*Warnings*", side: :bottom, size: {:percent, 30}, focus: false),
      Rule.new("*Messages*", side: :bottom, size: {:percent, 25}, focus: false, auto_close: true)
    ]

    Enum.each(defaults, &PopupRegistry.register/1)
    :ok
  end

  @spec eval_config_file(String.t()) :: String.t() | nil
  defp eval_config_file(path) do
    Code.eval_file(path)
    nil
  rescue
    e in [SyntaxError, TokenMissingError, CompileError] ->
      msg = "Config syntax error in #{path}: #{Exception.message(e)}"
      Log.warning(:config, msg)
      msg

    e ->
      msg = "Config error in #{path}: #{Exception.message(e)}"
      Log.warning(:config, msg)
      msg
  catch
    kind, reason ->
      msg = "Config error in #{path}: #{inspect(kind)} #{inspect(reason)}"
      Log.warning(:config, msg)
      msg
  end
end
