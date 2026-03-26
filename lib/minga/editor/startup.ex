defmodule Minga.Editor.Startup do
  @moduledoc """
  Editor initialization helpers.

  Pure functions and process-spawning helpers used by `Minga.Editor.init/1`.
  Extracted to keep the GenServer module focused on message handling.
  """

  # ShellState defaults include MapSet.new() which dialyzer flags as opaque
  # when flowing through bare-map pattern matches in accessor functions.
  @dialyzer {:no_opaque, build_initial_state: 1}

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.UIState
  alias Minga.Buffer
  alias Minga.Config
  alias Minga.Editor.Commands
  alias Minga.Editor.FileWatcherHelpers
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree

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
    port_manager = Keyword.get(opts, :port_manager, Minga.Frontend.Manager)
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    buffer = Keyword.get(opts, :buffer)

    subscribe_port(port_manager)
    subscribe_to_parser(Keyword.get(opts, :parser_manager))
    FileWatcherHelpers.maybe_watch_buffer(buffer)

    {messages_buf, _} = start_special_buffers()

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
              {Buffer, content: "", buffer_name: "[new 1]"}
            )

          {buf, [buf]}
      end

    dashboard = nil

    # Decide mode FIRST, then create the right window type.
    {keymap_scope, _agentic_state} = startup_view_state(backend)

    initial_window_id = 1

    {initial_window, agent_state_update} =
      build_initial_window(keymap_scope, initial_window_id, active_buf, height, width)

    windows =
      if initial_window, do: %{initial_window_id => initial_window}, else: %{}

    workspace = %Minga.Workspace.State{
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
      keymap_scope: keymap_scope
    }

    editing_model =
      Keyword.get_lazy(opts, :editing_model, fn ->
        Minga.Config.get(:editing_model)
      end)

    state = %EditorState{
      backend: backend,
      workspace: workspace,
      port_manager: port_manager,
      editing_model: editing_model,
      focus_stack: Minga.Input.default_stack(),
      shell: resolve_shell(opts),
      shell_state: init_shell_state(resolve_shell(opts), dashboard, opts),
      swap_dir: Keyword.get(opts, :swap_dir),
      session_dir: Keyword.get(opts, :session_dir)
    }

    state = EditorState.set_tab_bar(state, initial_tab_bar(active_buf, keymap_scope))

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
  def build_initial_window(:agent, win_id, _active_buf, rows, cols) do
    agent_buf = AgentBufferSync.start_buffer()

    if is_pid(agent_buf) do
      window = Window.new_agent_chat(win_id, agent_buf, rows, cols)
      {window, {:agent_buffer, agent_buf}}
    else
      {nil, :noop}
    end
  end

  def build_initial_window(_scope, win_id, active_buf, rows, cols) do
    window =
      if active_buf, do: Window.new(win_id, active_buf, rows, cols), else: nil

    {window, :noop}
  end

  @spec subscribe_port(GenServer.server() | nil) :: :ok
  defp subscribe_port(nil), do: :ok

  defp subscribe_port(port_manager) do
    Minga.Frontend.subscribe(port_manager)
  catch
    :exit, _ -> Minga.Log.warning(:editor, "Could not subscribe to port manager")
  end

  @doc """
  Builds the initial tab bar based on the active buffer and keymap scope.
  """
  @spec initial_tab_bar(pid() | nil, atom()) :: TabBar.t()
  def initial_tab_bar(_active_buf, :agent) do
    TabBar.new(Tab.new_agent(1, "Agent"))
  end

  def initial_tab_bar(active_buf, _scope) do
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

    TabBar.new(Tab.new_file(1, file_label))
  end

  @doc """
  Determines the initial view state based on the frontend backend and config.

  Returns `{keymap_scope, agentic_state}`. Called before window creation
  so the correct window type can be built in a single pass.

  Agent-first startup only applies to the TUI. GUI frontends always
  start with the editor view because agent mode is designed around the
  TUI's full-screen chat layout.
  """
  @spec startup_view_state(EditorState.backend()) :: {atom(), UIState.t()}
  def startup_view_state(backend) do
    cli_flags = Minga.CLI.startup_flags()

    want_agent? =
      backend == :tui and
        not cli_flags.force_editor and
        Config.get(:startup_view) == :agent

    if want_agent? do
      base = UIState.new()
      av = %UIState{base | view: %{base.view | active: true, focus: :chat}}
      {:agent, av}
    else
      {:editor, UIState.new()}
    end
  end

  @doc """
  Fetches port capabilities, returning defaults if no port manager is configured.
  """
  @spec fetch_capabilities(GenServer.server() | nil) :: Minga.Frontend.Capabilities.t()
  def fetch_capabilities(nil), do: %Minga.Frontend.Capabilities{}

  def fetch_capabilities(port_manager) do
    Minga.Frontend.capabilities(port_manager)
  catch
    :exit, _ -> %Minga.Frontend.Capabilities{}
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
  Starts the *Messages* special buffer.

  The *Warnings* buffer was removed in #825; warnings now route through
  *Messages* with level filtering in the GUI bottom panel.
  """
  @spec start_special_buffers() :: {pid() | nil, pid() | nil}
  def start_special_buffers do
    messages_buf = start_special_buffer("*Messages*", content: "", read_only: true)

    {messages_buf, nil}
  end

  @spec start_special_buffer(String.t(), keyword()) :: pid() | nil
  defp start_special_buffer(name, opts) do
    child_opts =
      [buffer_name: name, unlisted: true, persistent: true] ++ opts

    case DynamicSupervisor.start_child(Minga.Buffer.Supervisor, {Buffer, child_opts}) do
      {:ok, pid} -> pid
      _ -> nil
    end
  end

  @doc """
  Applies user config options (theme, error messages) to editor state.
  """
  @spec apply_config_options(Minga.Editor.State.t()) :: Minga.Editor.State.t()
  def apply_config_options(state) do
    state =
      try do
        theme_name = Config.get(:theme)
        theme = Minga.UI.Theme.get!(theme_name)

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
  Sends font configuration to the frontend via the port protocol.
  """
  @spec send_font_config(Minga.Editor.State.t()) :: :ok
  def send_font_config(%{port_manager: nil}), do: :ok

  def send_font_config(%{port_manager: port}) do
    family = Config.get(:font_family)
    size = Config.get(:font_size)
    ligatures = Config.get(:font_ligatures)
    weight = Config.get(:font_weight)
    fallback = Config.get(:font_fallback)

    Minga.Frontend.configure_font(port, family, size, ligatures, weight, fallback || [])
  catch
    :exit, _ -> :ok
  end

  # NOTE: safe_recent_files/0 removed with dashboard disable.
  # Will be restored when dashboard is reimplemented as a buffer.

  # ── Shell resolution ───────────────────────────────────────────────────

  @spec resolve_shell(keyword()) :: module()
  defp resolve_shell(opts) do
    case Keyword.get(opts, :shell) do
      :board -> Minga.Shell.Board
      :traditional -> Minga.Shell.Traditional
      nil -> resolve_shell_from_config()
      module when is_atom(module) -> module
    end
  end

  @spec resolve_shell_from_config() :: module()
  defp resolve_shell_from_config do
    case Minga.Config.get(:default_shell) do
      :board -> Minga.Shell.Board
      _ -> Minga.Shell.Traditional
    end
  catch
    :exit, _ -> Minga.Shell.Traditional
  end

  @spec init_shell_state(module(), term(), keyword()) :: term()
  defp init_shell_state(Minga.Shell.Board, _dashboard, opts) do
    Minga.Shell.Board.init(opts)
  end

  defp init_shell_state(Minga.Shell.Traditional, dashboard, opts) do
    %Minga.Shell.Traditional.State{
      dashboard: dashboard,
      suppress_tool_prompts: Keyword.get(opts, :suppress_tool_prompts, false)
    }
  end

  defp init_shell_state(module, _dashboard, opts) do
    module.init(opts)
  end
end
