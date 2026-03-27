defmodule Minga.Editor.State do
  @moduledoc """
  Internal state for the Editor GenServer.

  ## Field categories

  EditorState fields fall into three categories:

  **Workspace fields** live in `state.workspace` (`Minga.Workspace.State`)
  and are saved/restored when switching tabs. Each tab carries a snapshot
  of the workspace so switching tabs restores the full editing context.

  **Shell fields** live in `state.shell_state` (`Minga.Shell.Traditional.State`)
  and hold presentation concerns: chrome, overlays, transient UI state.
  The active shell module is `state.shell`. See `Minga.Shell` for the
  behaviour definition.

  **Global fields** are shared across all tabs and never snapshotted:
  `port_manager`, `theme`, `render_timer`, `focus_stack`,
  `tab_bar`, `capabilities`, `layout`, `modeline_click_regions`,
  `tab_bar_click_regions`, `agent`, `picker_ui`, `whichkey`.

  ## Composed sub-structs

  * `Minga.Workspace.State`           — per-tab editing context (buffers, windows, vim, etc.)
  * `Minga.Shell.Traditional.State`   — presentation state (nav_flash, hover, dashboard, etc.)
  * `Minga.Editor.State.Picker`       — picker instance, source, restore index
  * `Minga.Editor.State.WhichKey`     — which-key popup node, timer, visibility
  * `Minga.Editor.State.Registers`    — named registers and active register selection
  """

  alias Minga.Agent.Session, as: AgentSession
  alias Minga.Agent.UIState
  alias Minga.Buffer

  alias Minga.Editor.BottomPanel
  alias Minga.Editor.CompletionTrigger
  alias Minga.Editor.Dashboard
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Highlighting
  alias Minga.Editor.State.Mouse
  alias Minga.Editor.State.Picker
  alias Minga.Editor.State.Prompt
  alias Minga.Editor.State.Registers
  alias Minga.Editor.State.Search
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.WhichKey
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Editor.WindowTree
  alias Minga.Frontend.Capabilities
  alias Minga.Log
  alias Minga.Mode
  alias Minga.Project.FileTree
  alias Minga.Tool.Manager, as: ToolManager
  alias Minga.UI.Panel.MessageStore
  alias Minga.UI.Theme
  alias Minga.Workspace.State, as: WorkspaceState

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @typedoc "A document highlight range from the LSP server."
  @type document_highlight :: Minga.LSP.DocumentHighlight.t()

  alias Minga.Shell.Traditional.State, as: ShellState

  @enforce_keys [:port_manager, :workspace]
  defstruct backend: :headless,
            port_manager: nil,
            workspace: nil,
            editing_model: :vim,
            shell: Minga.Shell.Traditional,
            shell_state: %ShellState{},
            theme: Minga.UI.Theme.get!(:doom_one),
            render_timer: nil,
            message_store: %MessageStore{},
            git_remote_op: nil,
            lsp_status: :none,
            lsp_server_statuses: %{},
            parser_status: :available,
            focus_stack: [],
            capabilities: %Capabilities{},
            layout: nil,
            last_cursor_line: nil,
            last_test_command: nil,
            pending_quit: nil,
            buffer_monitors: %{},
            face_override_registries: %{},
            font_registry: Minga.UI.FontRegistry.new(),
            highlight_debounce_timer: nil,
            inlay_hint_debounce_timer: nil,
            last_inlay_viewport_top: nil,
            code_lenses: [],
            inlay_hints: [],
            selection_ranges: nil,
            selection_range_index: 0,
            session_timer: nil,
            swap_dir: nil,
            session_dir: nil,
            space_leader_pending: false,
            space_leader_timer: nil,
            stashed_board_state: nil

  @type backend :: :tui | :native_gui | :headless

  @type t :: %__MODULE__{
          backend: backend(),
          port_manager: GenServer.server() | nil,
          workspace: WorkspaceState.t(),
          editing_model: :vim | :cua,
          shell: module(),
          shell_state: ShellState.t(),
          theme: Theme.t(),
          render_timer: reference() | nil,
          message_store: MessageStore.t(),
          git_remote_op:
            {msg_ref :: reference(), task_monitor :: reference(),
             {git_root :: String.t(), success_msg :: String.t(), error_prefix :: String.t()}}
            | nil,
          lsp_status: Minga.Editor.Modeline.lsp_status(),
          lsp_server_statuses: %{
            atom() => :starting | :initializing | :ready | :crashed
          },
          parser_status: Minga.Editor.Modeline.parser_status(),
          focus_stack: [module()],
          capabilities: Capabilities.t(),
          layout: Minga.Editor.Layout.t() | nil,
          last_cursor_line: non_neg_integer() | nil,
          last_test_command: {String.t(), String.t()} | nil,
          pending_quit: :quit | :quit_all | nil,
          buffer_monitors: %{pid() => reference()},
          face_override_registries: %{pid() => Minga.UI.Face.Registry.t()},
          highlight_debounce_timer: reference() | nil,
          inlay_hint_debounce_timer: reference() | nil,
          last_inlay_viewport_top: non_neg_integer() | nil,
          code_lenses: [map()],
          inlay_hints: [map()],
          selection_ranges: [map()] | nil,
          selection_range_index: non_neg_integer(),
          font_registry: Minga.UI.FontRegistry.t(),
          session_timer: reference() | nil,
          swap_dir: String.t() | nil,
          session_dir: String.t() | nil,
          space_leader_pending: boolean(),
          space_leader_timer: reference() | nil,
          stashed_board_state: Minga.Shell.Board.State.t() | nil
        }

  # ── Workspace helpers ──────────────────────────────────────────────────────

  @doc "Applies a function to the workspace and returns the updated state."
  @spec update_workspace(t(), (WorkspaceState.t() -> WorkspaceState.t())) :: t()
  def update_workspace(%__MODULE__{workspace: ws} = state, fun) when is_function(fun, 1) do
    %{state | workspace: fun.(ws)}
  end

  @doc "Applies a function to the shell state and returns the updated state."
  @spec update_shell_state(t(), (ShellState.t() -> ShellState.t())) :: t()
  def update_shell_state(%__MODULE__{shell_state: ss} = state, fun) when is_function(fun, 1) do
    %{state | shell_state: fun.(ss)}
  end

  # ── Shell field accessors ─────────────────────────────────────────────────
  # Convenience helpers for the most-accessed shell fields. These avoid
  # the verbose `%{state | shell_state: %{state.shell_state | field: val}}`
  # pattern at 100+ call sites.

  @doc "Returns the transient status message, or nil."
  @spec status_msg(t()) :: String.t() | nil
  def status_msg(%__MODULE__{shell_state: ss}), do: ss.status_msg

  @doc "Sets the transient status message shown in the modeline."
  @spec set_status(t(), String.t()) :: t()
  def set_status(%{shell_state: ss} = state, msg) when is_binary(msg) do
    %{state | shell_state: %{ss | status_msg: msg}}
  end

  @doc "Clears the transient status message."
  @spec clear_status(t()) :: t()
  def clear_status(%{shell_state: ss} = state) do
    %{state | shell_state: %{ss | status_msg: nil}}
  end

  @doc "Returns the nav flash state, or nil when inactive."
  @spec nav_flash(t()) :: Minga.Editor.NavFlash.t() | nil
  def nav_flash(%__MODULE__{shell_state: ss}), do: ss.nav_flash

  @doc "Sets the nav flash state."
  @spec set_nav_flash(t(), Minga.Editor.NavFlash.t()) :: t()
  def set_nav_flash(%{shell_state: ss} = state, %Minga.Editor.NavFlash{} = flash) do
    %{state | shell_state: %{ss | nav_flash: flash}}
  end

  @doc "Cancels the nav flash animation."
  @spec cancel_nav_flash(t()) :: t()
  def cancel_nav_flash(%{shell_state: ss} = state) do
    %{state | shell_state: %{ss | nav_flash: nil}}
  end

  @doc "Returns the hover popup state, or nil when not showing."
  @spec hover_popup(t()) :: Minga.Editor.HoverPopup.t() | nil
  def hover_popup(%__MODULE__{shell_state: ss}), do: ss.hover_popup

  @doc "Sets the hover popup state."
  @spec set_hover_popup(t(), Minga.Editor.HoverPopup.t()) :: t()
  def set_hover_popup(%{shell_state: ss} = state, %Minga.Editor.HoverPopup{} = popup) do
    %{state | shell_state: %{ss | hover_popup: popup}}
  end

  @doc "Dismisses the hover popup."
  @spec dismiss_hover_popup(t()) :: t()
  def dismiss_hover_popup(%{shell_state: ss} = state) do
    %{state | shell_state: %{ss | hover_popup: nil}}
  end

  @doc "Returns the dashboard home screen state, or nil."
  @spec dashboard(t()) :: Dashboard.state() | nil
  def dashboard(%__MODULE__{shell_state: ss}), do: ss.dashboard

  @doc "Sets the dashboard home screen state."
  @spec set_dashboard(t(), Dashboard.state()) :: t()
  def set_dashboard(%{shell_state: ss} = state, dash) when is_map(dash) do
    %{state | shell_state: %{ss | dashboard: dash}}
  end

  @doc "Closes the dashboard home screen."
  @spec close_dashboard(t()) :: t()
  def close_dashboard(%{shell_state: ss} = state) do
    %{state | shell_state: %{ss | dashboard: nil}}
  end

  # ── Picker UI ───────────────────────────────────────────────────────────

  @doc "Returns the picker UI state."
  @spec picker_ui(t()) :: Picker.t()
  def picker_ui(%{shell_state: ss}), do: ss.picker_ui

  @doc "Replaces the picker UI state."
  @spec set_picker_ui(t(), Picker.t()) :: t()
  def set_picker_ui(%{shell_state: ss} = state, pui) do
    %{state | shell_state: %{ss | picker_ui: pui}}
  end

  @doc "Applies a function to the picker UI state."
  @spec update_picker_ui(t(), (Picker.t() -> Picker.t())) :: t()
  def update_picker_ui(%{shell_state: ss} = state, fun) when is_function(fun, 1) do
    %{state | shell_state: %{ss | picker_ui: fun.(ss.picker_ui)}}
  end

  # ── Prompt UI ──────────────────────────────────────────────────────────

  @doc "Returns the prompt UI state."
  @spec prompt_ui(t()) :: Prompt.t()
  def prompt_ui(%{shell_state: ss}), do: ss.prompt_ui

  @doc "Replaces the prompt UI state."
  @spec set_prompt_ui(t(), Prompt.t()) :: t()
  def set_prompt_ui(%{shell_state: ss} = state, prompt) do
    %{state | shell_state: %{ss | prompt_ui: prompt}}
  end

  # ── Which-key ──────────────────────────────────────────────────────────

  @doc "Returns the which-key popup state."
  @spec whichkey(t()) :: WhichKey.t()
  def whichkey(%{shell_state: ss}), do: ss.whichkey

  @doc "Replaces the which-key popup state."
  @spec set_whichkey(t(), WhichKey.t()) :: t()
  def set_whichkey(%{shell_state: ss} = state, wk) do
    %{state | shell_state: %{ss | whichkey: wk}}
  end

  # ── Bottom panel ───────────────────────────────────────────────────────

  @doc "Returns the bottom panel state."
  @spec bottom_panel(t()) :: BottomPanel.t()
  def bottom_panel(%{shell_state: ss}), do: ss.bottom_panel

  @doc "Replaces the bottom panel state."
  @spec set_bottom_panel(t(), BottomPanel.t()) :: t()
  def set_bottom_panel(%{shell_state: ss} = state, panel) do
    %{state | shell_state: %{ss | bottom_panel: panel}}
  end

  # ── Git status panel ──────────────────────────────────────────────────

  @doc "Returns the git status panel data, or nil."
  @spec git_status_panel(t()) :: Minga.Frontend.Protocol.GUI.git_status_data() | nil
  def git_status_panel(%{shell_state: ss}), do: ss.git_status_panel

  @doc "Sets the git status panel data."
  @spec set_git_status_panel(t(), map() | nil) :: t()
  def set_git_status_panel(%{shell_state: ss} = state, data) do
    %{state | shell_state: %{ss | git_status_panel: data}}
  end

  @doc "Clears the git status panel."
  @spec close_git_status_panel(t()) :: t()
  def close_git_status_panel(%{shell_state: ss} = state) do
    %{state | shell_state: %{ss | git_status_panel: nil}}
  end

  # ── Tab bar ────────────────────────────────────────────────────────────

  @doc "Returns the tab bar state, or nil."
  @spec tab_bar(t()) :: TabBar.t() | nil
  def tab_bar(%{shell_state: ss}), do: ss.tab_bar

  @doc "Replaces the tab bar state."
  @spec set_tab_bar(t(), TabBar.t() | nil) :: t()
  def set_tab_bar(%{shell_state: ss} = state, tb) do
    %{state | shell_state: %{ss | tab_bar: tb}}
  end

  # ── Agent lifecycle ────────────────────────────────────────────────────

  @doc "Returns the agent session lifecycle state."
  @spec agent(t()) :: AgentState.t()
  def agent(%{shell_state: ss}), do: ss.agent

  @doc "Replaces the agent session lifecycle state."
  @spec set_agent(t(), AgentState.t()) :: t()
  def set_agent(%{shell_state: ss} = state, agent) do
    %{state | shell_state: %{ss | agent: agent}}
  end

  # ── Convenience accessors ─────────────────────────────────────────────────

  @doc "Returns the active buffer pid."
  @spec buffer(t()) :: pid() | nil
  def buffer(%__MODULE__{workspace: %{buffers: %{active: b}}}), do: b

  @doc "Returns the buffer list."
  @spec buffers(t()) :: [pid()]
  def buffers(%__MODULE__{workspace: %{buffers: %{list: bs}}}), do: bs

  @doc "Returns the active buffer index."
  @spec active_buffer(t()) :: non_neg_integer()
  def active_buffer(%__MODULE__{workspace: %{buffers: %{active_index: idx}}}), do: idx

  @doc """
  Returns the index of the buffer whose file path matches `file_path`, or nil.

  Catches `:exit` for each buffer in case a process has died but not yet been
  removed from the buffer list.
  """
  @spec find_buffer_by_path(t() | map(), String.t()) :: non_neg_integer() | nil
  def find_buffer_by_path(%{workspace: %{buffers: %{list: buffers}}}, file_path) do
    Enum.find_index(buffers, fn buf ->
      try do
        Buffer.file_path(buf) == file_path
      catch
        :exit, _ -> false
      end
    end)
  end

  @doc "Starts a new buffer under the buffer supervisor for the given file path."
  @spec start_buffer(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_buffer(file_path) do
    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {Minga.Buffer, file_path: file_path}
    )
  end

  # ── Buffer monitoring ──────────────────────────────────────────────────────

  @doc """
  Monitors a buffer pid so the Editor receives `:DOWN` when it dies.

  Idempotent: if the pid is already monitored, returns state unchanged.
  """
  @spec monitor_buffer(t(), pid()) :: t()
  def monitor_buffer(%__MODULE__{buffer_monitors: monitors} = state, pid)
      when is_pid(pid) do
    if Map.has_key?(monitors, pid) do
      state
    else
      ref = Process.monitor(pid)
      %{state | buffer_monitors: Map.put(monitors, pid, ref)}
    end
  end

  def monitor_buffer(state, _), do: state

  @doc """
  Monitors a list of buffer pids. Convenience wrapper around `monitor_buffer/2`.
  """
  @spec monitor_buffers(t(), [pid()]) :: t()
  def monitor_buffers(state, pids) when is_list(pids) do
    Enum.reduce(pids, state, &monitor_buffer(&2, &1))
  end

  @doc """
  Removes a dead buffer pid from all state locations.

  Called from the Editor's `:DOWN` handler. Removes the pid from the buffer
  list, clears it from special buffer slots (messages, warnings, help), and
  switches to another buffer if the active one died. Also cleans up the
  monitor ref.
  """
  @spec remove_dead_buffer(t(), pid()) :: t()
  def remove_dead_buffer(
        %__MODULE__{workspace: %{buffers: %Buffers{} = bs}, buffer_monitors: monitors} = state,
        pid
      ) do
    # Clean up monitor ref
    monitors = Map.delete(monitors, pid)

    # Remove from buffer list
    new_list = Enum.reject(bs.list, &(&1 == pid))

    # Clear special buffer slots if they match
    messages = if bs.messages == pid, do: nil, else: bs.messages
    help = if bs.help == pid, do: nil, else: bs.help

    # Determine new active buffer
    {new_active, new_index} =
      case new_list do
        [] ->
          {nil, 0}

        _ ->
          new_index = min(bs.active_index, length(new_list) - 1)
          {Enum.at(new_list, new_index), new_index}
      end

    new_bs = %Buffers{
      bs
      | list: new_list,
        active: new_active,
        active_index: new_index,
        messages: messages,
        help: help
    }

    state = %{state | workspace: %{state.workspace | buffers: new_bs}, buffer_monitors: monitors}

    # Clear agent buffer or prompt buffer if the dead pid matches
    agent = state.shell_state.agent

    state =
      if agent != nil and agent.buffer == pid do
        AgentAccess.update_agent(state, fn a -> %{a | buffer: nil} end)
      else
        state
      end

    ws = state.workspace

    state =
      if ws.agent_ui != nil and ws.agent_ui.panel.prompt_buffer == pid do
        AgentAccess.update_panel(state, fn p -> %{p | prompt_buffer: nil} end)
      else
        state
      end

    sync_active_window_buffer(state)
  end

  # ── Active content context ───────────────────────────────────────────────────

  @typedoc """
  Display metadata derived from the active window's content type.

  Used by title, modeline, and any other subsystem that needs to answer
  "what is the user looking at?" without assuming a buffer is active.
  """
  @type content_context :: %{
          type: :buffer | :agent,
          display_name: String.t(),
          directory: String.t(),
          dirty: boolean(),
          filetype: atom()
        }

  @doc """
  Returns display metadata for the active window's content.

  Buffer windows return file/buffer metadata. Agent chat windows return
  agent-specific display info. Falls back to buffer metadata when the
  active window is nil or unrecognized.
  """
  @spec active_content_context(t()) :: content_context()
  def active_content_context(%__MODULE__{} = state) do
    case active_window_struct(state) do
      %Window{content: {:agent_chat, _}} ->
        %{
          type: :agent,
          display_name: "Agent",
          directory: project_directory(),
          dirty: false,
          filetype: :markdown
        }

      _ ->
        buffer_content_context(state)
    end
  end

  @spec buffer_content_context(t()) :: content_context()
  defp buffer_content_context(%__MODULE__{workspace: %{buffers: %{active: buf}}})
       when is_pid(buf) do
    path = Buffer.file_path(buf)
    name = Buffer.buffer_name(buf)
    dirty = Buffer.dirty?(buf)
    filetype = Buffer.filetype(buf)

    display_name = if path, do: Path.basename(path), else: name || "[no file]"
    directory = if path, do: path |> Path.dirname() |> Path.basename(), else: ""

    %{
      type: :buffer,
      display_name: display_name,
      directory: directory,
      dirty: dirty,
      filetype: filetype || :text
    }
  end

  defp buffer_content_context(_state) do
    %{
      type: :buffer,
      display_name: "[no file]",
      directory: "",
      dirty: false,
      filetype: :text
    }
  end

  @spec project_directory() :: String.t()
  defp project_directory do
    case Minga.Project.root() do
      nil -> ""
      root -> Path.basename(root)
    end
  catch
    :exit, _ -> ""
  end

  # ── Window delegates ────────────────────────────────────────────────────────
  # Pure window-only logic lives in `Windows`. These delegators keep the
  # call-site API stable so callers pass the full editor state.

  @doc "Returns the active window struct, or nil if windows aren't initialized."
  @spec active_window_struct(t()) :: Window.t() | nil
  def active_window_struct(%__MODULE__{workspace: ws}),
    do: WorkspaceState.active_window_struct(ws)

  @doc "Returns true if the editor has more than one window."
  @spec split?(t()) :: boolean()
  def split?(%__MODULE__{workspace: ws}), do: WorkspaceState.split?(ws)

  @doc "Updates the window struct for the given window id via a mapper function."
  @spec update_window(t(), Window.id(), (Window.t() -> Window.t())) :: t()
  def update_window(%__MODULE__{} = state, id, fun) do
    update_workspace(state, &WorkspaceState.update_window(&1, id, fun))
  end

  @doc """
  Invalidates render caches for all windows.

  Call when the screen layout changes (file tree toggle, agent panel toggle)
  because cached draws contain baked-in absolute coordinates that become
  wrong when column offsets shift.
  """
  @spec invalidate_all_windows(t()) :: t()
  def invalidate_all_windows(%__MODULE__{} = state) do
    update_workspace(state, &WorkspaceState.invalidate_all_windows/1)
  end

  @doc """
  Returns the active window's viewport, falling back to `state.workspace.viewport`
  when no window is active. Use this for scroll commands that need to
  read/write the viewport of the focused window (not the terminal-level
  viewport).
  """
  @spec active_window_viewport(t()) :: Viewport.t()
  def active_window_viewport(%__MODULE__{} = state) do
    case active_window_struct(state) do
      nil -> state.workspace.viewport
      %Window{viewport: vp} -> vp
    end
  end

  @doc """
  Updates the active window's viewport. Falls back to updating
  `state.workspace.viewport` when no window is active.
  """
  @spec put_active_window_viewport(t(), Viewport.t()) :: t()
  def put_active_window_viewport(%__MODULE__{} = state, new_vp) do
    case active_window_struct(state) do
      nil ->
        put_in(state.workspace.viewport, new_vp)

      %Window{id: win_id} ->
        update_window(state, win_id, fn w -> %{w | viewport: new_vp} end)
    end
  end

  @doc """
  Finds the agent chat window in the windows map.

  Returns `{win_id, window}` or `nil` if no agent chat window exists.
  """
  @spec find_agent_chat_window(t()) :: {Window.id(), Window.t()} | nil
  def find_agent_chat_window(%__MODULE__{workspace: %{windows: ws}}) do
    Enum.find_value(ws.map, fn
      {win_id, %Window{content: {:agent_chat, _}} = window} -> {win_id, window}
      _ -> nil
    end)
  end

  @doc """
  Scrolls the agent chat window's viewport by `delta` lines and updates
  pinned state. Delegates to `Window.scroll_viewport/3`.

  Returns the state unchanged if no agent chat window exists.
  """
  @spec scroll_agent_chat_window(t(), integer()) :: t()
  def scroll_agent_chat_window(%__MODULE__{} = state, delta) do
    case find_agent_chat_window(state) do
      nil ->
        state

      {win_id, window} ->
        total_lines = Buffer.line_count(window.buffer)
        updated = Window.scroll_viewport(window, delta, total_lines)
        update_window(state, win_id, fn _ -> updated end)
    end
  end

  # ── Other accessors ───────────────────────────────────────────────────────

  @doc """
  Returns the screen rect for layout computation, excluding the global
  minibuffer row and reserving space for the file tree panel when open.
  """
  @spec screen_rect(t()) :: WindowTree.rect()
  def screen_rect(%__MODULE__{workspace: %{viewport: vp, file_tree: %{tree: nil}}}) do
    {0, 0, vp.cols, vp.rows - 1}
  end

  def screen_rect(%__MODULE__{
        workspace: %{viewport: vp, file_tree: %{tree: %FileTree{width: tw}}}
      }) do
    # Tree occupies columns 0..tw-1, separator at column tw,
    # editor content starts at column tw+1.
    editor_col = tw + 1
    editor_width = max(vp.cols - editor_col, 1)
    {0, editor_col, editor_width, vp.rows - 1}
  end

  @doc "Returns the screen rect for the file tree panel, or nil if closed."
  @spec tree_rect(t()) :: WindowTree.rect() | nil
  def tree_rect(%__MODULE__{workspace: %{file_tree: %{tree: nil}}}), do: nil

  def tree_rect(%__MODULE__{workspace: %{viewport: vp, file_tree: %{tree: %FileTree{width: tw}}}}) do
    # Row 0 is the tab bar; file tree starts at row 1.
    {1, 0, tw, vp.rows - 2}
  end

  # ── Cross-cutting window + buffer helpers ─────────────────────────────────

  @doc """
  Syncs the active window's buffer reference with `state.workspace.buffers.active`.

  Call this after any operation that changes `state.workspace.buffers.active` to keep the
  window tree consistent. No-op when windows aren't initialized.
  """
  @spec sync_active_window_buffer(t()) :: t()
  def sync_active_window_buffer(%__MODULE__{} = state) do
    update_workspace(state, &WorkspaceState.sync_active_window_buffer/1)
  end

  @doc """
  Adds a new buffer and makes it the active buffer for the current window.

  When the active tab is a file tab, the buffer replaces the current
  tab's buffer in-place (like Vim `:e`). When the active tab is an
  agent tab, a new file tab is created and switched to. This matches
  the expected workflow: opening files from the tree or picker reuses
  the current file tab; opening from the agent UI view creates a
  dedicated file tab.
  """
  @spec add_buffer(t(), pid()) :: t()
  def add_buffer(
        %__MODULE__{workspace: %{buffers: bs}, shell_state: %{tab_bar: %TabBar{} = tb}} = state,
        pid
      ) do
    label = buffer_label(pid)
    active_tab = TabBar.active(tb)

    Log.debug(:editor, fn ->
      "[tab] add_buffer label=#{label} tab=#{tb.active_id} kind=#{active_tab.kind}"
    end)

    # Add the buffer to the pool (Buffers.add auto-activates it)
    state = put_in(state.workspace.buffers, Buffers.add(bs, pid))
    state = monitor_buffer(state, pid)

    # Check if a tab for this buffer already exists (by label match).
    # If so, switch to it. Otherwise, create a new tab.
    case find_tab_for_buffer(tb, pid, label) do
      %Tab{id: tab_id} ->
        switch_tab(state, tab_id)

      nil ->
        case active_tab.kind do
          :agent ->
            add_buffer_as_new_tab(state, label)

          :file ->
            add_buffer_as_new_file_tab(state, label)
        end
    end
  end

  def add_buffer(%__MODULE__{workspace: %{buffers: bs} = wspace} = state, pid) do
    %{state | workspace: %{wspace | buffers: Buffers.add(bs, pid)}}
    |> monitor_buffer(pid)
    |> sync_active_window_buffer()
  end

  # Creates a new file tab from a file tab context. Snapshots the current
  # tab, creates a new one, and syncs the buffer into the new tab's window.
  @spec add_buffer_as_new_file_tab(t(), String.t()) :: t()
  defp add_buffer_as_new_file_tab(state, label) do
    tb = tab_bar(state)

    # Snapshot current tab before leaving
    current_ctx = snapshot_tab_context(state)
    tb = TabBar.update_context(tb, tb.active_id, current_ctx)

    # Create file tab (TabBar.add auto-activates it)
    {tb, new_tab} = TabBar.add(tb, :file, label)
    state = set_tab_bar(state, tb)
    state = sync_active_window_buffer(state)

    # Snapshot the new tab's context
    new_ctx = snapshot_tab_context(state)
    tb = TabBar.update_context(tab_bar(state), new_tab.id, new_ctx)

    Log.debug(:editor, fn ->
      "[tab] add_buffer new file tab=#{new_tab.id} label=#{label}"
    end)

    set_tab_bar(state, tb)
  end

  # Finds an existing file tab that shows the same buffer (by label match).
  # Returns the tab or nil.
  @spec find_tab_for_buffer(TabBar.t(), pid(), String.t()) :: Tab.t() | nil
  defp find_tab_for_buffer(%TabBar{tabs: tabs}, _pid, label) do
    Enum.find(tabs, fn tab ->
      tab.kind == :file and tab.label == label
    end)
  end

  # Updates the active file tab's label to match the current buffer name.
  # No-op if there's no tab bar or the active tab isn't a file tab.
  @spec sync_active_tab_label(t()) :: t()
  defp sync_active_tab_label(%__MODULE__{shell_state: %{tab_bar: nil}} = state), do: state

  defp sync_active_tab_label(
         %__MODULE__{shell_state: %{tab_bar: tb}, workspace: %{buffers: bs}} = state
       ) do
    case TabBar.active(tb) do
      %Tab{kind: :file} ->
        label = buffer_label(bs.active)
        set_tab_bar(state, TabBar.update_label(tb, tb.active_id, label))

      _ ->
        state
    end
  end

  # Creates a new file tab and switches to it. Used when the active tab
  # is an agent tab and we need a dedicated file tab for the buffer.
  @spec add_buffer_as_new_tab(t(), String.t()) :: t()
  defp add_buffer_as_new_tab(state, label) do
    tb = tab_bar(state)

    # Snapshot current tab before leaving.
    current_ctx = snapshot_tab_context(state)
    tb = TabBar.update_context(tb, tb.active_id, current_ctx)

    # Create file tab (TabBar.add auto-activates it)
    {tb, new_tab} = TabBar.add(tb, :file, label)

    # Leave agent UI view: reset to editor scope.
    state = AgentAccess.update_agent_ui(state, fn _ -> UIState.new() end)
    state = put_in(state.workspace.keymap_scope, :editor)
    state = set_tab_bar(state, tb)
    state = sync_active_window_buffer(state)

    # Snapshot the new tab's context.
    new_ctx = snapshot_tab_context(state)
    tb = TabBar.update_context(tab_bar(state), new_tab.id, new_ctx)

    Log.debug(:editor, fn ->
      "[tab] add_buffer new tab=#{new_tab.id} label=#{label}"
    end)

    set_tab_bar(state, tb)
  end

  @doc """
  Switches to the buffer at `idx`, making it active for the current window.

  Centralizes `Buffers.switch_to` + window sync so callers don't need to
  remember to call `sync_active_window_buffer/1`.
  """
  @spec switch_buffer(t(), non_neg_integer()) :: t()
  def switch_buffer(%__MODULE__{} = state, idx) do
    state = update_workspace(state, &WorkspaceState.switch_buffer(&1, idx))
    sync_active_tab_label(state)
  end

  @doc """
  Snapshots the active buffer's cursor into the active window struct.

  Call this before rendering split views so inactive windows have a fresh
  cursor position for the active window when it becomes inactive later.
  """
  @spec sync_active_window_cursor(t()) :: t()
  def sync_active_window_cursor(%__MODULE__{workspace: %{buffers: %{active: nil}}} = state),
    do: state

  def sync_active_window_cursor(
        %__MODULE__{
          workspace:
            %{windows: %{map: windows, active: id} = ws, buffers: %{active: buf}} = wspace
        } = state
      ) do
    case Map.fetch(windows, id) do
      {:ok, window} ->
        cursor = Buffer.cursor(buf)

        %{
          state
          | workspace: %{
              wspace
              | windows: %{ws | map: Map.put(windows, id, %{window | cursor: cursor})}
            }
        }

      :error ->
        state
    end
  catch
    :exit, _ -> state
  end

  @doc """
  Switches focus to the given window, saving the current cursor to the
  outgoing window and restoring the target window's stored cursor.

  No-op if `target_id` is already the active window or windows aren't set up.
  """
  @spec focus_window(t(), Window.id()) :: t()
  def focus_window(%__MODULE__{workspace: %{windows: %{active: active}}} = state, target_id)
      when target_id == active,
      do: state

  def focus_window(%__MODULE__{workspace: %{buffers: %{active: nil}}} = state, _target_id),
    do: state

  def focus_window(
        %__MODULE__{
          workspace: %{windows: %{map: windows, active: old_id} = ws, buffers: buffers} = wspace
        } = state,
        target_id
      ) do
    case {Map.fetch(windows, old_id), Map.fetch(windows, target_id)} do
      {{:ok, old_win}, {:ok, target_win}} ->
        # Save current cursor to outgoing window
        current_cursor = Buffer.cursor(buffers.active)
        windows = Map.put(windows, old_id, %{old_win | cursor: current_cursor})

        # Restore target window's cursor into its buffer
        Buffer.move_to(target_win.buffer, target_win.cursor)

        # Derive keymap_scope from the target window's content type.
        # Agent chat windows use :agent scope; buffer windows use the
        # current scope (preserving :file_tree if the tree is focused).
        scope = scope_for_content(target_win.content, wspace.keymap_scope)

        %{
          state
          | workspace: %{
              wspace
              | windows: %{ws | map: windows, active: target_id},
                buffers: %{buffers | active: target_win.buffer},
                keymap_scope: scope
            }
        }

      _ ->
        state
    end
  end

  @doc """
  Derives the keymap scope from a window's content type.

  Agent chat windows always use `:agent` scope. Buffer windows use
  `:editor` when coming from `:agent` scope, and preserve the current
  scope otherwise (e.g., `:file_tree` stays as `:file_tree`).
  """
  @spec scope_for_content(Content.t(), Minga.Keymap.Scope.scope_name()) ::
          Minga.Keymap.Scope.scope_name()
  defdelegate scope_for_content(content, current_scope), to: WorkspaceState

  @doc """
  Returns the appropriate keymap scope for the active window's content type.

  Used when leaving the file tree (toggle, close, navigate right) to restore
  the correct scope. Returns :agent for agent chat windows, :editor otherwise.
  """
  @spec scope_for_active_window(t()) :: atom()
  def scope_for_active_window(%{workspace: ws}) do
    WorkspaceState.scope_for_active_window(ws)
  end

  @spec buffer_label(pid()) :: String.t()
  defp buffer_label(pid) when is_pid(pid) do
    live_buffer_label(pid)
  catch
    :exit, _ -> "[dead]"
  end

  defp buffer_label(_), do: "[unknown]"

  @spec live_buffer_label(pid()) :: String.t()
  defp live_buffer_label(pid) do
    case Buffer.buffer_name(pid) do
      nil ->
        case Buffer.file_path(pid) do
          nil -> "[no file]"
          path -> Path.basename(path)
        end

      name ->
        name
    end
  end

  # ── Tab bar helpers ───────────────────────────────────────────────────────

  @doc """
  Captures the current per-tab fields into a context map.

  The returned map is stored in the outgoing tab so it can be restored
  when the user switches back.
  """
  @spec snapshot_tab_context(t()) :: Tab.context()
  def snapshot_tab_context(%__MODULE__{workspace: ws}) do
    snapshot_workspace_fields(ws)
  end

  # Internal: snapshots tab fields without syncing. Used by switch_tab.
  @spec snapshot_tab_context_no_sync(t()) :: Tab.context()
  defp snapshot_tab_context_no_sync(%__MODULE__{workspace: ws}) do
    snapshot_workspace_fields(ws)
  end

  @spec snapshot_workspace_fields(WorkspaceState.t()) :: Tab.context()
  defp snapshot_workspace_fields(%WorkspaceState{} = ws) do
    Map.from_struct(ws)
  end

  @doc """
  Writes a tab context back into the live editor state.

  The context carries workspace fields as a flat map. Empty context means a
  brand-new tab; we build defaults with the current active buffer and
  viewport dimensions.

  Backward compatibility: old contexts with nested structure are migrated
  to the new flat format via `maybe_migrate_legacy_context/2`.
  """
  @spec restore_tab_context(t(), Tab.context()) :: t()
  def restore_tab_context(%__MODULE__{} = state, context) when is_map(context) do
    context =
      if map_size(context) == 0 do
        build_file_tab_defaults(state)
      else
        context
        |> maybe_migrate_legacy_context(state)
        |> maybe_migrate_vim_fields()
      end

    # Build a new workspace from the context fields
    ws = state.workspace

    new_ws =
      Enum.reduce(WorkspaceState.field_names(), ws, fn field, acc ->
        case Map.fetch(context, field) do
          {:ok, value} -> Map.put(acc, field, value)
          :error -> acc
        end
      end)

    %{state | workspace: new_ws}
  end

  # Builds a file-tab context for a brand-new tab. Returns the flat format
  # with per-tab fields directly.
  @spec build_file_tab_defaults(t()) :: Tab.context()
  defp build_file_tab_defaults(state) do
    win_id = state.workspace.windows.next_id
    rows = state.workspace.viewport.rows
    cols = state.workspace.viewport.cols
    buf = state.workspace.buffers.active

    windows =
      if buf do
        try do
          window = Window.new(win_id, buf, max(rows, 1), max(cols, 1))

          %Windows{
            tree: WindowTree.new(win_id),
            map: %{win_id => window},
            active: win_id,
            next_id: win_id + 1
          }
        catch
          :exit, _ -> %Windows{}
        end
      else
        %Windows{}
      end

    %{
      keymap_scope: :editor,
      buffers: %Buffers{
        active: buf,
        list: if(buf, do: [buf], else: []),
        active_index: state.workspace.buffers.active_index
      },
      windows: windows,
      file_tree: %FileTreeState{},
      viewport: state.workspace.viewport,
      mouse: %Mouse{},
      highlight: %Highlighting{},
      lsp_pending: %{},
      completion: nil,
      completion_trigger: CompletionTrigger.new(),
      injection_ranges: %{},
      search: %Search{},
      pending_conflict: nil,
      editing: VimState.new(),
      document_highlights: nil,
      agent_ui: UIState.new()
    }
  end

  @doc """
  Builds a complete per-tab context for an agent tab.

  Used by agent tab creation paths to ensure all `@per_tab_fields` are
  populated. Accepts a pre-built `Windows` struct for the agent chat
  window and the agent buffer pid.
  """
  @spec build_agent_tab_defaults(t(), Windows.t(), pid() | nil) :: Tab.context()
  def build_agent_tab_defaults(state, windows, agent_buf) do
    %{
      keymap_scope: :agent,
      buffers: %Buffers{
        active: agent_buf,
        list: if(agent_buf, do: [agent_buf], else: []),
        active_index: 0
      },
      windows: windows,
      file_tree: %FileTreeState{},
      viewport: state.workspace.viewport,
      mouse: %Mouse{},
      highlight: %Highlighting{},
      lsp_pending: %{},
      completion: nil,
      completion_trigger: CompletionTrigger.new(),
      injection_ranges: %{},
      search: %Search{},
      pending_conflict: nil,
      editing: VimState.new(),
      document_highlights: nil,
      agent_ui: UIState.new()
    }
  end

  # Migrates legacy contexts (old nested format or oldest
  # bare-field format) to the new flat format. If the context already
  # has the :buffers key (new format), returns it unchanged.
  @spec maybe_migrate_legacy_context(Tab.context(), t()) :: Tab.context()
  defp maybe_migrate_legacy_context(%{buffers: _} = context, _state), do: context

  defp maybe_migrate_legacy_context(%{surface_state: %{buffers: _} = ss} = context, _state) do
    # Extract fields from old nested snapshot format
    vim_map = ss.editing || %{}

    vim = %VimState{
      mode: Map.get(vim_map, :mode, :normal),
      mode_state: Map.get(vim_map, :mode_state, Mode.initial_state()),
      reg: Map.get(vim_map, :reg, %Registers{}),
      marks: Map.get(vim_map, :marks, %{}),
      last_jump_pos: Map.get(vim_map, :last_jump_pos),
      last_find_char: Map.get(vim_map, :last_find_char)
    }

    %{
      keymap_scope: Map.get(context, :keymap_scope, :editor),
      buffers: ss.buffers,
      windows: ss.windows,
      file_tree: ss.file_tree,
      viewport: ss.viewport,
      mouse: Map.get(ss, :mouse, %Mouse{}),
      highlight: Map.get(ss, :highlight, %Highlighting{}),
      lsp_pending: Map.get(ss, :lsp_pending, %{}),
      completion: Map.get(ss, :completion),
      completion_trigger: Map.get(ss, :completion_trigger, CompletionTrigger.new()),
      injection_ranges: Map.get(ss, :injection_ranges, %{}),
      search: Map.get(ss, :search, %Search{}),
      pending_conflict: Map.get(ss, :pending_conflict),
      editing: vim
    }
  end

  defp maybe_migrate_legacy_context(context, state) do
    # Oldest format: bare fields like :active_buffer, :windows, :mode
    ws = state.workspace

    ws = maybe_restore_ws(ws, :windows, context)
    ws = maybe_restore_ws(ws, :file_tree, context)

    ws =
      case Map.fetch(context, :active_buffer) do
        {:ok, buf_pid} ->
          idx = Map.get(context, :active_buffer_index, ws.buffers.active_index)
          %{ws | buffers: %{ws.buffers | active: buf_pid, active_index: idx}}

        :error ->
          ws
      end

    ws = %{ws | keymap_scope: Map.get(context, :keymap_scope, :editor)}

    # Build vim state from old fields (will be migrated by maybe_migrate_vim_fields)
    # Preserve vim-related fields from the original context so they can be migrated
    # Drop the vim field from the snapshot so maybe_migrate_vim_fields will migrate the flat fields
    snapshot_workspace_fields(ws)
    |> Map.drop([:vim, :editing])
    |> Map.merge(
      Map.take(context, [:mode, :mode_state, :reg, :marks, :last_jump_pos, :last_find_char])
    )
  end

  @spec log_switch_tab(TabBar.t(), Tab.id(), Tab.id()) :: :ok
  defp log_switch_tab(tb, current_id, target_id) do
    Log.debug(:editor, fn ->
      from = format_tab_ref(TabBar.active(tb))
      to = format_tab_ref(TabBar.get(tb, target_id))
      "[tab] switch_tab #{current_id}(#{from}) -> #{target_id}(#{to})"
    end)
  end

  @spec format_tab_ref(Tab.t() | nil) :: String.t()
  defp format_tab_ref(%{kind: kind, label: label}), do: "#{kind}:#{label}"
  defp format_tab_ref(nil), do: "nil"

  @spec log_switch_tab_result(t()) :: :ok
  defp log_switch_tab_result(state) do
    Log.debug(:editor, fn ->
      "[tab] switch_tab restored: scope=#{state.workspace.keymap_scope} buf=#{inspect(state.workspace.buffers.active)}"
    end)
  end

  # Restores a workspace field from a context map.
  @spec maybe_restore_ws(WorkspaceState.t(), atom(), Tab.context()) :: WorkspaceState.t()
  defp maybe_restore_ws(ws, key, context) do
    case Map.fetch(context, key) do
      {:ok, value} -> Map.put(ws, key, value)
      :error -> ws
    end
  end

  # Migrates old contexts with separate vim fields to the new VimState substruct.
  # The :editing and :vim guards are defensive: earlier migration steps strip
  # these keys before calling here, but persisted session data may have them.
  @dialyzer {:no_match, maybe_migrate_vim_fields: 1}
  @spec maybe_migrate_vim_fields(Tab.context()) :: Tab.context()
  defp maybe_migrate_vim_fields(%{editing: _} = context), do: context
  defp maybe_migrate_vim_fields(%{vim: _} = context), do: context

  defp maybe_migrate_vim_fields(%{mode: mode} = context) do
    vim = %VimState{
      mode: mode,
      mode_state: Map.get(context, :mode_state, Mode.initial_state()),
      reg: Map.get(context, :reg, %Registers{}),
      marks: Map.get(context, :marks, %{}),
      last_jump_pos: Map.get(context, :last_jump_pos),
      last_find_char: Map.get(context, :last_find_char)
    }

    context
    |> Map.drop([
      :mode,
      :mode_state,
      :reg,
      :marks,
      :last_jump_pos,
      :last_find_char,
      :change_recorder,
      :macro_recorder
    ])
    |> Map.put(:editing, vim)
  end

  defp maybe_migrate_vim_fields(context), do: context

  @doc """
  Switches to the tab with `target_id`.

  Snapshots the current tab's context, stores it, updates the tab bar's
  active pointer, and restores the target tab's saved context into the
  live editor state. Invalidates layout and window caches since the
  entire visual context changes.
  """
  @spec switch_tab(t(), Tab.id()) :: t()
  def switch_tab(%__MODULE__{shell_state: %{tab_bar: nil}} = state, _target_id), do: state

  def switch_tab(%__MODULE__{shell_state: %{tab_bar: tb}} = state, target_id) do
    current_id = tb.active_id

    if current_id == target_id do
      state
    else
      log_switch_tab(tb, current_id, target_id)

      # Stop the outgoing agent's spinner timer so it doesn't leak.
      # The timer ref is in state.agent (the live field) before snapshot.
      state = stop_outgoing_spinner(state)

      # Snapshot current tab
      context = snapshot_tab_context_no_sync(state)
      tb = TabBar.update_context(tb, current_id, context)

      # Switch pointer
      tb = TabBar.switch_to(tb, target_id)

      # Restore target tab's context
      %Tab{} = target = TabBar.active(tb)
      state = set_tab_bar(state, tb)

      state = restore_tab_context(state, target.context)

      # If switching to an agent tab, rebuild agent state from the
      # Session process (the source of truth for status, pending
      # approval, and error).
      state = rebuild_agent_from_session(state, target)

      # Clear attention flag on the tab we're switching to.
      state =
        set_tab_bar(
          state,
          TabBar.update_tab(tab_bar(state), target_id, &Tab.set_attention(&1, false))
        )

      # Restart spinner for incoming agent if it's busy.
      state = maybe_restart_incoming_spinner(state)

      log_switch_tab_result(state)

      state
      |> invalidate_all_windows()
      |> Map.put(:layout, nil)
    end
  end

  @doc """
  Returns the active tab, or nil if the tab bar isn't initialized.
  """
  @spec active_tab(t()) :: Tab.t() | nil
  def active_tab(%__MODULE__{shell_state: %{tab_bar: nil}}), do: nil
  def active_tab(%__MODULE__{shell_state: %{tab_bar: tb}}), do: TabBar.active(tb)

  @doc "Finds a file tab whose context has the given buffer pid as active."
  @spec find_tab_by_buffer(t(), pid()) :: Tab.t() | nil
  def find_tab_by_buffer(%__MODULE__{shell_state: %{tab_bar: nil}}, _pid), do: nil

  def find_tab_by_buffer(%__MODULE__{shell_state: %{tab_bar: tb}}, pid) do
    Enum.find(tb.tabs, fn tab ->
      tab.kind == :file and tab_has_active_buffer?(tab, pid)
    end)
  end

  @spec tab_has_active_buffer?(Tab.t(), pid()) :: boolean()
  defp tab_has_active_buffer?(tab, pid) do
    case tab.context do
      %{buffers: %{active: ^pid}} -> true
      %{surface_state: %{buffers: %{active: ^pid}}} -> true
      %{active_buffer: ^pid} -> true
      _ -> false
    end
  end

  @doc """
  Returns the kind of the active tab, or `:file` as default.
  """
  @spec active_tab_kind(t()) :: Tab.kind()
  def active_tab_kind(%__MODULE__{shell_state: %{tab_bar: nil}}), do: :file

  def active_tab_kind(%__MODULE__{shell_state: %{tab_bar: tb}}) do
    %Tab{kind: kind} = TabBar.active(tb)
    kind
  end

  # ── Spinner lifecycle for tab switching ──────────────────────────────────────

  @spec stop_outgoing_spinner(t()) :: t()
  defp stop_outgoing_spinner(%__MODULE__{} = state) do
    AgentAccess.update_agent(state, &AgentState.stop_spinner_timer/1)
  end

  @spec maybe_restart_incoming_spinner(t()) :: t()
  defp maybe_restart_incoming_spinner(state) do
    agent = AgentAccess.agent(state)

    if AgentState.busy?(agent) and agent.spinner_timer == nil do
      AgentAccess.update_agent(state, &AgentState.start_spinner_timer/1)
    else
      state
    end
  end

  @doc """
  Sets the `Tab.session` field for the tab with the given id.

  Called when a session is started or switched so `find_by_session/2` works.
  """
  @spec set_tab_session(t(), Tab.id(), pid() | nil) :: t()
  def set_tab_session(%__MODULE__{shell_state: %{tab_bar: tb}} = state, tab_id, session_pid) do
    set_tab_bar(state, TabBar.update_tab(tb, tab_id, &Tab.set_session(&1, session_pid)))
  end

  # Rebuilds state.agent from the Session process when switching to an
  # agent tab. The Session is the source of truth for status, pending
  # approval, and error. The editor's agent field is a rendering cache,
  # not a source of truth.
  @spec rebuild_agent_from_session(t(), Tab.t()) :: t()
  defp rebuild_agent_from_session(state, %Tab{kind: :agent, session: session_pid})
       when is_pid(session_pid) do
    snapshot =
      try do
        AgentSession.editor_snapshot(session_pid)
      catch
        :exit, _ -> nil
      end

    if snapshot do
      AgentAccess.update_agent(state, fn agent ->
        %{
          agent
          | session: session_pid,
            status: snapshot.status,
            pending_approval: snapshot.pending_approval,
            error: snapshot.error
        }
      end)
    else
      AgentAccess.update_agent(state, fn agent ->
        %{agent | session: session_pid}
      end)
    end
  end

  defp rebuild_agent_from_session(state, _tab), do: state

  # ── Mode transitions ────────────────────────────────────────────────────────

  @doc """
  Transitions the editor to a new vim mode.

  Convenience wrapper around `VimState.transition/3` that operates on
  the full EditorState. This is the preferred API for call sites that
  already have an EditorState.

  ## Examples

      # Simple transition (uses default mode_state):
      EditorState.transition_mode(state, :normal)
      EditorState.transition_mode(state, :insert)

      # With explicit mode_state (required for visual, search, etc.):
      EditorState.transition_mode(state, :visual, %VisualState{...})
  """
  @spec transition_mode(t(), Mode.mode(), Mode.state() | nil) :: t()
  def transition_mode(%__MODULE__{} = state, mode, mode_state \\ nil) do
    update_workspace(state, &WorkspaceState.transition_mode(&1, mode, mode_state))
  end

  # ── Tool prompt helpers ──────────────────────────────────────────────────────

  @doc """
  Returns true if the given tool should NOT be prompted for installation.

  A tool is skipped when it's already declined this session, already
  installed, currently being installed, or already in the prompt queue.
  """
  @spec skip_tool_prompt?(t(), atom()) :: boolean()
  def skip_tool_prompt?(%__MODULE__{shell_state: ss}, tool_name) do
    MapSet.member?(ss.tool_declined, tool_name) or
      ToolManager.installed?(tool_name) or
      MapSet.member?(ToolManager.installing(), tool_name) or
      tool_name in ss.tool_prompt_queue
  end
end
