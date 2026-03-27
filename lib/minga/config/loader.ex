defmodule Minga.Config.Loader do
  @moduledoc """
  Discovers and evaluates config files and user modules at startup.

  ## Load order (both startup and reload)

  1. `~/.config/minga/modules/*.ex` (compile user modules)
  2. `~/.config/minga/themes/*.exs` (load user themes, before config eval)
  3. `~/.config/minga/config.exs` (global config)
  4. `.minga.exs` in the current working directory (project-local config)
  5. `~/.config/minga/after.exs` (post-init hook)

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

  alias Minga.Command.Registry, as: CommandRegistry
  alias Minga.Config.Advice
  alias Minga.Config.Hooks
  alias Minga.Config.Options
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Supervisor, as: ExtSupervisor
  alias Minga.Keymap
  alias Minga.UI.Popup.Registry, as: PopupRegistry
  alias Minga.UI.Theme.Loader, as: ThemeLoader

  @typedoc "Loader state: stores paths, loaded modules, and any errors from each stage."
  @type state :: %{
          config_path: String.t(),
          load_error: String.t() | nil,
          loaded_modules: [module()],
          modules_errors: [String.t()],
          project_config_path: String.t() | nil,
          project_config_error: String.t() | nil,
          after_error: String.t() | nil
        }

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Starts the loader, compiles user modules, and evaluates all config files."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    Agent.start_link(fn -> load_all() end, name: name)
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

  @doc "Returns the after.exs load error, or `nil` if clean (or no after.exs)."
  @spec after_error() :: String.t() | nil
  @spec after_error(GenServer.server()) :: String.t() | nil
  def after_error, do: after_error(__MODULE__)
  def after_error(server), do: Agent.get(server, & &1.after_error)

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
    # Stop all running extensions first
    ExtSupervisor.stop_all()

    # Get the old modules so we can purge them
    old_modules = Agent.get(server, & &1.loaded_modules)

    # Purge old user modules
    for mod <- old_modules do
      :code.purge(mod)
      :code.delete(mod)
    end

    # Reset all registries to defaults
    Options.reset()
    Hooks.reset()
    Advice.reset()
    Keymap.reset()
    CommandRegistry.reset()
    ExtRegistry.reset()
    PopupRegistry.clear()

    # Re-run the full load sequence (includes starting extensions)
    new_state = load_all()
    Agent.update(server, fn _ -> new_state end)

    # Return error if any stage had problems
    errors =
      [new_state.load_error, new_state.project_config_error, new_state.after_error]
      |> Enum.reject(&is_nil/1)

    all_errors = new_state.modules_errors ++ errors

    case all_errors do
      [] -> :ok
      msgs -> {:error, Enum.join(msgs, "; ")}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec load_all() :: state()
  defp load_all do
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

    # 5. Eval after.exs
    after_path = Path.join(config_dir, "after.exs")
    after_error = eval_if_exists(after_path)

    # 6. Apply log level from config
    apply_log_level()

    # 7. Start declared extensions (if the supervisor is running)
    if Process.whereis(Minga.Extension.Supervisor) do
      ExtSupervisor.start_all()
    end

    %{
      config_path: config_path,
      load_error: load_error,
      loaded_modules: loaded_modules,
      modules_errors: modules_errors,
      project_config_path: project_path,
      project_config_error: project_config_error,
      after_error: after_error
    }
  end

  @spec load_user_themes() :: :ok
  defp load_user_themes do
    {themes, errors} = ThemeLoader.load_all()
    Minga.UI.Theme.register_user_themes(themes)

    for %{path: path, error: error} <- errors do
      Minga.Log.warning(:editor, "Theme load error: #{path}: #{error}")
    end

    :ok
  end

  @spec apply_log_level() :: :ok
  defp apply_log_level do
    level = Options.get(:log_level)

    # Only apply the Minga log level if it is more restrictive than what
    # Mix config already set. This prevents the default :info from
    # overriding config/test.exs {:logger, level: :warning}.
    current = Logger.level()

    if Logger.compare_levels(level, current) == :gt do
      Logger.configure(level: level)
    end

    :ok
  rescue
    # Options agent may not be running yet (e.g., during tests)
    _ -> :ok
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
    alias Minga.UI.Popup.Rule

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
