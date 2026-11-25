defmodule Minga.Config.Loader do
  @moduledoc """
  Discovers and evaluates config files and user modules at startup.

  ## Load order (both startup and reload)

  1. `~/.config/minga/modules/*.ex` (compile at OS-process startup; retain on reload)
  2. `~/.config/minga/themes/*.exs` (load user themes, before config eval)
  3. `~/.config/minga/config.exs` (global config)
  4. `.minga.exs` at the project root (project-local config)
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

  ## Project-local configuration

  A project can carry its own configuration: `.minga.exs` (evaluated as Elixir), `.minga/plugins` (plugin directories that are registered) and `.minga/mcp.json` (MCP servers, which are command lines Minga starts). All three are read from the project root the loader is given, never from the directory the VM runs in.

  The root is explicit data. At startup it is the project of what was launched (`Minga.CLI.startup_project_root/0`). On reload the editor passes its active project. With no project, nothing project-local is loaded.

  The root has to pass `Minga.Project.Trust.project_root/1`, the rule the Agent uses for its working folder: a folder as broad as the home directory or the filesystem root is a project only under version control. A root that is refused, or that does not resolve, loads nothing. `project_config/1` says which of these happened, and the editor prints it in `*Messages*`.
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
  alias Minga.Project.Sources
  alias Minga.Project.Trust
  alias Minga.Log
  alias Minga.Telemetry.StartupProgress

  @extracted_extensions [
    {:minga_adversarial, "minga-adversarial",
     [:adversarial_analyze, :adversarial_clear, :adversarial_cycle_skepticism]},
    {:minga_knowledge_graph, "minga-knowledge-graph",
     [:knowledge_briefing, :knowledge_map, :knowledge_heat_refresh]},
    {:minga_ghost_cursors, "minga-ghost-cursors", [:ghost_cursor_follow]}
  ]

  @type keymap_server :: Keymap.server()
  @type options_server :: Options.server()
  @typep user_module_mode :: :compile | {:reuse, [module()], [String.t()]}

  @typep inputs :: %{
           keymap_server: keymap_server(),
           options_server: options_server(),
           cleanup_callbacks: %{atom() => ContributionCleanup.cleanup_fun()} | nil,
           config_home: String.t() | nil,
           project_root: String.t() | nil
         }

  @typedoc """
  What happened to project-local configuration in the latest load.

  `:none` means no project was given. `{:loaded, root, files}` names the trusted root and the project-local files and folders that were found and read there, possibly none. `{:refused, reason}` means the root was not accepted as a project, so nothing was read from it.
  """
  @type project_config ::
          :none
          | {:loaded, root :: String.t(), files :: [String.t()], left_out :: [left_out()]}
          | {:refused, root :: String.t(), project_refusal()}

  @typedoc "A project-local file or folder that was found and not read, with the reason."
  @type left_out ::
          {path :: String.t(), Trust.code_refusal()}

  @typedoc """
  Why a whole project's configuration was left out.

  Besides the trust rule's reasons, `:extensions_need_restart` means the project declares extensions and is not the project Minga started with. Extensions are admitted once, when Minga starts.
  """
  @type project_refusal :: Trust.config_refusal() | :extensions_need_restart

  @typep load_report :: %{
           config_path: String.t(),
           load_error: String.t() | nil,
           config_eval_error: String.t() | nil,
           migration_notice: String.t() | nil,
           loaded_modules: [module()],
           modules_errors: [String.t()],
           modules_fingerprint: binary(),
           extension_declarations_fingerprint: binary(),
           project_config_path: String.t() | nil,
           project_config_error: String.t() | nil,
           project_config: project_config(),
           gui_settings_path: String.t(),
           gui_settings_error: String.t() | nil,
           after_error: String.t() | nil,
           lsp_settings: %{atom() => map()}
         }

  @typedoc """
  Loader state: runtime inputs, the latest load report, and the project Minga started with.

  `startup_project` keeps that project's root and the fingerprint of the extensions it declared, because those were admitted when the VM started and a reload cannot admit others.
  """
  @type state :: %{
          inputs: inputs(),
          report: load_report(),
          startup_project: %{root: String.t() | nil, declarations: binary()}
        }

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc """
  Starts the loader, compiles user modules, and evaluates all config files.

  When the loader is started under the application supervisor, the caller
  process is the supervisor, so the `:minga_config_keymap` process-dict
  fallback below reads the supervisor's pdict (effectively unset) and
  resolves to `Keymap.default_server/0`. To target a non-default server at
  boot, pass `:keymap_server` explicitly. The chosen keymap and options
  servers, cleanup callbacks, and configured home are retained across reloads.
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

    inputs = %{
      keymap_server: keymap_server,
      options_server: options_server,
      cleanup_callbacks: Keyword.get(opts, :cleanup_callbacks),
      config_home: Keyword.get(opts, :config_home),
      project_root: Keyword.get(opts, :project_root)
    }

    artifact_admission = Keyword.get(opts, :artifact_admission, ArtifactAdmission)

    Agent.start_link(
      fn ->
        project = trusted_project(inputs.project_root)

        report =
          StartupProgress.during_config_load(fn ->
            load_all(inputs, Minga.SafeMode.active?(), :compile, project)
          end)

        :ok =
          maybe_seal_artifact_generation(
            artifact_admission,
            Application.get_env(:minga, :seal_extension_artifact_generation, true)
          )

        %{
          inputs: inputs,
          report: report,
          startup_project: %{
            root: project_identity(project, inputs.project_root),
            declarations: declarations_fingerprint(project_declarations(project))
          }
        }
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
  def config_path(server), do: Agent.get(server, & &1.report.config_path)

  @doc """
  Returns the last global config load error, or `nil` if config loaded cleanly
  (or no config file exists).
  """
  @spec load_error() :: String.t() | nil
  @spec load_error(GenServer.server()) :: String.t() | nil
  def load_error, do: load_error(__MODULE__)
  def load_error(server), do: Agent.get(server, & &1.report.load_error)

  @doc """
  Returns why the global config file did not evaluate in the loaded config, or `nil` when it evaluated (or does not exist).

  Unlike `load_error/1`, this is only the failure that leaves the editor on its defaults: project config, MCP, plugin and extension errors are not in it, and a reload the loader rejects does not change it, because the last loaded config stays in place.
  """
  @spec config_eval_error() :: String.t() | nil
  @spec config_eval_error(GenServer.server()) :: String.t() | nil
  def config_eval_error, do: config_eval_error(__MODULE__)
  def config_eval_error(server), do: Agent.get(server, & &1.report.config_eval_error)

  @doc "Returns the startup notice for saved bindings that need an opt-in extension."
  @spec migration_notice() :: String.t() | nil
  @spec migration_notice(GenServer.server()) :: String.t() | nil
  def migration_notice(server \\ __MODULE__), do: Agent.get(server, & &1.report.migration_notice)

  @doc false
  @spec record_config_binding(atom()) :: :ok
  def record_config_binding(command) do
    if bindings = Process.get(:minga_config_bound_commands) do
      Process.put(:minga_config_bound_commands, MapSet.put(bindings, command))
    end

    :ok
  end

  @doc "Returns the list of modules compiled from the user's modules directory."
  @spec loaded_modules() :: [module()]
  @spec loaded_modules(GenServer.server()) :: [module()]
  def loaded_modules, do: loaded_modules(__MODULE__)
  def loaded_modules(server), do: Agent.get(server, & &1.report.loaded_modules)

  @doc "Returns compilation errors from user modules, or an empty list if all compiled cleanly."
  @spec modules_errors() :: [String.t()]
  @spec modules_errors(GenServer.server()) :: [String.t()]
  def modules_errors, do: modules_errors(__MODULE__)
  def modules_errors(server), do: Agent.get(server, & &1.report.modules_errors)

  @doc "Returns the project-local config load error, or `nil` if clean (or no project config)."
  @spec project_config_error() :: String.t() | nil
  @spec project_config_error(GenServer.server()) :: String.t() | nil
  def project_config_error, do: project_config_error(__MODULE__)
  def project_config_error(server), do: Agent.get(server, & &1.report.project_config_error)

  @doc "Returns the generated GUI settings overlay path."
  @spec gui_settings_path() :: String.t()
  @spec gui_settings_path(GenServer.server()) :: String.t()
  def gui_settings_path, do: gui_settings_path(__MODULE__)

  def gui_settings_path(server) when is_atom(server) do
    case Process.whereis(server) do
      nil -> default_gui_settings_path()
      _pid -> Agent.get(server, & &1.report.gui_settings_path)
    end
  end

  def gui_settings_path(server), do: Agent.get(server, & &1.report.gui_settings_path)

  @doc "Returns the gui_settings.exs load error, or `nil` if clean (or no GUI overlay)."
  @spec gui_settings_error() :: String.t() | nil
  @spec gui_settings_error(GenServer.server()) :: String.t() | nil
  def gui_settings_error, do: gui_settings_error(__MODULE__)
  def gui_settings_error(server), do: Agent.get(server, & &1.report.gui_settings_error)

  @doc "Returns the after.exs load error, or `nil` if clean (or no after.exs)."
  @spec after_error() :: String.t() | nil
  @spec after_error(GenServer.server()) :: String.t() | nil
  def after_error, do: after_error(__MODULE__)
  def after_error(server), do: Agent.get(server, & &1.report.after_error)

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

  def reload(server), do: reload_project(server, :same)

  @doc """
  Reloads config with `project_root` as the project whose configuration is read.

  The editor passes its active project, which may differ from the one the VM started with. `nil` means no project: nothing project-local is loaded.
  """
  @spec reload(GenServer.server(), String.t() | nil) :: :ok | {:error, String.t()}
  def reload(server, project_root) when is_binary(project_root) or is_nil(project_root),
    do: reload_project(server, {:root, project_root})

  @spec reload_project(GenServer.server(), :same | {:root, String.t() | nil}) ::
          :ok | {:error, String.t()}
  defp reload_project(server, target) do
    Writer.set_reloading(true)

    try do
      do_reload(server, target)
    after
      Writer.set_reloading(false)
    end
  end

  @doc "Says what the latest load did with project-local configuration."
  @spec project_config() :: project_config()
  @spec project_config(GenServer.server()) :: project_config()
  def project_config, do: project_config(__MODULE__)
  def project_config(server), do: Agent.get(server, & &1.report.project_config)

  @doc """
  The directory a process started because of config runs in, or `nil` when no project's config is in effect.

  It is the canonical root of the project the latest load used: the project that was launched, or the one that was open at the last reload. A hook acts on the project, so a relative path in its command line means "in the project". It must not depend on the directory Minga itself happens to run in, which is the source tree for a source build and whatever the shell was in for a release.
  """
  @spec project_directory() :: String.t() | nil
  @spec project_directory(GenServer.server()) :: String.t() | nil
  def project_directory(server \\ __MODULE__) do
    case project_config(server) do
      {:loaded, root, _files, _left_out} -> if File.dir?(root), do: root
      _none_or_refused -> nil
    end
  catch
    :exit, _loader_not_running -> nil
  end

  @doc "The line for `*Messages*` about project-local configuration, or `nil` when there is nothing to say."
  @spec project_config_message(project_config()) :: String.t() | nil
  def project_config_message(:none), do: nil
  def project_config_message({:loaded, _root, [], []}), do: nil

  def project_config_message({:loaded, root, files, left_out}) do
    folder = Minga.Project.collapse_home(root)

    [loaded_line(folder, root, files), left_out_line(folder, root, left_out)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  def project_config_message({:refused, root, reason}) do
    folder = Minga.Project.collapse_home(root)

    "Project config in #{folder} not loaded: #{refusal_text(reason, refused_name(reason, folder))}"
  end

  # The folder the rule judged, which is where a link leads, not the link's own name.
  @spec refused_name(project_refusal(), String.t()) :: String.t()
  defp refused_name({kind, path}, _folder)
       when kind in [:too_broad, :not_yours, :writable_by_others, :writable_by_group],
       do: Minga.Project.collapse_home(path)

  defp refused_name(_reason, folder), do: folder

  @spec loaded_line(String.t(), String.t(), [String.t()]) :: String.t() | nil
  defp loaded_line(_folder, _root, []), do: nil

  defp loaded_line(folder, root, files),
    do: "Project config loaded from #{folder}: #{relative_names(files, root)}."

  @spec left_out_line(String.t(), String.t(), [left_out()]) :: String.t() | nil
  defp left_out_line(_folder, _root, []), do: nil

  defp left_out_line(folder, root, left_out) do
    parts =
      Enum.map_join(left_out, "; ", fn {path, reason} ->
        "#{relative_names([path], root)} (#{refusal_text(reason, Path.relative_to(path, root))})"
      end)

    "Not loaded from #{folder}: #{parts}"
  end

  @spec relative_names([String.t()], String.t()) :: String.t()
  defp relative_names(paths, root), do: Enum.map_join(paths, ", ", &Path.relative_to(&1, root))

  # Each refusal says what is wrong and what makes it loadable. The trust rule's own reasons are worded in
  # `Minga.Project.Trust`, in one place for every loader.
  @spec refusal_text(project_refusal() | Trust.code_refusal(), String.t()) :: String.t()
  defp refusal_text(:extensions_need_restart, name),
    do:
      "it declares extensions or has plugins, and those load only when Minga starts. " <>
        "Start Minga in #{name} to use its config."

  defp refusal_text(reason, name), do: Trust.explain(reason, name)

  @spec do_reload(GenServer.server(), :same | {:root, String.t() | nil}) ::
          :ok | {:error, String.t()}
  defp do_reload(server, target) do
    %{report: report, inputs: inputs, startup_project: startup} = state = Agent.get(server, & &1)
    root = target_root(target, inputs.project_root)

    with nil <- user_module_restart_required(report),
         nil <- global_declaration_restart_required(report),
         {:ok, project} <- admit_project(trusted_project(root), root, startup) do
      # The new root becomes the loader's project only now that the reload is admitted.
      admitted = %{state | inputs: %{inputs | project_root: root}}
      reload_current_extension_generation(server, admitted, project)
    else
      message when is_binary(message) -> reject_reload(server, message)
    end
  end

  @spec target_root(:same | {:root, String.t() | nil}, String.t() | nil) :: String.t() | nil
  defp target_root(:same, current), do: current
  defp target_root({:root, root}, _current), do: root

  # Extensions are admitted once, when the VM starts, for the project it started with.
  # That project must still declare what it declared then, or Minga has to restart.
  # Another project loads on reload only if it declares none and has no plugins.
  # Otherwise its config is left out, and only its config. Nothing of it is compiled.
  @spec admit_project(trusted_project(), String.t() | nil, %{
          root: String.t() | nil,
          declarations: binary()
        }) :: {:ok, trusted_project()} | String.t()
  defp admit_project(project, root, %{root: startup_root, declarations: admitted}) do
    if project_identity(project, root) == startup_root,
      do: admit_startup_project(project, admitted),
      else: admit_other_project(project)
  end

  @spec admit_startup_project(trusted_project(), binary()) ::
          {:ok, trusted_project()} | String.t()
  defp admit_startup_project(project, admitted) do
    if declarations_fingerprint(project_declarations(project)) == admitted,
      do: {:ok, project},
      else: "Extension declarations changed; restart Minga before config reload"
  end

  @spec admit_other_project(trusted_project()) :: {:ok, trusted_project()}
  defp admit_other_project(project) do
    # A plugin is an extension too: it would be compiled now and refused afterwards, so it is not started at all.
    if not declares_extensions?(project_declarations(project)) and
         project_plugin_names(project) == [],
       do: {:ok, project},
       else: {:ok, {:error, :extensions_need_restart}}
  end

  # Which project this is, whatever spelling of its path the caller used.
  # A usable project is known by its canonical root, any other by the path as given.
  # The editor's name for the open project can differ from the name Minga was started with (a link, `/tmp`).
  @spec project_identity(trusted_project(), String.t() | nil) :: String.t() | nil
  defp project_identity({:ok, %Sources{root: canonical}}, _root), do: canonical
  defp project_identity(_refused_or_none, root), do: root

  # A config file that does not parse declares nothing: evaluating it reports the error and registers nothing.
  # A file whose declarations cannot be read off its source might declare anything, so it counts.
  @spec declares_extensions?([term()]) :: boolean()
  defp declares_extensions?(declarations) do
    Enum.any?(declarations, fn
      {_path, {:invalid_config, _hash}} -> false
      _declaration -> true
    end)
  end

  @spec project_plugin_names(trusted_project()) :: [String.t()]
  defp project_plugin_names({:ok, %Sources{} = sources}), do: Sources.plugin_names(sources)
  defp project_plugin_names(_no_trusted_project), do: []

  @spec reload_current_extension_generation(GenServer.server(), state(), trusted_project()) ::
          :ok | {:error, String.t()}
  defp reload_current_extension_generation(server, state, project) do
    case ExtSupervisor.pending_artifact_restarts(Minga.Extension.Registry) do
      [] ->
        do_reload_unchanged_generation(server, state, project)

      changed ->
        names = Enum.map_join(changed, ", ", &Atom.to_string/1)
        reject_reload(server, "Extension restart required before config reload: #{names}")
    end
  end

  @spec user_module_restart_required(load_report()) :: String.t() | nil
  defp user_module_restart_required(%{
         config_path: config_path,
         modules_fingerprint: admitted_fingerprint
       }) do
    current_fingerprint = user_modules_fingerprint(Path.dirname(config_path))

    if current_fingerprint == admitted_fingerprint do
      nil
    else
      "User module restart required before config reload"
    end
  end

  @spec global_declaration_restart_required(load_report()) :: String.t() | nil
  defp global_declaration_restart_required(%{
         config_path: config_path,
         gui_settings_path: gui_settings_path,
         extension_declarations_fingerprint: admitted_fingerprint
       }) do
    if extension_declarations_fingerprint(config_path, gui_settings_path) == admitted_fingerprint,
      do: nil,
      else: "Extension declarations changed; restart Minga before config reload"
  end

  # The extension declarations of the global sources: the config file, the GUI settings and the post-init hook.
  @spec extension_declarations_fingerprint(String.t(), String.t()) :: binary()
  defp extension_declarations_fingerprint(config_path, gui_settings_path) do
    after_path = Path.join(Path.dirname(config_path), "after.exs")

    [config_path, gui_settings_path, after_path]
    |> Enum.flat_map(&extension_declarations/1)
    |> declarations_fingerprint()
  end

  # A relative `path:` resolves against the file that declares it, which is part of each declaration.
  # The directory the VM runs in plays no part.
  @spec declarations_fingerprint([term()]) :: binary()
  defp declarations_fingerprint(declarations),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(declarations))

  # What a project's own config declares. A project that is refused or absent declares nothing.
  @spec project_declarations(trusted_project()) :: [term()]
  defp project_declarations({:ok, %Sources{config: {:ok, %{path: path, content: content}}}}),
    do: extension_declarations(path, content)

  # A file the load refuses, or a project that is refused or absent, declares nothing.
  defp project_declarations(_no_usable_config), do: []

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
        declarations =
          ast
          |> Macro.prewalker()
          |> Enum.reduce_while([], fn
            {:extension, _meta, [name, opts]}, acc ->
              collect_extension_declaration(path, name, opts, acc)

            {:extension, _meta, [module]}, acc ->
              collect_extension_declaration(path, module, [], acc)

            {{:., _dot_meta, [_receiver, :extension]}, _meta, [name, opts]}, acc ->
              collect_extension_declaration(path, name, opts, acc)

            {{:., _dot_meta, [_receiver, :extension]}, _meta, [module]}, acc ->
              collect_extension_declaration(path, module, [], acc)

            _node, acc ->
              {:cont, acc}
          end)

        case declarations do
          :dynamic -> [{path, {:dynamic_source_file, :crypto.hash(:sha256, source)}}]
          literals -> Enum.reverse(literals)
        end

      {:error, _reason} ->
        [{path, {:invalid_config, :crypto.hash(:sha256, source)}}]
    end
  end

  @spec collect_extension_declaration(String.t(), Macro.t(), Macro.t(), [term()]) ::
          {:cont, [term()]} | {:halt, :dynamic}
  defp collect_extension_declaration(path, name, opts, declarations) do
    case extension_source_identity(name, opts) do
      {:ok, identity} -> {:cont, [{path, identity} | declarations]}
      :dynamic -> {:halt, :dynamic}
    end
  end

  @spec extension_source_identity(Macro.t(), Macro.t()) :: {:ok, term()} | :dynamic
  defp extension_source_identity(name_ast, opts) do
    if Keyword.keyword?(opts) do
      with {:ok, name} <- extension_name_identity(name_ast) do
        source_identity(name, opts)
      end
    else
      :dynamic
    end
  end

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
    Agent.update(server, fn %{report: report} = state ->
      %{state | report: %{report | load_error: message}}
    end)

    {:error, message}
  end

  @spec do_reload_unchanged_generation(GenServer.server(), state(), trusted_project()) ::
          :ok | {:error, String.t()}
  defp do_reload_unchanged_generation(server, %{inputs: inputs, report: report}, project) do
    # Stop all running extensions first. If that fails, do not tear down
    # registries or start a new load, because the old extension tree is still
    # partially live and a reset would orphan it.
    case stop_all_extensions(inputs.cleanup_callbacks) do
      nil ->
        # Reset all registries to defaults while preserving this VM's admitted user modules.
        maybe_reset_options(inputs.options_server)
        Hooks.reset()
        Advice.reset()
        Keymap.reset(inputs.keymap_server)
        Command.reset_registry()
        ExtRegistry.reset()
        PopupRegistry.clear()
        ModelineSegments.reset_warnings()

        # Reload deliberately ignores startup safe mode so fixed config can be loaded without restarting.
        new_report =
          load_all(inputs, false, {:reuse, report.loaded_modules, report.modules_errors}, project)

        Agent.update(server, &%{&1 | report: new_report, inputs: inputs})
        reload_result(new_report)

      message ->
        reject_reload(server, message)
    end
  end

  @spec reload_result(load_report()) :: :ok | {:error, String.t()}
  defp reload_result(report) do
    errors =
      [
        report.load_error,
        report.project_config_error,
        report.gui_settings_error,
        report.after_error
      ]
      |> Enum.reject(&is_nil/1)

    case report.modules_errors ++ errors do
      [] -> :ok
      messages -> {:error, Enum.join(messages, "; ")}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  # The process dictionary bridges per-loader state into config DSL functions,
  # which run synchronously while `.exs` configs evaluate. Code that calls those
  # helpers from a separate process (e.g., a GenServer started by an extension
  # callback) won't see this dict and will fall back to registered defaults.
  # Extensions are skipped in test mode, so this only affects long-lived runtime
  # callers.
  @spec load_all(inputs(), boolean(), user_module_mode(), trusted_project()) :: load_report()
  defp load_all(inputs, safe_mode?, user_module_mode, project) when is_boolean(safe_mode?) do
    %{keymap_server: keymap_server, options_server: options_server} = inputs
    previous_keymap_server = Process.put(:minga_config_keymap, keymap_server)
    previous_options_server = Process.put(:minga_config_options, options_server)
    previous_lsp_settings = Process.put(:minga_config_lsp_settings, %{})
    previous_bound_commands = Process.put(:minga_config_bound_commands, MapSet.new())

    try do
      config_cleanup_error =
        cleanup_source_owned_config_contributions(keymap_server, inputs.cleanup_callbacks)

      config_path = resolve_config_path(inputs.config_home)
      config_dir = Path.dirname(config_path)

      # 0. Register default popup rules (before user config so overrides work)
      register_default_popup_rules()

      if safe_mode? do
        safe_mode_report(config_path, config_dir)
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

        config_eval_error =
          case {custom_config?, File.exists?(config_path)} do
            {true, false} ->
              "Custom config not found: #{config_path} (using defaults)"

            _ ->
              eval_if_exists(config_path)
          end

        load_error =
          if custom_config? and config_eval_error == nil and
               not String.ends_with?(config_path, ".exs") do
            "Custom config path does not end in .exs: #{config_path} (file was loaded, but may not be valid Elixir)"
          else
            config_eval_error
          end

        StartupTimer.mark(:config_global_eval)

        # 4. Eval project-local config, from the project root the loader was given and only if it is trusted.
        project_file = eval_project_config(project)
        project_mcp = load_project_mcp_json(project)
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

        # 8. Discover plugins and start extensions after every config source has declared them.
        {project_plugins, plugin_error} =
          discover_and_register_plugins(inputs.config_home, project)

        start_all_error =
          if Process.whereis(Minga.Extension.RootSupervisor) != nil &&
               Application.get_env(:minga, :load_extensions, true) do
            start_all_extensions(inputs.cleanup_callbacks)
          end

        StartupTimer.mark(:config_extensions_started)

        load_error =
          merge_error_messages([
            config_cleanup_error,
            load_error,
            project_part_error(project_mcp),
            plugin_error,
            start_all_error
          ])

        lsp_settings = Process.get(:minga_config_lsp_settings, %{})

        %{
          config_path: config_path,
          load_error: load_error,
          config_eval_error: config_eval_error,
          migration_notice: extension_migration_notice(),
          loaded_modules: loaded_modules,
          modules_errors: modules_errors,
          modules_fingerprint: modules_fingerprint,
          extension_declarations_fingerprint:
            extension_declarations_fingerprint(config_path, gui_settings_path),
          project_config_path: project_part_path(project_file),
          project_config_error: project_part_error(project_file),
          project_config:
            project_config(inputs.project_root, project, [
              project_file,
              project_mcp,
              project_plugins
            ]),
          gui_settings_path: gui_settings_path,
          gui_settings_error: gui_settings_error,
          after_error: after_error,
          lsp_settings: lsp_settings
        }
      end
    after
      restore_pdict(:minga_config_keymap, previous_keymap_server)
      restore_pdict(:minga_config_options, previous_options_server)
      restore_pdict(:minga_config_lsp_settings, previous_lsp_settings)
      restore_pdict(:minga_config_bound_commands, previous_bound_commands)
    end
  end

  @spec safe_mode_report(String.t(), String.t()) :: load_report()
  defp safe_mode_report(config_path, config_dir) do
    gui_settings_path = Path.join(config_dir, "gui_settings.exs")

    %{
      config_path: config_path,
      load_error: nil,
      config_eval_error: nil,
      migration_notice: nil,
      loaded_modules: [],
      modules_errors: [],
      modules_fingerprint: user_modules_fingerprint(config_dir),
      extension_declarations_fingerprint:
        extension_declarations_fingerprint(config_path, gui_settings_path),
      project_config_path: nil,
      project_config_error: nil,
      project_config: :none,
      gui_settings_path: gui_settings_path,
      gui_settings_error: nil,
      after_error: nil,
      lsp_settings: %{}
    }
  end

  @spec extension_migration_notice() :: String.t() | nil
  defp extension_migration_notice do
    bindings = Process.get(:minga_config_bound_commands)

    installs =
      for {name, repo, commands} <- @extracted_extensions,
          Enum.any?(commands, &MapSet.member?(bindings, &1)),
          ExtRegistry.get(name) == :error,
          do: "extension #{inspect(name)}, git: \"https://github.com/jsmestad/#{repo}\""

    case installs do
      [] ->
        nil

      _ ->
        "Some configured keybindings need optional extensions. Add to config.exs and restart: #{Enum.join(installs, "; ")}"
    end
  end

  # ── Plugin Discovery ──────────────────────────────────────────────────────────

  # Returns what happened to the project's plugin folder, so the report can name it, and the merged errors.
  @spec discover_and_register_plugins(String.t() | nil, trusted_project()) ::
          {project_part(), String.t() | nil}
  defp discover_and_register_plugins(config_home, project) do
    user_errors = register_plugins_from_dir(user_plugins_dir(config_home))
    project_plugins = register_project_plugins(project)

    {project_plugins,
     merge_error_messages(user_errors ++ List.wrap(project_part_error(project_plugins)))}
  end

  # A plugin is code Minga loads, so the folder and each plugin in it must be the user's own.
  # Each is resolved to its canonical path first, and that path is what gets registered.
  @spec register_project_plugins(trusted_project()) :: project_part()
  defp register_project_plugins(
         {:ok, %Sources{plugins: {:ok, %{folder: folder, plugins: plugins}}}}
       ) do
    errors = Enum.reduce(plugins, [], &register_project_plugin/2)
    {:loaded, folder, merge_error_messages(errors)}
  end

  defp register_project_plugins({:ok, %Sources{plugins: {:refused, dir, reason}}}),
    do: {:refused, dir, reason}

  defp register_project_plugins(_absent_or_no_trusted_project), do: :absent

  # The canonical root that was examined is what gets registered.
  @spec register_project_plugin(Sources.plugin(), [String.t()]) :: [String.t()]
  defp register_project_plugin({name, {:ok, canonical}}, errors),
    do: register_plugin_entry(canonical, name, errors)

  defp register_project_plugin({name, {:error, reason}}, errors),
    do: ["Plugin #{name} not loaded: #{Trust.explain(reason)}" | errors]

  @spec user_plugins_dir(String.t() | nil) :: String.t()
  defp user_plugins_dir(config_home) do
    Path.join(config_dir(config_home), "plugins")
  end

  # The project root as the trust rule sees it: accepted with its canonical path and the account that must own
  # what is read from it, refused, or absent.
  @typep trusted_project :: {:ok, Sources.t()} | {:error, project_refusal()} | :none

  # What happened to one project-local file or folder.
  @typep project_part ::
           :absent
           | {:loaded, String.t(), error :: String.t() | nil}
           | {:refused, String.t(), Trust.code_refusal()}

  # `Minga.Project.Sources` examines the root and everything in it once. The load uses what it returns.
  @spec trusted_project(String.t() | nil) :: trusted_project()
  defp trusted_project(nil), do: :none
  defp trusted_project(root) when is_binary(root), do: Sources.admit(root)

  @spec project_config(String.t() | nil, trusted_project(), [project_part()]) :: project_config()
  defp project_config(_root, :none, _parts), do: :none
  defp project_config(root, {:error, reason}, _parts), do: {:refused, root, reason}

  defp project_config(_root, {:ok, %Sources{root: canonical}}, parts) do
    loaded = for {:loaded, path, _error} <- parts, do: path
    left_out = for {:refused, path, reason} <- parts, do: {path, reason}
    {:loaded, canonical, loaded, left_out}
  end

  @spec project_part_path(project_part()) :: String.t() | nil
  defp project_part_path({:loaded, path, _error}), do: path
  defp project_part_path(_absent_or_refused), do: nil

  @spec project_part_error(project_part()) :: String.t() | nil
  defp project_part_error({:loaded, _path, error}), do: error
  defp project_part_error(_absent_or_refused), do: nil

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
    Agent.get(server, & &1.report.lsp_settings)
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
    {rev_mods, rev_errs} =
      files
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.sort()
      |> Enum.reduce({[], []}, fn file, {rev_mods, rev_errs} ->
        path = Path.join(modules_dir, file)

        case compile_module(path) do
          {:ok, modules} -> {Enum.reverse(modules, rev_mods), rev_errs}
          {:error, msg} -> {rev_mods, [msg | rev_errs]}
        end
      end)

    {Enum.reverse(rev_mods), Enum.reverse(rev_errs)}
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
    Path.join(config_dir(config_home), "config.exs")
  end

  @spec config_dir(String.t() | nil) :: String.t()
  defp config_dir(config_home) when is_binary(config_home), do: Path.join(config_home, "minga")
  defp config_dir(nil), do: Minga.UserPaths.config_dir!()

  @spec load_project_mcp_json(trusted_project()) :: project_part()
  defp load_project_mcp_json(
         {:ok, %Sources{mcp: {:ok, %{path: path, content: content}}} = sources}
       ),
       do: {:loaded, path, parse_project_mcp_json(content, path, sources)}

  defp load_project_mcp_json({:ok, %Sources{mcp: {:refused, path, reason}}}),
    do: {:refused, path, reason}

  defp load_project_mcp_json(_absent_or_no_trusted_project), do: :absent

  @spec eval_project_config(trusted_project()) :: project_part()
  defp eval_project_config(
         {:ok, %Sources{config: {:ok, %{path: path, content: content}}} = sources}
       ),
       do: {:loaded, path, eval_project_source(content, path, sources)}

  defp eval_project_config({:ok, %Sources{config: {:refused, path, reason}}}),
    do: {:refused, path, reason}

  defp eval_project_config(_absent_or_no_trusted_project), do: :absent

  # While a project's config is evaluated, an `extension ..., path:` it declares is held to the ownership rule
  # too (`Minga.Config`): the account that must own those sources travels in the process dictionary.
  # The MCP servers and hooks the file adds are processes the project declares. They are picked out afterwards,
  # by comparing the options before and after, and go through `declared_by_project/3`.
  @spec eval_project_source(binary(), String.t(), Sources.t()) :: String.t() | nil
  defp eval_project_source(source, path, %Sources{} = sources) do
    previous = Process.put(:minga_config_owner, {:owner, sources.user_id})
    options = Process.get(:minga_config_options, Options.default_server())
    servers_before = Options.get(options, :agent_mcp_servers)
    hooks_before = Options.get(options, :agent_hooks)

    try do
      error = eval_config_source(source, path)
      declared = declared_by_project(options, {servers_before, hooks_before}, sources)
      merge_error_messages([error | declared])
    after
      restore_pdict(:minga_config_owner, previous)
    end
  end

  # An entry that was there before the project's file ran is the user's own. Every other entry is the project's:
  # a server is started from the program `Sources.process/5` returns, in the project root, and a hook runs there.
  @spec declared_by_project(GenServer.server(), {term(), term()}, Sources.t()) :: [String.t()]
  defp declared_by_project(options, {servers_before, hooks_before}, sources) do
    {servers, refused} =
      options
      |> Options.get(:agent_mcp_servers)
      |> List.wrap()
      |> Enum.map_reduce([], fn server, refused ->
        if server in List.wrap(servers_before),
          do: {server, refused},
          else: project_server_entry(server, sources, refused)
      end)

    hooks =
      options
      |> Options.get(:agent_hooks)
      |> List.wrap()
      |> Enum.map(fn hook ->
        if hook in List.wrap(hooks_before), do: hook, else: project_hook_entry(hook, sources)
      end)

    [
      set_option_error(options, :agent_mcp_servers, Enum.reject(servers, &is_nil/1)),
      set_option_error(options, :agent_hooks, hooks)
      | Enum.reverse(refused)
    ]
  end

  @spec set_option_error(GenServer.server(), atom(), term()) :: String.t() | nil
  defp set_option_error(options, name, value) do
    if Options.get(options, name) == value do
      nil
    else
      case Options.set(options, name, value) do
        {:ok, _value} -> nil
        {:error, message} -> message
      end
    end
  end

  @spec project_server_entry(term(), Sources.t(), [String.t()]) :: {map() | nil, [String.t()]}
  defp project_server_entry(server, sources, refused) do
    with {:ok, %MingaAgent.MCP.ServerConfig{} = config} <-
           MingaAgent.MCP.ServerConfig.normalize(server),
         {:ok, started} <- project_server(config, sources) do
      {Map.from_struct(started), refused}
    else
      {:error, reason} when is_binary(reason) -> {nil, [reason | refused]}
      _not_a_server -> {nil, ["MCP server entry not loaded: #{inspect(server)}" | refused]}
    end
  end

  @spec project_server(MingaAgent.MCP.ServerConfig.t(), Sources.t(), {[map()], [String.t()]}) ::
          {[map()], [String.t()]}
  defp project_server(server, sources, {started, refused}) do
    case project_server(server, sources) do
      {:ok, server} -> {[Map.from_struct(server) | started], refused}
      {:error, message} -> {started, [message | refused]}
    end
  end

  # The program and the working directory come from the owner, never from the project's own data.
  @spec project_server(MingaAgent.MCP.ServerConfig.t(), Sources.t()) ::
          {:ok, MingaAgent.MCP.ServerConfig.t()} | {:error, String.t()}
  defp project_server(%MingaAgent.MCP.ServerConfig{} = server, %Sources{} = sources) do
    case Sources.process(sources, server.command, server.args, server.env) do
      {:ok, process} ->
        {:ok, MingaAgent.MCP.ServerConfig.started_from(server, process.executable, process.cwd)}

      {:error, reason} ->
        {:error, "MCP server #{server.name} not loaded: #{Trust.explain(reason)}"}
    end
  end

  # A hook is one shell line that Minga's own hook runner starts, so there is no program of the project's to
  # judge. What Minga decides is where it runs: in the project root.
  @spec project_hook_entry(term(), Sources.t()) :: term()
  defp project_hook_entry(hook, %Sources{root: root}) when is_map(hook),
    do: hook |> Map.delete("cwd") |> Map.put(:cwd, root)

  defp project_hook_entry(hook, %Sources{root: root}) when is_list(hook) do
    if Keyword.keyword?(hook), do: Keyword.put(hook, :cwd, root), else: hook
  end

  defp project_hook_entry(hook, _sources), do: hook

  @spec parse_project_mcp_json(binary(), String.t(), Sources.t()) :: String.t() | nil
  defp parse_project_mcp_json(content, path, sources) do
    case JSON.decode(content) do
      {:ok, decoded} -> register_project_mcp_servers(decoded, sources)
      {:error, reason} -> "#{path}: invalid JSON: #{inspect(reason)}"
    end
  end

  @spec register_project_mcp_servers(term(), Sources.t()) :: String.t() | nil
  defp register_project_mcp_servers(%{"mcpServers" => servers}, sources) when is_map(servers) do
    case normalize_project_mcp_server_entries(servers) do
      {:ok, entries} -> append_project_mcp_servers(entries, sources)
      {:error, reason} -> reason
    end
  end

  defp register_project_mcp_servers(%{"servers" => servers}, sources) when is_list(servers),
    do: append_project_mcp_servers(servers, sources)

  defp register_project_mcp_servers(servers, sources) when is_list(servers),
    do: append_project_mcp_servers(servers, sources)

  defp register_project_mcp_servers(_decoded, _sources) do
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

  @spec append_project_mcp_servers([map()], Sources.t()) :: String.t() | nil
  defp append_project_mcp_servers(servers, sources) do
    case MingaAgent.MCP.ServerConfig.normalize_list(servers) do
      {:ok, normalized} ->
        {started, refused} =
          Enum.reduce(Enum.reverse(normalized), {[], []}, &project_server(&1, sources, &2))

        options = Process.get(:minga_config_options, Options.default_server())
        existing = Options.get(options, :agent_mcp_servers)

        case Options.set(options, :agent_mcp_servers, existing ++ started) do
          {:ok, _servers} -> merge_error_messages(refused)
          {:error, message} -> merge_error_messages([message | refused])
        end

      {:error, reason} ->
        reason
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
  defp eval_config_file(path), do: eval_config(path, fn -> Code.eval_file(path) end)

  # Evaluates content that was already read, under the name of the file it came from.
  @spec eval_config_source(binary(), String.t()) :: String.t() | nil
  defp eval_config_source(source, path),
    do: eval_config(path, fn -> Code.eval_string(source, [], file: path) end)

  @spec eval_config(String.t(), (-> term())) :: String.t() | nil
  defp eval_config(path, evaluate) do
    # A relative `extension ..., path:` in this file resolves against the file's own folder (`Minga.Config`).
    previous = Process.put(:minga_config_file, path)

    try do
      evaluate.()
      nil
    after
      restore_pdict(:minga_config_file, previous)
    end
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
