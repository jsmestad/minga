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
  alias Minga.Editor.LayoutPreset
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.Mode
  alias Minga.Port.Manager, as: PortManager

  @doc """
  Builds the complete initial EditorState from startup opts.

  Subscribes to port manager and parser, starts special buffers,
  initializes windows, and determines the initial view (agent vs editor).
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

    {messages_buf, scratch_buf} = start_special_buffers()

    {active_buf, buffers} =
      case {buffer, scratch_buf} do
        {nil, pid} when is_pid(pid) -> {pid, []}
        {pid, _} when is_pid(pid) -> {pid, [pid]}
        _ -> {nil, []}
      end

    initial_window_id = 1

    initial_window =
      if active_buf, do: Window.new(initial_window_id, active_buf, height, width), else: nil

    windows = if initial_window, do: %{initial_window_id => initial_window}, else: %{}

    {keymap_scope, _agentic_state, effective_tree} =
      startup_view_state(port_manager, initial_window_id)

    state = %EditorState{
      buffers: %Buffers{
        active: active_buf,
        list: buffers,
        active_index: 0,
        messages: messages_buf,
        scratch: scratch_buf
      },
      port_manager: port_manager,
      viewport: Viewport.new(height, width),
      mode: :normal,
      mode_state: Mode.initial_state(),
      windows: %Windows{
        tree: effective_tree,
        map: windows,
        active: initial_window_id,
        next_id: initial_window_id + 1
      },
      keymap_scope: keymap_scope,
      focus_stack: Minga.Input.default_stack()
    }

    state = %{state | tab_bar: initial_tab_bar(active_buf, keymap_scope)}
    maybe_apply_agent_split(state)
  end

  @doc """
  Creates the agent buffer and applies the agent split layout when
  booting into agent mode.

  This bridges the gap between `startup_view_state` (which decides
  *whether* to use agent mode) and the window tree (which needs an
  actual agent chat window for the render pipeline to find). Without
  this step, `LayoutPreset.has_agent_chat?/1` returns false and the
  agent session never starts.
  """
  @spec maybe_apply_agent_split(EditorState.t()) :: EditorState.t()
  def maybe_apply_agent_split(%{keymap_scope: :agent} = state) do
    agent_buf = AgentBufferSync.start_buffer()

    if is_pid(agent_buf) do
      state = AgentAccess.update_agent(state, fn a -> %{a | buffer: agent_buf} end)
      LayoutPreset.apply(state, :agent_right, agent_buf)
    else
      state
    end
  end

  def maybe_apply_agent_split(state), do: state

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
        "*scratch*"
      end

    TabBar.new(Tab.new_file(1, file_label))
  end

  @doc """
  Determines the initial view state based on CLI flags and config.

  Returns `{keymap_scope, agentic_state, window_tree}`. Both agent and
  editor modes get a real WindowTree; agent mode creates the split layout
  in `maybe_apply_agent_split/1` after the state struct is built.
  """
  @spec startup_view_state(GenServer.server() | nil, pos_integer()) ::
          {atom(), ViewState.t(), WindowTree.t()}
  def startup_view_state(port_manager, window_id) do
    tui_mode? = port_manager == PortManager
    cli_flags = Minga.CLI.startup_flags()

    want_agent? =
      tui_mode? and
        not cli_flags.force_editor and
        safe_get_option(:startup_view, :agent) == :agent

    if want_agent? do
      av = %ViewState{ViewState.new() | active: true, focus: :chat}
      {:agent, av, WindowTree.new(window_id)}
    else
      {:editor, ViewState.new(), WindowTree.new(window_id)}
    end
  end

  @doc """
  Reads a config option with a fallback if the Options Agent isn't running.
  """
  @spec safe_get_option(ConfigOptions.option_name(), term()) :: term()
  def safe_get_option(name, fallback) do
    ConfigOptions.get(name)
  rescue
    _ -> fallback
  end

  @doc """
  Fetches port capabilities, returning defaults if the port isn't available.
  """
  @spec fetch_capabilities(GenServer.server() | nil) :: Minga.Port.Capabilities.t()
  def fetch_capabilities(nil), do: %Minga.Port.Capabilities{}

  def fetch_capabilities(port_manager) do
    PortManager.capabilities(port_manager)
  rescue
    _ -> %Minga.Port.Capabilities{}
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
  Starts the *Messages* and *scratch* special buffers.
  """
  @spec start_special_buffers() :: {pid() | nil, pid() | nil}
  def start_special_buffers do
    messages_buf =
      case DynamicSupervisor.start_child(
             Minga.Buffer.Supervisor,
             {BufferServer,
              content: "",
              buffer_name: "*Messages*",
              read_only: true,
              unlisted: true,
              persistent: true}
           ) do
        {:ok, pid} -> pid
        _ -> nil
      end

    scratch_filetype = ConfigOptions.get(:scratch_filetype)

    scratch_content =
      "# This buffer is for notes you don't want to save.\n# It will persist across buffer switches.\n\n"

    scratch_buf =
      case DynamicSupervisor.start_child(
             Minga.Buffer.Supervisor,
             {BufferServer,
              content: scratch_content,
              buffer_name: "*scratch*",
              unlisted: true,
              persistent: true,
              filetype: scratch_filetype}
           ) do
        {:ok, pid} -> pid
        _ -> nil
      end

    {messages_buf, scratch_buf}
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
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
