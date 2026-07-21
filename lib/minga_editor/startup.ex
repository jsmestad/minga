defmodule MingaEditor.Startup do
  @moduledoc """
  Editor initialization helpers.

  Pure functions and process-spawning helpers used by `MingaEditor.init/1`.
  Extracted to keep the GenServer module focused on message handling.
  """

  # ShellState defaults include MapSet.new() which dialyzer flags as opaque
  # when flowing through bare-map pattern matches in accessor functions.
  @dialyzer {:no_opaque, build_initial_state: 1}

  alias MingaEditor.Agent.UIState
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Handlers.SessionRestore
  alias Minga.Log
  alias Minga.Config
  alias MingaEditor.Commands
  alias MingaEditor.FileTree.Feature, as: FileTreeFeature
  alias MingaEditor.FileWatcherHelpers
  alias MingaEditor.Shell.Runtime, as: ShellRuntime
  alias MingaEditor.Sidebar.BuiltinSurfaces
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentConnection
  alias MingaEditor.State.ExtensionSurfaces
  alias MingaEditor.State.Frontend, as: FrontendState
  alias MingaEditor.State.Interaction
  alias MingaEditor.State.Parser, as: ParserState
  alias MingaEditor.State.Render, as: RenderState
  alias MingaEditor.State.Session, as: EditorSessionState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace.Persistence, as: WorkspacePersistence
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias Minga.Config.Options

  @doc "Runs the one-time startup work (swap recovery, agent session, save timer) exactly once per session."
  @spec ensure_session_started(EditorState.t()) :: EditorState.t()
  def ensure_session_started(
        %EditorState{session: %EditorSessionState{session_started?: true}} = state
      ),
      do: state

  def ensure_session_started(%EditorState{} = state) do
    SessionRestore.maybe_check_swap_recovery(state)

    state = AgentLifecycle.maybe_start_session(state)

    %{
      state
      | session:
          MingaEditor.State.Session.complete_startup(state.session, maybe_start_save_timer(state))
    }
  end

  @spec maybe_start_save_timer(EditorState.t()) :: EditorSessionState.t()
  defp maybe_start_save_timer(%EditorState{
         frontend: %FrontendState{backend: :headless},
         session: session
       }),
       do: session

  defp maybe_start_save_timer(%EditorState{session: session}) do
    case EditorSessionState.start_timer(session) do
      {:no_timer, session} ->
        session

      {:start_timer, session} ->
        ref = Process.send_after(self(), :save_session, EditorSessionState.timer_interval())
        EditorSessionState.accept_timer(session, ref)
    end
  end

  @doc """
  Builds the complete initial EditorState from startup opts.

  Subscribes to port manager and parser, starts special buffers,
  determines the startup mode (agent vs editor), and creates the
  correct window type in a single pass.

  In agent mode the initial window is an agent chat window (full screen).
  In editor mode it's a regular buffer window showing the file buffer
  (or a blank buffer if no file was specified). The mode decision happens *before* window creation so
  there's no create-then-replace dance.
  """
  @spec build_initial_state(keyword()) :: EditorState.t()
  def build_initial_state(opts) do
    backend = Keyword.get(opts, :backend, :headless)
    rendering = rendering_policy(opts)
    port_manager = Keyword.get(opts, :port_manager, MingaEditor.Frontend.Manager)
    parser_manager = Keyword.get(opts, :parser_manager, Minga.Parser.Manager)
    keymap_server = Keyword.get(opts, :keymap_server, Minga.Keymap.default_server())
    events_registry = Keyword.get(opts, :events_registry, Minga.Events.default_registry())

    sidebar_registry =
      Keyword.get(opts, :sidebar_registry, MingaEditor.Extension.Sidebar.default_table())

    options_server =
      case Keyword.get(opts, :options_server, Options.default_server()) do
        nil -> Options.default_server()
        server -> Options.validate_server!(server)
      end

    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    buffer = Keyword.get(opts, :buffer)

    subscribe_port(port_manager)
    subscribe_to_parser(parser_manager)
    FileWatcherHelpers.maybe_watch_buffer(buffer)

    log_safe_mode_startup()

    # An empty launch (no file argument) boots into the zero-buffers
    # launchpad (#2689): buffers.active stays nil, the initial window shows
    # the empty-state surface, and command dispatch skips requires_buffer
    # commands until a buffer opens.
    {active_buf, buffers} =
      case buffer do
        pid when is_pid(pid) -> {pid, [pid]}
        _ -> {nil, []}
      end

    # Decide mode FIRST, then create the right window type.
    {keymap_scope, agentic_state} =
      startup_view_state(backend, Keyword.get(opts, :view_mode), options_server)

    initial_window_id = 1

    {initial_window, agent_state_update} =
      build_initial_window(
        keymap_scope,
        initial_window_id,
        active_buf,
        height,
        width,
        options_server
      )

    windows = %{initial_window_id => initial_window}

    project_root = project_root_from_opts(opts)

    file_tree = %MingaEditor.State.FileTree{project_root: project_root}

    register_sidebar_contributions(file_tree, sidebar_registry)

    workspace =
      %MingaEditor.Session.State{
        buffers: %Buffers{
          active: active_buf,
          list: buffers,
          active_index: 0
        },
        viewport: Viewport.new(height, width),
        editing: VimState.new(),
        windows: %Windows{
          tree: WindowTree.new(initial_window_id),
          map: windows,
          active: initial_window_id,
          next_id: initial_window_id + 1
        },
        keymap_scope: keymap_scope,
        agent_ui: agentic_state,
        launchpad: startup_launchpad(active_buf, keymap_scope, opts)
      }
      |> MingaEditor.Session.State.set_file_tree(file_tree)

    editing_model =
      Keyword.get_lazy(opts, :editing_model, fn ->
        Minga.Config.get(:editing_model)
      end)

    # Warn if CUA is active on TUI backend
    if editing_model == :cua and backend == :tui do
      Minga.Log.warning(
        :editor,
        "CUA mode is not fully supported on TUI. Some keybindings may not work as expected. Consider using Vim mode (set editing_model = 'vim' in config)."
      )
    end

    shell_entry = resolve_shell(opts)

    state = %EditorState{
      workspace: workspace,
      shell_runtime: ShellRuntime.new(shell_entry, init_shell_state(shell_entry.module, opts)),
      frontend:
        FrontendState.new(
          backend: backend,
          rendering: rendering,
          port_manager: port_manager
        ),
      render: RenderState.new(),
      parser: ParserState.new(parser_manager),
      agent_connection:
        AgentConnection.new(
          Keyword.get(opts, :agent_provider_module),
          Keyword.get(opts, :agent_provider_opts, [])
        ),
      interaction:
        Interaction.new(
          editing_model: editing_model,
          keymap_server: keymap_server,
          options_server: options_server
        ),
      extension_surfaces:
        ExtensionSurfaces.new(
          events_registry: events_registry,
          sidebar_registry: sidebar_registry
        ),
      effect_scheduler: Keyword.get(opts, :effect_scheduler),
      session: EditorSessionState.new(Keyword.take(opts, [:swap_dir, :session_dir]))
    }

    shell_state =
      MingaEditor.Shell.Traditional.State.install_tab_bar(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        initial_tab_bar(active_buf, keymap_scope, project_root)
      )

    state = %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }

    state =
      case agent_state_update do
        :semantic_agent_window ->
          state

        :noop ->
          state
      end

    # Snapshot the fully assembled state into the initial tab's context.
    # Without this, the first tab starts with an empty context, and
    # restore_tab_context falls back to file defaults (wrong for agent tabs).
    context = MingaEditor.State.Tab.Context.snapshot(state.workspace)
    current_tb = state.shell_runtime.state.tab_bar
    tb = TabBar.update_context(current_tb, current_tb.active_id, context)

    shell_state =
      MingaEditor.Shell.Traditional.State.install_tab_bar(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        tb
      )

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  @spec rendering_policy(keyword()) :: EditorState.rendering_policy()
  defp rendering_policy(opts) do
    opts
    |> Keyword.get(:rendering, :enabled)
    |> validate_rendering_policy()
  end

  @spec validate_rendering_policy(term()) :: EditorState.rendering_policy()
  defp validate_rendering_policy(policy) when policy in [:enabled, :disabled], do: policy

  defp validate_rendering_policy(policy) do
    raise ArgumentError,
          "expected :rendering to be :enabled or :disabled, got: #{inspect(policy)}"
  end

  @spec log_safe_mode_startup() :: :ok
  defp log_safe_mode_startup do
    if Minga.SafeMode.active?() do
      Log.info(:editor, "Started in safe mode: user config not loaded")
    end

    :ok
  end

  @doc """
  Creates the initial window based on the startup mode.

  In agent mode: creates a semantic agent chat window. In editor mode:
  creates a regular buffer window for the
  file buffer (or a blank buffer if no file was specified).

  Returns `{window | nil, agent_state_update}` where the update is
  either `:semantic_agent_window` or `:noop`.
  """
  @spec build_initial_window(atom(), Window.id(), pid() | nil, pos_integer(), pos_integer()) ::
          {Window.t(), :semantic_agent_window | :noop}
  @spec build_initial_window(
          atom(),
          Window.id(),
          pid() | nil,
          pos_integer(),
          pos_integer(),
          Options.server()
        ) :: {Window.t(), :semantic_agent_window | :noop}
  def build_initial_window(scope, win_id, active_buf, rows, cols) do
    build_initial_window(
      scope,
      win_id,
      active_buf,
      rows,
      cols,
      Options.default_server()
    )
  end

  def build_initial_window(:agent, win_id, _active_buf, rows, cols, _options_server) do
    {Window.new_agent_chat(win_id, rows, cols), :semantic_agent_window}
  end

  def build_initial_window(_scope, win_id, active_buf, rows, cols, _options_server) do
    window =
      if active_buf do
        Window.new(win_id, active_buf, rows, cols)
      else
        Window.new_empty_state(win_id, rows, cols)
      end

    {window, :noop}
  end

  # An empty non-agent launch boots into the launchpad; agent view mode has
  # its own semantic surface, and a file argument shows the buffer.
  @spec startup_launchpad(pid() | nil, atom(), keyword()) ::
          MingaEditor.State.Launchpad.t() | nil
  defp startup_launchpad(nil, scope, opts) when scope != :agent do
    MingaEditor.State.Launchpad.new(Keyword.take(opts, [:session_dir]))
  end

  defp startup_launchpad(_active_buf, _scope, _opts), do: nil

  @spec subscribe_port(GenServer.server() | nil) :: :ok
  defp subscribe_port(nil), do: :ok

  defp subscribe_port(port_manager) do
    MingaEditor.Frontend.subscribe(port_manager)
  catch
    :exit, _ -> Minga.Log.warning(:editor, "Could not subscribe to port manager")
  end

  @doc """
  Builds the initial tab bar based on the active buffer and keymap scope.
  """
  @spec initial_tab_bar(pid() | nil, atom(), String.t() | nil) :: TabBar.t()
  def initial_tab_bar(_active_buf, :agent, project_root) do
    TabBar.new(Tab.new_agent(1, "Agent"), project_root)
    |> restore_persisted_workspaces(project_root)
  end

  def initial_tab_bar(nil, _scope, project_root) do
    TabBar.new_empty(project_root)
    |> restore_persisted_workspaces(project_root)
  end

  def initial_tab_bar(active_buf, _scope, project_root) do
    file_label =
      try do
        Commands.Helpers.buffer_display_name(active_buf)
      catch
        :exit, _ -> "[no file]"
      end

    TabBar.new(Tab.new_file(1, file_label), project_root)
    |> restore_persisted_workspaces(project_root)
  end

  @spec restore_persisted_workspaces(TabBar.t(), String.t() | nil) :: TabBar.t()
  defp restore_persisted_workspaces(%TabBar{} = tab_bar, project_root) do
    TabBar.restore_workspaces(tab_bar, WorkspacePersistence.scan(project_root), project_root)
  end

  @spec register_sidebar_contributions(
          MingaEditor.State.FileTree.t(),
          MingaEditor.Extension.Sidebar.table()
        ) :: :ok
  defp register_sidebar_contributions(file_tree, sidebar_registry) do
    log_contribution_registration(
      FileTreeFeature.register_contributions(file_tree, sidebar_registry),
      "FileTree contribution registration failed"
    )

    log_contribution_registration(
      BuiltinSurfaces.register_contributions(sidebar_registry),
      "Built-in sidebar contribution registration failed"
    )
  end

  @spec log_contribution_registration(:ok | {:error, term()}, String.t()) :: :ok
  defp log_contribution_registration(:ok, _message), do: :ok

  defp log_contribution_registration({:error, reason}, message) do
    Log.warning(:editor, "#{message}: #{inspect(reason)}")
  end

  @spec project_root_from_opts(keyword()) :: String.t() | nil
  defp project_root_from_opts(opts) do
    if Keyword.has_key?(opts, :project_root) do
      Keyword.get(opts, :project_root)
    else
      maybe_infer_project_root(opts)
    end
  end

  @spec maybe_infer_project_root(keyword()) :: String.t() | nil
  defp maybe_infer_project_root(opts) do
    default = Application.get_env(:minga, :infer_startup_project_root, true)

    if Keyword.get(opts, :infer_project_root, default) do
      startup_project_root()
    else
      nil
    end
  end

  @spec startup_project_root() :: String.t() | nil
  defp startup_project_root do
    Minga.CLI.startup_project_root() || Minga.CLI.argv_startup_project_root() ||
      current_project_root()
  end

  @spec current_project_root() :: String.t() | nil
  defp current_project_root do
    case Minga.Project.root() do
      root when is_binary(root) -> root
      nil -> nil
    end
  catch
    :exit, reason ->
      Minga.Log.warning(:editor, "Startup project root lookup failed: #{inspect(reason)}")
      nil
  end

  @doc """
  Determines the initial view state based on the frontend backend and config.

  Returns `{keymap_scope, agentic_state}`. Called before window creation
  so the correct window type can be built in a single pass.

  Explicit CLI view modes are final. Auto startup consults the
  `:startup_view` config option for all backends.
  """
  @spec startup_view_state(EditorState.backend()) :: {atom(), UIState.t()}
  def startup_view_state(backend) do
    cli_flags = Minga.CLI.startup_flags()
    startup_view_state(backend, cli_flags.view_mode, nil)
  end

  @spec startup_view_state(
          EditorState.backend(),
          Minga.CLI.view_mode() | nil,
          Options.server() | nil
        ) :: {atom(), UIState.t()}
  defp startup_view_state(backend, nil, options_server) do
    cli_flags = Minga.CLI.startup_flags()
    startup_view_state(backend, cli_flags.view_mode, options_server)
  end

  defp startup_view_state(_backend, :editor, _options_server), do: editor_view_state()
  defp startup_view_state(_backend, :agentic, _options_server), do: agent_view_state()

  defp startup_view_state(_backend, :auto, nil),
    do: startup_view_state_from_config(Config.get(:startup_view))

  defp startup_view_state(_backend, :auto, options_server),
    do: startup_view_state_from_config(Options.get(options_server, :startup_view))

  @spec startup_view_state_from_config(atom()) :: {atom(), UIState.t()}
  defp startup_view_state_from_config(:agent), do: agent_view_state()
  defp startup_view_state_from_config(_startup_view), do: editor_view_state()

  @spec agent_view_state() :: {atom(), UIState.t()}
  defp agent_view_state do
    ui = UIState.new()
    view = MingaEditor.Agent.UIState.View.activate(ui.view, nil, nil)
    {:agent, UIState.replace_view(ui, view)}
  end

  @spec editor_view_state() :: {atom(), UIState.t()}
  defp editor_view_state, do: {:editor, UIState.new()}

  @doc """
  Fetches port capabilities, returning defaults if no port manager is configured.
  """
  @spec fetch_capabilities(GenServer.server() | nil) :: MingaEditor.Frontend.Capabilities.t()
  def fetch_capabilities(nil), do: %MingaEditor.Frontend.Capabilities{}

  def fetch_capabilities(port_manager) do
    MingaEditor.Frontend.capabilities(port_manager)
  catch
    :exit, _ -> %MingaEditor.Frontend.Capabilities{}
  end

  @doc """
  Subscribes to the parser manager for highlight events.
  """
  @spec subscribe_to_parser(GenServer.server() | nil) :: :ok
  def subscribe_to_parser(nil) do
    Minga.Parser.Manager.subscribe()
  catch
    :exit, _ -> :ok
  end

  def subscribe_to_parser(parser_manager) do
    Minga.Parser.Manager.subscribe(parser_manager)
  catch
    :exit, _ -> Minga.Log.warning(:editor, "Could not subscribe to parser manager")
  end

  @doc """
  Applies user config options (theme, error messages) to editor state.
  """
  @spec apply_config_options(MingaEditor.State.t()) :: MingaEditor.State.t()
  def apply_config_options(state) do
    theme_name = Options.get(state.interaction.options_server, :theme)
    theme = MingaEditor.UI.Theme.get!(theme_name)
    state = EditorState.apply_theme(state, theme)

    case Config.load_error() do
      nil -> state
      error -> MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, error)
    end
  end

  @doc """
  Applies GUI-specific option defaults when the frontend is a native GUI.

  Called after capabilities are fetched during the `:ready` handshake.
  Only overrides options the user has not explicitly customized. Uses the
  heuristic that if an option still holds its TUI-era default value, the
  user did not set it.

  Currently overrides:
  - `:line_numbers` — `:hybrid` → `:absolute` (GUI users expect VS Code/Zed-style
    absolute numbers; relative numbers look alien in a GUI context)
  - `:line_spacing` — `1.0` → `1.2` (GUI text benefits from breathing room;
    TUI stays at 1.0 because terminal cells have fixed height)
  """
  @spec apply_gui_defaults(MingaEditor.Frontend.Capabilities.t(), Options.server()) ::
          :ok
  def apply_gui_defaults(caps, options_server) do
    alias MingaEditor.Frontend.Capabilities

    if Capabilities.gui?(caps) do
      # Only override if the user hasn't explicitly set a preference.
      # :hybrid is the TUI default; if it is still the implicit default, we can
      # safely switch to :absolute for native GUI frontends.
      if Options.get(options_server, :line_numbers) == :hybrid and
           not Options.explicitly_set?(options_server, :line_numbers) do
        Options.set(options_server, :line_numbers, :absolute)
      end

      if Options.get(options_server, :line_spacing) == 1.0 and
           not Options.explicitly_set?(options_server, :line_spacing) do
        Options.set(options_server, :line_spacing, 1.2)
      end
    end

    :ok
  end

  @doc """
  Sends font configuration to the frontend via the port protocol.

  Line spacing and cursor animation are no longer pushed here; they ride inside
  the frame transaction as semantic models (#2119), so a late-attaching client's
  keyframe carries them. This helper covers only the font family/size/weight/
  ligatures/fallback configuration, which remains an out-of-band font setup push.
  """
  @spec send_font_config(MingaEditor.State.t()) :: :ok
  def send_font_config(%EditorState{frontend: %{port_manager: nil}}), do: :ok

  def send_font_config(%EditorState{frontend: %{port_manager: port}} = state) do
    options_server = state.interaction.options_server
    family = Options.get(options_server, :font_family)
    config_size = Options.get(options_server, :font_size)
    size = state.appearance.font_size_override || config_size
    ligatures = Options.get(options_server, :font_ligatures)
    weight = Options.get(options_server, :font_weight)
    fallback = Options.get(options_server, :font_fallback)

    MingaEditor.Frontend.configure_font(port, family, size, ligatures, weight, fallback || [])
  catch
    :exit, _ -> :ok
  end

  # ── Shell resolution ───────────────────────────────────────────────────

  @spec resolve_shell(keyword()) :: MingaEditor.Shell.Entry.t()
  defp resolve_shell(opts) do
    MingaEditor.Shell.Registry.seed_builtin()

    case Keyword.get(opts, :shell) do
      nil -> resolve_shell_from_config()
      id_or_module when is_atom(id_or_module) -> resolve_explicit_shell(id_or_module)
    end
  end

  @spec resolve_shell_from_config() :: MingaEditor.Shell.Entry.t()
  defp resolve_shell_from_config do
    Minga.Config.get(:default_shell)
    |> resolve_shell_id_or_module()
  catch
    :exit, reason ->
      default = MingaEditor.Shell.Registry.default()
      Log.warning(:editor, "Default shell lookup failed: #{inspect(reason)}; using #{default.id}")
      default
  end

  @spec resolve_explicit_shell(atom()) :: MingaEditor.Shell.Entry.t()
  defp resolve_explicit_shell(id_or_module) do
    case resolve_shell_entry(id_or_module) do
      nil ->
        default = MingaEditor.Shell.Registry.default()

        Log.warning(
          :editor,
          "Requested shell #{inspect(id_or_module)} is not registered, using #{default.id}"
        )

        default

      entry ->
        entry
    end
  end

  @spec resolve_shell_id_or_module(atom()) :: MingaEditor.Shell.Entry.t()
  defp resolve_shell_id_or_module(id_or_module) do
    case resolve_shell_entry(id_or_module) do
      nil ->
        default = MingaEditor.Shell.Registry.default()

        Log.warning(
          :editor,
          "Configured default shell #{inspect(id_or_module)} is not registered, using #{default.id}"
        )

        default

      entry ->
        entry
    end
  end

  @spec resolve_shell_entry(atom()) :: MingaEditor.Shell.Entry.t() | nil
  defp resolve_shell_entry(id_or_module), do: MingaEditor.Shell.Registry.resolve(id_or_module)

  @spec init_shell_state(module(), keyword()) :: term()
  defp init_shell_state(MingaEditor.Shell.Traditional, opts) do
    MingaEditor.Shell.Traditional.State.install_tool_prompt_suppression(
      %MingaEditor.Shell.Traditional.State{},
      Keyword.get(opts, :suppress_tool_prompts, false)
    )
  end

  defp init_shell_state(module, opts) do
    module.init(opts)
  end
end
