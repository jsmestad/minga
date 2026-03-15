defmodule Minga.Editor.Startup do
  @moduledoc """
  Editor initialization helpers.

  Pure functions and process-spawning helpers used by `Minga.Editor.init/1`.
  Extracted to keep the GenServer module focused on message handling.
  """

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Config.Loader, as: ConfigLoader
  alias Minga.Config.Options, as: ConfigOptions
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
  alias Minga.Port.Manager, as: PortManager

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
    port_manager = Keyword.get(opts, :port_manager, PortManager)
    width = Keyword.get(opts, :width, 80)
    height = Keyword.get(opts, :height, 24)
    buffer = Keyword.get(opts, :buffer)

    subscribe_port(port_manager)
    subscribe_to_parser(Keyword.get(opts, :parser_manager))
    FileWatcherHelpers.maybe_watch_buffer(buffer)

    {messages_buf, warnings_buf} = start_special_buffers()

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
              {BufferServer, content: "", buffer_name: "[new 1]"}
            )

          {buf, [buf]}
      end

    dashboard = nil

    # Decide mode FIRST, then create the right window type.
    {keymap_scope, _agentic_state} = startup_view_state(port_manager)

    initial_window_id = 1

    {initial_window, agent_state_update} =
      build_initial_window(keymap_scope, initial_window_id, active_buf, height, width)

    windows =
      if initial_window, do: %{initial_window_id => initial_window}, else: %{}

    state = %EditorState{
      buffers: %Buffers{
        active: active_buf,
        list: buffers,
        active_index: 0,
        messages: messages_buf,
        warnings: warnings_buf
      },
      port_manager: port_manager,
      viewport: Viewport.new(height, width),
      vim: VimState.new(),
      windows: %Windows{
        tree: WindowTree.new(initial_window_id),
        map: windows,
        active: initial_window_id,
        next_id: initial_window_id + 1
      },
      keymap_scope: keymap_scope,
      focus_stack: Minga.Input.default_stack(),
      dashboard: dashboard
    }

    state = %{state | tab_bar: initial_tab_bar(active_buf, keymap_scope)}

    # Store the agent buffer reference if one was created.
    case agent_state_update do
      {:agent_buffer, pid} ->
        AgentAccess.update_agent(state, fn a -> %{a | buffer: pid} end)

      :noop ->
        state
    end
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
    PortManager.subscribe(port_manager)
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
      if active_buf && Process.alive?(active_buf) do
        Commands.Helpers.buffer_display_name(active_buf)
      else
        "[no file]"
      end

    TabBar.new(Tab.new_file(1, file_label))
  end

  @doc """
  Determines the initial view state based on CLI flags and config.

  Returns `{keymap_scope, agentic_state}`. Called before window creation
  so the correct window type can be built in a single pass.
  """
  @spec startup_view_state(GenServer.server() | nil) ::
          {atom(), ViewState.t()}
  def startup_view_state(port_manager) do
    tui_mode? = port_manager == PortManager
    cli_flags = Minga.CLI.startup_flags()

    want_agent? =
      tui_mode? and
        not cli_flags.force_editor and
        ConfigOptions.get(:startup_view) == :agent

    if want_agent? do
      av = %ViewState{ViewState.new() | active: true, focus: :chat}
      {:agent, av}
    else
      {:editor, ViewState.new()}
    end
  end

  @doc """
  Fetches port capabilities, returning defaults if no port manager is configured.
  """
  @spec fetch_capabilities(GenServer.server() | nil) :: Minga.Port.Capabilities.t()
  def fetch_capabilities(nil), do: %Minga.Port.Capabilities{}

  def fetch_capabilities(port_manager) do
    PortManager.capabilities(port_manager)
  catch
    :exit, _ -> %Minga.Port.Capabilities{}
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
  Starts the *Messages* and *Warnings* special buffers.
  """
  @spec start_special_buffers() :: {pid() | nil, pid() | nil}
  def start_special_buffers do
    messages_buf = start_special_buffer("*Messages*", content: "", read_only: true)
    warnings_buf = start_special_buffer("*Warnings*", content: "", read_only: true)

    {messages_buf, warnings_buf}
  end

  @spec start_special_buffer(String.t(), keyword()) :: pid() | nil
  defp start_special_buffer(name, opts) do
    child_opts =
      [buffer_name: name, unlisted: true, persistent: true] ++ opts

    case DynamicSupervisor.start_child(Minga.Buffer.Supervisor, {BufferServer, child_opts}) do
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
        theme_name = ConfigOptions.get(:theme)
        theme = Minga.Theme.get!(theme_name)

        %{state | theme: theme}
      catch
        :exit, _ -> state
      end

    try do
      case ConfigLoader.load_error() do
        nil -> state
        error -> %{state | status_msg: error}
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
    family = ConfigOptions.get(:font_family)
    size = ConfigOptions.get(:font_size)
    ligatures = ConfigOptions.get(:font_ligatures)
    weight = ConfigOptions.get(:font_weight)
    cmd = Minga.Port.Protocol.encode_set_font(family, size, ligatures, weight)
    Minga.Port.Manager.send_commands(port, [cmd])
  catch
    :exit, _ -> :ok
  end

  # NOTE: safe_recent_files/0 removed with dashboard disable.
  # Will be restored when dashboard is reimplemented as a buffer.
end
