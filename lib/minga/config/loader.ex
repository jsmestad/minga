defmodule Minga.Config.Loader do
  @moduledoc """
  Discovers and evaluates config files and user modules at startup.

  ## Load order (both startup and reload)

  1. `~/.config/minga/modules/*.ex` (compile user modules)
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
  alias Minga.Extension.ContributionCleanup
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap
  alias Minga.Popup.Registry, as: PopupRegistry

  @type keymap_server :: Keymap.server()
  @type options_server :: Options.server()

  @typedoc "Loader state: stores paths, loaded modules, and any errors from each stage."
  @type state :: %{
          config_path: String.t(),
          load_error: String.t() | nil,
          loaded_modules: [module()],
          modules_errors: [String.t()],
          project_config_path: String.t() | nil,
          project_config_error: String.t() | nil,
          gui_settings_path: String.t(),
          gui_settings_error: String.t() | nil,
          after_error: String.t() | nil,
          lsp_settings: %{atom() => map()},
          keymap_server: keymap_server(),
          options_server: options_server()
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

    Agent.start_link(fn -> load_all(keymap_server, options_server) end, name: name)
  end

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
  Reloads all config from scratch.

  Purges previously loaded user modules, resets Options, Hooks,
  Keymap.Active, and Command.Registry to defaults, then re-runs the
  full load sequence. Returns `:ok` on success or `{:error, reason}`
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
    # Stop all running extensions first. If that fails, do not tear down
    # registries or start a new load, because the old extension tree is still
    # partially live and a reset would orphan it.
    stop_all_error = stop_all_extensions()

    if stop_all_error do
      Agent.update(server, fn state -> %{state | load_error: stop_all_error} end)
      {:error, stop_all_error}
    else
      # Get the old modules so we can purge them
      old_modules = Agent.get(server, & &1.loaded_modules)

      # Purge old user modules
      for mod <- old_modules do
        :code.purge(mod)
        :code.delete(mod)
      end

      # Reset all registries to defaults
      {keymap_server, options_server} =
        Agent.get(server, fn
          %{keymap_server: keymap_server, options_server: options_server} ->
            {keymap_server, options_server}

          # Defensive fallback: state shape predates the *_server fields.
          # Unreachable in single-version processes; logged so a real schema
          # mismatch doesn't degrade silently.
          _ ->
            Minga.Log.warning(
              :config,
              "loader state missing :keymap_server/:options_server; using defaults"
            )

            {
              Process.get(:minga_config_keymap, Keymap.default_server()),
              Process.get(:minga_config_options, Options.default_server())
            }
        end)

      maybe_reset_options(options_server)
      Hooks.reset()
      Advice.reset()
      Keymap.reset(keymap_server)
      Command.reset_registry()
      ExtRegistry.reset()
      PopupRegistry.clear()
      ModelineSegments.reset_warnings()

      # Re-run the full load sequence (includes starting extensions)
      new_state = load_all(keymap_server, options_server)
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
  @spec load_all(keymap_server(), options_server()) :: state()
  defp load_all(keymap_server, options_server) do
    previous_keymap_server = Process.put(:minga_config_keymap, keymap_server)
    previous_options_server = Process.put(:minga_config_options, options_server)
    previous_lsp_settings = Process.put(:minga_config_lsp_settings, %{})

    try do
      config_cleanup_error = cleanup_source_owned_config_contributions(keymap_server)
      config_path = resolve_config_path()
      config_dir = Path.dirname(config_path)

      # 0. Register default popup rules (before user config so overrides work)
      register_default_popup_rules()

      # 1. Compile user modules
      {loaded_modules, modules_errors} = compile_user_modules(config_dir)

      # 2. Load user themes (before config eval so `set :theme, :my_custom` works)
      load_user_themes()

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

      # 4. Eval project-local config
      project_path = resolve_project_config_path()
      project_config_error = eval_if_exists(project_path)

      # 5. Eval generated GUI settings overlay
      gui_settings_path = Path.join(config_dir, "gui_settings.exs")

      gui_settings_error =
        with_config_source(:gui_settings, fn -> eval_if_exists(gui_settings_path) end)

      # 6. Eval after.exs
      after_path = Path.join(config_dir, "after.exs")
      after_error = eval_if_exists(after_path)

      # 7. Apply log level from config
      apply_log_level(options_server)

      # 8. Register bundled extensions, then start extensions only after all config sources have had a chance
      # to declare them.
      register_bundled_extensions()

      start_all_error =
        if Process.whereis(Minga.Extension.Supervisor) != nil &&
             Application.get_env(:minga, :load_extensions, true) do
          start_all_extensions()
        end

      load_error = merge_error_messages([config_cleanup_error, load_error, start_all_error])

      lsp_settings = Process.get(:minga_config_lsp_settings, %{})

      %{
        config_path: config_path,
        load_error: load_error,
        loaded_modules: loaded_modules,
        modules_errors: modules_errors,
        project_config_path: project_path,
        project_config_error: project_config_error,
        gui_settings_path: gui_settings_path,
        gui_settings_error: gui_settings_error,
        after_error: after_error,
        lsp_settings: lsp_settings,
        keymap_server: keymap_server,
        options_server: options_server
      }
    after
      restore_pdict(:minga_config_keymap, previous_keymap_server)
      restore_pdict(:minga_config_options, previous_options_server)
      restore_pdict(:minga_config_lsp_settings, previous_lsp_settings)
    end
  end

  @spec register_bundled_extensions() :: :ok
  defp register_bundled_extensions do
    if Application.get_env(:minga, :load_git_porcelain_extension, true) do
      ExtRegistry.register(:minga_git_porcelain, bundled_extension_path("git_porcelain"), [])
    end

    if Application.get_env(:minga, :load_board_extension, true) do
      ExtRegistry.register(:minga_board, bundled_extension_path("board"), [])
    end

    :ok
  end

  @spec bundled_extension_path(String.t()) :: String.t()
  defp bundled_extension_path(name) do
    priv_path = Application.app_dir(:minga, Path.join(["priv", "extensions", name, "lib"]))

    case File.dir?(priv_path) do
      true -> priv_path
      false -> bundled_extension_fallback_path(name, priv_path)
    end
  end

  @spec bundled_extension_fallback_path(String.t(), String.t()) :: String.t()
  defp bundled_extension_fallback_path(name, priv_path) do
    source_path = Path.expand("../../../extensions/#{name}/lib", __DIR__)

    if source_extension_fallback_allowed?() and File.dir?(source_path) do
      source_path
    else
      Minga.Log.warning(
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
      Minga.Log.warning(
        :config,
        "Loader.reload: options_server #{inspect(server)} not alive, skipping reset"
      )
    end

    :ok
  end

  @spec start_all_extensions() :: String.t() | nil
  defp start_all_extensions do
    case ExtSupervisor.start_all() do
      :ok ->
        nil

      {:error, failures} ->
        msg = "Extension start_all failed: #{format_start_failures(failures)}"
        Minga.Log.warning(:config, msg)
        msg
    end
  end

  @spec stop_all_extensions() :: String.t() | nil
  defp stop_all_extensions do
    case ExtSupervisor.stop_all() do
      :ok ->
        nil

      {:error, failures} ->
        msg = "Extension stop_all failed: #{format_stop_failures(failures)}"
        Minga.Log.warning(:config, msg)
        msg
    end
  end

  @spec cleanup_source_owned_config_contributions(keymap_server()) :: String.t() | nil
  defp cleanup_source_owned_config_contributions(keymap_server) do
    case ContributionCleanup.unregister_source(:config, keymap: keymap_server) do
      :ok ->
        nil

      {:error, failures} ->
        msg = "Config reload cleanup for :config failed: #{format_cleanup_failures(failures)}"
        Minga.Log.warning(:config, msg)
        msg
    end
  end

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
        Minga.Log.warning(:config, msg)
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
      Minga.Log.warning(:config, msg)
      {:error, msg}

    e ->
      msg = "Module error in #{path}: #{Exception.message(e)}"
      Minga.Log.warning(:config, msg)
      {:error, msg}
  catch
    kind, reason ->
      msg = "Module error in #{path}: #{inspect(kind)} #{inspect(reason)}"
      Minga.Log.warning(:config, msg)
      {:error, msg}
  end

  @spec resolve_config_path() :: String.t()
  defp resolve_config_path do
    case cli_config_file() do
      path when is_binary(path) -> path
      nil -> default_config_path()
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

  @spec default_gui_settings_path() :: String.t()
  defp default_gui_settings_path do
    default_config_path()
    |> Path.dirname()
    |> Path.join("gui_settings.exs")
  end

  @spec default_config_path() :: String.t()
  defp default_config_path do
    base =
      case System.get_env("XDG_CONFIG_HOME") do
        nil -> Path.expand("~/.config")
        "" -> Path.expand("~/.config")
        dir -> dir
      end

    Path.join([base, "minga", "config.exs"])
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
      Minga.Log.warning(:config, msg)
      msg

    e ->
      msg = "Config error in #{path}: #{Exception.message(e)}"
      Minga.Log.warning(:config, msg)
      msg
  catch
    kind, reason ->
      msg = "Config error in #{path}: #{inspect(kind)} #{inspect(reason)}"
      Minga.Log.warning(:config, msg)
      msg
  end
end
