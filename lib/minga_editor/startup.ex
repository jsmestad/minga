defmodule MingaEditor.Startup do
  @moduledoc """
  Editor initialization helpers.

  Pure functions and process-spawning helpers used by `MingaEditor.init/1`.
  Extracted to keep the GenServer module focused on message handling.
  """

  # ShellState defaults include MapSet.new() which dialyzer flags as opaque
  # when flowing through bare-map pattern matches in accessor functions.
  @dialyzer {:no_opaque, build_initial_state: 1}

  alias MingaEditor.Agent.BufferSync, as: AgentBufferSync
  alias MingaEditor.Agent.UIState
  alias Minga.Buffer
  alias Minga.Config
  alias MingaEditor.Commands
  alias MingaEditor.FileWatcherHelpers
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Session, as: SessionState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Workspace.Persistence, as: WorkspacePersistence
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @doc """
  Builds the complete initial EditorState from startup opts.

  Subscribes to port manager and parser, starts special buffers,
  determines the startup mode (agent vs editor), and creates the
  correct window type in a single pass.

  In agent mode the initial window is an agent chat window (full screen).
  In editor mode it's a regular buffer window showing the file buffer
  (or the dashboard if no file was specified). The mode decision happens *before* window creation so
  there's no create-then-replace dance.
  """
  @spec build_initial_state(keyword()) :: EditorState.t()
  def build_initial_state(opts) do
    backend = Keyword.get(opts, :backend, :headless)
    port_manager = Keyword.get(opts, :port_manager, MingaEditor.Frontend.Manager)
    keymap_server = Keyword.get(opts, :keymap_server, Minga.Keymap.default_server())
    events_registry = Keyword.get(opts, :events_registry, Minga.Events.default_registry())

    options_server =
      case Keyword.get(opts, :options_server, Minga.Config.Options.default_server()) do
        nil -> Minga.Config.Options.default_server()
        server -> Minga.Config.Options.validate_server!(server)
      end

    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    buffer = Keyword.get(opts, :buffer)

    subscribe_port(port_manager)
    subscribe_to_parser(Keyword.get(opts, :parser_manager))
    FileWatcherHelpers.maybe_watch_buffer(buffer)

    messages_buf = Minga.Log.messages_buffer()

    # Always ensure an active buffer exists. The editor's render pipeline,
    # command dispatch, and input routing all assume buffers.active is a
    # pid. The dashboard feature (which set active to nil) is disabled
    # until it can be reimplemented as a special buffer. See #XXX.
    {active_buf, buffers} =
      case buffer do
        pid when is_pid(pid) ->
          {pid, [pid]}

        _ ->
          {:ok, buf} =
            DynamicSupervisor.start_child(
              Minga.Buffer.Supervisor,
              {Buffer, content: "", buffer_name: "[new 1]", options_server: options_server}
            )

          {buf, [buf]}
      end

    dashboard = nil

    # Decide mode FIRST, then create the right window type.
    {keymap_scope, _agentic_state} = startup_view_state(backend)

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

    windows =
      if initial_window, do: %{initial_window_id => initial_window}, else: %{}

    project_root = Keyword.get_lazy(opts, :project_root, &startup_project_root/0)

    workspace = %MingaEditor.Workspace.State{
      buffers: %Buffers{
        active: active_buf,
        list: buffers,
        active_index: 0,
        messages: messages_buf
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
      file_tree: %MingaEditor.State.FileTree{project_root: project_root}
    }

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

    state = %EditorState{
      backend: backend,
      workspace: workspace,
      port_manager: port_manager,
      keymap_server: keymap_server,
      options_server: options_server,
      events_registry: events_registry,
      editing_model: editing_model,
      focus_stack: MingaEditor.Input.default_stack(),
      shell: resolve_shell(opts),
      shell_state: init_shell_state(resolve_shell(opts), dashboard, opts),
      session: SessionState.new(Keyword.take(opts, [:swap_dir, :session_dir]))
    }

    state =
      EditorState.set_tab_bar(state, initial_tab_bar(active_buf, keymap_scope, project_root))

    # Store the agent buffer reference if one was created.
    state =
      case agent_state_update do
        {:agent_buffer, pid} ->
          AgentAccess.update_agent(state, fn a -> %{a | buffer: pid} end)

        :noop ->
          state
      end

    # Snapshot the fully assembled state into the initial tab's context.
    # Without this, the first tab starts with an empty context, and
    # restore_tab_context falls back to file defaults (wrong for agent tabs).
    context = EditorState.snapshot_tab_context(state)
    current_tb = EditorState.tab_bar(state)
    tb = TabBar.update_context(current_tb, current_tb.active_id, context)
    EditorState.set_tab_bar(state, tb)
  end

  @doc """
  Creates the initial window based on the startup mode.

  In agent mode: starts the `*Agent*` buffer and creates an agent chat
  window. In editor mode: creates a regular buffer window for the
  file buffer (or dashboard if no file was specified).

  Returns `{window | nil, agent_state_update}` where the update is
  either `{:agent_buffer, pid}` or `:noop`.
  """
  @spec build_initial_window(atom(), Window.id(), pid() | nil, pos_integer(), pos_integer()) ::
          {Window.t() | nil, {:agent_buffer, pid()} | :noop}
  @spec build_initial_window(
          atom(),
          Window.id(),
          pid() | nil,
          pos_integer(),
          pos_integer(),
          Minga.Config.Options.server()
        ) :: {Window.t() | nil, {:agent_buffer, pid()} | :noop}
  def build_initial_window(scope, win_id, active_buf, rows, cols) do
    build_initial_window(
      scope,
      win_id,
      active_buf,
      rows,
      cols,
      Minga.Config.Options.default_server()
    )
  end

  def build_initial_window(:agent, win_id, _active_buf, rows, cols, options_server) do
    agent_buf = AgentBufferSync.start_buffer(options_server)

    if is_pid(agent_buf) do
      window = Window.new_agent_chat(win_id, agent_buf, rows, cols)
      {window, {:agent_buffer, agent_buf}}
    else
      {nil, :noop}
    end
  end

  def build_initial_window(_scope, win_id, active_buf, rows, cols, _options_server) do
    window =
      if active_buf, do: Window.new(win_id, active_buf, rows, cols), else: nil

    {window, :noop}
  end

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

  def initial_tab_bar(active_buf, _scope, project_root) do
    file_label =
      if active_buf do
        try do
          Commands.Helpers.buffer_display_name(active_buf)
        catch
          :exit, _ -> "[no file]"
        end
      else
        "[no file]"
      end

    TabBar.new(Tab.new_file(1, file_label), project_root)
    |> restore_persisted_workspaces(project_root)
  end

  @spec restore_persisted_workspaces(TabBar.t(), String.t() | nil) :: TabBar.t()
  defp restore_persisted_workspaces(%TabBar{} = tab_bar, project_root) do
    TabBar.restore_workspaces(tab_bar, WorkspacePersistence.scan(project_root), project_root)
  end

  @spec startup_project_root() :: String.t() | nil
  defp startup_project_root do
    Minga.CLI.startup_project_root() || Minga.CLI.argv_startup_project_root() ||
      Minga.CLI.cwd_startup_project_root() || current_project_root()
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

  Explicit CLI view modes are final. Auto startup keeps the existing
  behavior: TUI consults the startup config, while GUI frontends default
  to the editor view.
  """
  @spec startup_view_state(EditorState.backend()) :: {atom(), UIState.t()}
  def startup_view_state(backend) do
    cli_flags = Minga.CLI.startup_flags()
    startup_view_state(backend, cli_flags.view_mode)
  end

  @spec startup_view_state(EditorState.backend(), Minga.CLI.view_mode()) :: {atom(), UIState.t()}
  defp startup_view_state(_backend, :editor), do: editor_view_state()
  defp startup_view_state(_backend, :agentic), do: agent_view_state()

  defp startup_view_state(:tui, :auto),
    do: startup_view_state_from_config(Config.get(:startup_view))

  defp startup_view_state(_backend, :auto), do: editor_view_state()

  @spec startup_view_state_from_config(atom()) :: {atom(), UIState.t()}
  defp startup_view_state_from_config(:agent), do: agent_view_state()
  defp startup_view_state_from_config(_startup_view), do: editor_view_state()

  @spec agent_view_state() :: {atom(), UIState.t()}
  defp agent_view_state do
    base = UIState.new()
    av = %UIState{base | view: %{base.view | active: true, focus: :chat}}
    {:agent, av}
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
    state =
      try do
        theme_name = Config.get(:theme)
        theme = MingaEditor.UI.Theme.get!(theme_name)

        %{state | theme: theme}
      catch
        :exit, _ -> state
      end

    try do
      case Config.load_error() do
        nil -> state
        error -> EditorState.set_status(state, error)
      end
    catch
      :exit, _ -> state
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
  @spec apply_gui_defaults(MingaEditor.Frontend.Capabilities.t(), Minga.Config.Options.server()) ::
          :ok
  def apply_gui_defaults(caps, options_server) do
    alias MingaEditor.Frontend.Capabilities

    if Capabilities.gui?(caps) do
      # Only override if the user hasn't explicitly set a preference.
      # :hybrid is the TUI default; if it is still the implicit default, we can
      # safely switch to :absolute for native GUI frontends.
      if Minga.Config.Options.get(options_server, :line_numbers) == :hybrid and
           not Minga.Config.Options.explicitly_set?(options_server, :line_numbers) do
        Minga.Config.Options.set(options_server, :line_numbers, :absolute)
      end

      if Minga.Config.Options.get(options_server, :line_spacing) == 1.0 and
           not Minga.Config.Options.explicitly_set?(options_server, :line_spacing) do
        Minga.Config.Options.set(options_server, :line_spacing, 1.2)
      end
    end

    :ok
  end

  @doc """
  Sends font configuration to the frontend via the port protocol.

  Also sends GUI renderer options such as line spacing and cursor animation.
  """
  @spec send_font_config(MingaEditor.State.t()) :: :ok
  def send_font_config(%{port_manager: nil}), do: :ok

  def send_font_config(%{port_manager: port} = state) do
    options_server = EditorState.options_server(state)
    family = Minga.Config.Options.get(options_server, :font_family)
    size = Minga.Config.Options.get(options_server, :font_size)
    ligatures = Minga.Config.Options.get(options_server, :font_ligatures)
    weight = Minga.Config.Options.get(options_server, :font_weight)
    fallback = Minga.Config.Options.get(options_server, :font_fallback)

    MingaEditor.Frontend.configure_font(port, family, size, ligatures, weight, fallback || [])

    if MingaEditor.Frontend.gui?(state.capabilities) do
      line_spacing = Minga.Config.Options.get(options_server, :line_spacing) || 1.0
      MingaEditor.Frontend.send_line_spacing(port, line_spacing)

      cursor_animate = Minga.Config.Options.get(options_server, :cursor_animate)
      MingaEditor.Frontend.send_cursor_animation(port, cursor_animate)
    end
  catch
    :exit, _ -> :ok
  end

  @doc "Sends the current cursor animation preference to GUI frontends after a runtime option change."
  @spec send_cursor_animation_config(MingaEditor.State.t(), boolean()) :: :ok
  def send_cursor_animation_config(%{port_manager: nil}, _enabled), do: :ok

  def send_cursor_animation_config(%{port_manager: port} = state, enabled)
      when is_boolean(enabled) do
    if MingaEditor.Frontend.gui?(state.capabilities) do
      MingaEditor.Frontend.send_cursor_animation(port, enabled)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # NOTE: safe_recent_files/0 removed with dashboard disable.
  # Will be restored when dashboard is reimplemented as a buffer.

  # ── Shell resolution ───────────────────────────────────────────────────

  @spec resolve_shell(keyword()) :: module()
  defp resolve_shell(opts) do
    case Keyword.get(opts, :shell) do
      :board -> MingaEditor.Shell.Board
      :traditional -> MingaEditor.Shell.Traditional
      nil -> resolve_shell_from_config()
      module when is_atom(module) -> module
    end
  end

  @spec resolve_shell_from_config() :: module()
  defp resolve_shell_from_config do
    case Minga.Config.get(:default_shell) do
      :board -> MingaEditor.Shell.Board
      _ -> MingaEditor.Shell.Traditional
    end
  catch
    :exit, _ -> MingaEditor.Shell.Traditional
  end

  @spec init_shell_state(module(), term(), keyword()) :: term()
  defp init_shell_state(MingaEditor.Shell.Board, _dashboard, opts) do
    MingaEditor.Shell.Board.init(opts)
  end

  defp init_shell_state(MingaEditor.Shell.Traditional, _dashboard, opts) do
    %MingaEditor.Shell.Traditional.State{
      suppress_tool_prompts: Keyword.get(opts, :suppress_tool_prompts, false)
    }
  end

  defp init_shell_state(module, _dashboard, opts) do
    module.init(opts)
  end
end
