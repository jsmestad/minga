defmodule Minga.Editor.State do
  @moduledoc """
  Internal state for the Editor GenServer.

  ## Field categories

  EditorState fields fall into two categories:

  **Workspace fields** live in `state.workspace` (`Minga.Workspace.State`).
  These are saved/restored when switching tabs. Each tab carries a
  snapshot of the workspace so switching tabs restores the full editing
  context.

  **Global fields** are shared across all tabs and never snapshotted:
  `port_manager`, `theme`, `status_msg`, `render_timer`, `focus_stack`,
  `tab_bar`, `capabilities`, `layout`, `modeline_click_regions`,
  `tab_bar_click_regions`, `agent`, `picker_ui`, `whichkey`.

  ## Composed sub-structs

  * `Minga.Workspace.State`           — per-tab editing context (buffers, windows, vim, etc.)
  * `Minga.Editor.State.Picker`       — picker instance, source, restore index
  * `Minga.Editor.State.WhichKey`     — which-key popup node, timer, visibility
  * `Minga.Editor.State.Registers`    — named registers and active register selection
  """

  alias Minga.Agent.Session, as: AgentSession
  alias Minga.Agent.UIState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.CompletionTrigger
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
  alias Minga.FileTree
  alias Minga.Log
  alias Minga.Mode
  alias Minga.Panel.MessageStore
  alias Minga.Port.Capabilities
  alias Minga.Tool.Manager, as: ToolManager
  alias Minga.Workspace
  alias Minga.Workspace.State, as: WorkspaceState

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @typedoc "A document highlight range from the LSP server."
  @type document_highlight :: Minga.LSP.DocumentHighlight.t()

  @enforce_keys [:port_manager, :workspace]
  defstruct backend: :headless,
            port_manager: nil,
            workspace: nil,
            picker_ui: %Picker{},
            prompt_ui: %Prompt{},
            whichkey: %WhichKey{},
            theme: Minga.Theme.get!(:doom_one),
            status_msg: nil,
            render_timer: nil,
            warning_popup_timer: nil,
            bottom_panel: %Minga.Editor.BottomPanel{},
            message_store: %MessageStore{},
            git_status_panel: nil,
            git_remote_op: nil,
            lsp_status: :none,
            lsp_server_statuses: %{},
            parser_status: :available,
            hover_popup: nil,
            signature_help: nil,
            focus_stack: [],
            tab_bar: nil,
            capabilities: %Capabilities{},
            layout: nil,
            modeline_click_regions: [],
            tab_bar_click_regions: [],
            agent: %AgentState{},
            dashboard: nil,
            nav_flash: nil,
            last_cursor_line: nil,
            last_test_command: nil,
            pending_quit: nil,
            buffer_monitors: %{},
            face_override_registries: %{},
            font_registry: Minga.FontRegistry.new(),
            highlight_debounce_timer: nil,
            inlay_hint_debounce_timer: nil,
            last_inlay_viewport_top: nil,
            code_lenses: [],
            inlay_hints: [],
            selection_ranges: nil,
            selection_range_index: 0,
            tool_declined: MapSet.new(),
            tool_prompt_queue: [],
            session_timer: nil,
            swap_dir: nil,
            session_dir: nil,
            suppress_tool_prompts: false

  @type backend :: :tui | :native_gui | :headless

  @type t :: %__MODULE__{
          backend: backend(),
          port_manager: GenServer.server() | nil,
          workspace: WorkspaceState.t(),
          picker_ui: Picker.t(),
          prompt_ui: Prompt.t(),
          whichkey: WhichKey.t(),
          theme: Minga.Theme.t(),
          status_msg: String.t() | nil,
          render_timer: reference() | nil,
          warning_popup_timer: reference() | nil,
          bottom_panel: Minga.Editor.BottomPanel.t(),
          message_store: MessageStore.t(),
          git_status_panel: Minga.Port.Protocol.GUI.git_status_data() | nil,
          git_remote_op:
            {msg_ref :: reference(), task_monitor :: reference(),
             {git_root :: String.t(), success_msg :: String.t(), error_prefix :: String.t()}}
            | nil,
          lsp_status: Minga.Editor.Modeline.lsp_status(),
          lsp_server_statuses: %{
            atom() => :starting | :initializing | :ready | :crashed
          },
          parser_status: Minga.Editor.Modeline.parser_status(),
          hover_popup: Minga.Editor.HoverPopup.t() | nil,
          signature_help: Minga.Editor.SignatureHelp.t() | nil,
          focus_stack: [module()],
          tab_bar: TabBar.t() | nil,
          capabilities: Capabilities.t(),
          layout: Minga.Editor.Layout.t() | nil,
          modeline_click_regions: [Minga.Editor.Modeline.click_region()],
          tab_bar_click_regions: [Minga.Editor.TabBarRenderer.click_region()],
          agent: AgentState.t(),
          dashboard: Minga.Editor.Dashboard.state() | nil,
          nav_flash: Minga.Editor.NavFlash.t() | nil,
          last_cursor_line: non_neg_integer() | nil,
          last_test_command: {String.t(), String.t()} | nil,
          pending_quit: :quit | :quit_all | nil,
          buffer_monitors: %{pid() => reference()},
          face_override_registries: %{pid() => Minga.Face.Registry.t()},
          highlight_debounce_timer: reference() | nil,
          inlay_hint_debounce_timer: reference() | nil,
          last_inlay_viewport_top: non_neg_integer() | nil,
          code_lenses: [map()],
          inlay_hints: [map()],
          selection_ranges: [map()] | nil,
          selection_range_index: non_neg_integer(),
          font_registry: Minga.FontRegistry.t(),
          tool_declined: MapSet.t(atom()),
          tool_prompt_queue: [atom()],
          session_timer: reference() | nil,
          swap_dir: String.t() | nil,
          session_dir: String.t() | nil,
          suppress_tool_prompts: boolean()
        }

  # ── Workspace helpers ────────────────────────────────────────────────────

  @doc """
  Returns the workspace state.

  Convenience accessor so callers can write `State.ws(state)` for
  read-heavy code paths instead of `state.workspace`.
  """
  @spec ws(t()) :: WorkspaceState.t()
  def ws(%__MODULE__{workspace: ws}), do: ws

  @doc """
  Updates the workspace via a mapper function.

  Convenience for the common `%{state | workspace: %{state.workspace | ...}}`
  pattern. Use when updating multiple workspace fields at once.
  """
  @spec update_workspace(t(), (WorkspaceState.t() -> WorkspaceState.t())) :: t()
  def update_workspace(%__MODULE__{workspace: ws} = state, fun) when is_function(fun, 1) do
    %{state | workspace: fun.(ws)}
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
  def find_buffer_by_path(%__MODULE__{workspace: %{buffers: %{list: buffers}}}, file_path) do
    Enum.find_index(buffers, fn buf ->
      try do
        BufferServer.file_path(buf) == file_path
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
      {BufferServer, file_path: file_path}
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
  def remove_dead_buffer(%__MODULE__{buffer_monitors: monitors} = state, pid) do
    # Clean up monitor ref (EditorState concern)
    monitors = Map.delete(monitors, pid)

    # Delegate workspace buffer cleanup to Workspace (pure calculation)
    updated_ws = Workspace.remove_dead_buffer(state.workspace, pid)

    state = %{state | workspace: updated_ws, buffer_monitors: monitors}

    # Clear agent buffer or prompt buffer if the dead pid matches
    # (EditorState concern: agent state is global, not per-workspace)
    state =
      if state.agent != nil and state.agent.buffer == pid do
        AgentAccess.update_agent(state, fn a -> %{a | buffer: nil} end)
      else
        state
      end

    if state.workspace.agent_ui != nil and state.workspace.agent_ui.panel.prompt_buffer == pid do
      AgentAccess.update_panel(state, fn p -> %{p | prompt_buffer: nil} end)
    else
      state
    end
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
    path = BufferServer.file_path(buf)
    name = BufferServer.buffer_name(buf)
    dirty = BufferServer.dirty?(buf)
    filetype = BufferServer.filetype(buf)

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
  # Pure window logic lives in `Minga.Workspace`. These delegates unwrap
  # the workspace, call the calculation, and rewrap the result.

  @doc "Returns the active window struct, or nil if windows aren't initialized."
  @spec active_window_struct(t()) :: Window.t() | nil
  def active_window_struct(%__MODULE__{workspace: ws}), do: Workspace.active_window_struct(ws)

  @doc "Returns true if the editor has more than one window."
  @spec split?(t()) :: boolean()
  def split?(%__MODULE__{workspace: ws}), do: Workspace.split?(ws)

  @doc "Updates the window struct for the given window id via a mapper function."
  @spec update_window(t(), Window.id(), (Window.t() -> Window.t())) :: t()
  def update_window(%__MODULE__{workspace: ws} = state, id, fun) do
    %{state | workspace: Workspace.update_window(ws, id, fun)}
  end

  @doc """
  Invalidates render caches for all windows.

  Call when the screen layout changes (file tree toggle, agent panel toggle)
  because cached draws contain baked-in absolute coordinates that become
  wrong when column offsets shift.
  """
  @spec invalidate_all_windows(t()) :: t()
  def invalidate_all_windows(%__MODULE__{workspace: ws} = state) do
    %{state | workspace: Workspace.invalidate_all_windows(ws)}
  end

  @doc """
  Returns the active window's viewport, falling back to `state.workspace.viewport`
  when no window is active. Use this for scroll commands that need to
  read/write the viewport of the focused window (not the terminal-level
  viewport).
  """
  @spec active_window_viewport(t()) :: Viewport.t()
  def active_window_viewport(%__MODULE__{workspace: ws}) do
    Workspace.active_window_viewport(ws)
  end

  @doc """
  Updates the active window's viewport. Falls back to updating
  `state.workspace.viewport` when no window is active.
  """
  @spec put_active_window_viewport(t(), Viewport.t()) :: t()
  def put_active_window_viewport(%__MODULE__{workspace: ws} = state, new_vp) do
    %{state | workspace: Workspace.put_active_window_viewport(ws, new_vp)}
  end

  @doc """
  Finds the agent chat window in the windows map.

  Returns `{win_id, window}` or `nil` if no agent chat window exists.
  """
  @spec find_agent_chat_window(t()) :: {Window.id(), Window.t()} | nil
  def find_agent_chat_window(%__MODULE__{workspace: ws}) do
    Workspace.find_agent_chat_window(ws)
  end

  @doc """
  Scrolls the agent chat window's viewport by `delta` lines and updates
  pinned state.

  Note: This is an action delegate (calls BufferServer.line_count).
  """
  @spec scroll_agent_chat_window(t(), integer()) :: t()
  def scroll_agent_chat_window(%__MODULE__{} = state, delta) do
    case Workspace.find_agent_chat_window(state.workspace) do
      nil ->
        state

      {_win_id, window} ->
        total_lines = BufferServer.line_count(window.buffer)

        %{
          state
          | workspace: Workspace.scroll_agent_chat_window(state.workspace, delta, total_lines)
        }
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

  def tree_rect(%__MODULE__{
        workspace: %{viewport: vp, file_tree: %{tree: %FileTree{width: tw}}}
      }) do
    # Row 0 is the tab bar; file tree starts at row 1.
    {1, 0, tw, vp.rows - 2}
  end

  # ── Cross-cutting window + buffer helpers ─────────────────────────────────

  @doc """
  Syncs the active window's buffer reference with `state.workspace.buffers.active`.

  Delegates to `Workspace.sync_active_window_buffer/1`.
  """
  @spec sync_active_window_buffer(t()) :: t()
  def sync_active_window_buffer(%__MODULE__{workspace: ws} = state) do
    %{state | workspace: Workspace.sync_active_window_buffer(ws)}
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
  def add_buffer(%__MODULE__{tab_bar: %TabBar{} = tb} = state, pid) do
    label = buffer_label(pid)
    active_tab = TabBar.active(tb)

    Log.debug(:editor, fn ->
      "[tab] add_buffer label=#{label} tab=#{tb.active_id} kind=#{active_tab.kind}"
    end)

    # Add the buffer to the workspace (Workspace.add_buffer handles
    # Buffers.add + window sync as a pure calculation)
    state = %{state | workspace: Workspace.add_buffer(state.workspace, pid)}
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

  def add_buffer(%__MODULE__{} = state, pid) do
    %{state | workspace: Workspace.add_buffer(state.workspace, pid)}
    |> monitor_buffer(pid)
  end

  # Creates a new file tab from a file tab context. Snapshots the current
  # tab, creates a new one, and syncs the buffer into the new tab's window.
  @spec add_buffer_as_new_file_tab(t(), String.t()) :: t()
  defp add_buffer_as_new_file_tab(state, label) do
    tb = state.tab_bar

    # Snapshot current tab before leaving
    current_ctx = snapshot_tab_context(state)
    tb = TabBar.update_context(tb, tb.active_id, current_ctx)

    # Create file tab (TabBar.add auto-activates it)
    {tb, new_tab} = TabBar.add(tb, :file, label)
    state = %{state | tab_bar: tb}
    state = sync_active_window_buffer(state)

    # Snapshot the new tab's context
    new_ctx = snapshot_tab_context(state)
    tb2 = TabBar.update_context(state.tab_bar, new_tab.id, new_ctx)

    Log.debug(:editor, fn ->
      "[tab] add_buffer new file tab=#{new_tab.id} label=#{label}"
    end)

    %{state | tab_bar: tb2}
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
  defp sync_active_tab_label(%__MODULE__{tab_bar: nil} = state), do: state

  defp sync_active_tab_label(%__MODULE__{tab_bar: tb, workspace: %{buffers: bs}} = state) do
    case TabBar.active(tb) do
      %Tab{kind: :file} ->
        label = buffer_label(bs.active)
        %{state | tab_bar: TabBar.update_label(tb, tb.active_id, label)}

      _ ->
        state
    end
  end

  # Creates a new file tab and switches to it. Used when the active tab
  # is an agent tab and we need a dedicated file tab for the buffer.
  @spec add_buffer_as_new_tab(t(), String.t()) :: t()
  defp add_buffer_as_new_tab(state, label) do
    tb = state.tab_bar

    # Snapshot current tab before leaving.
    current_ctx = snapshot_tab_context(state)
    tb = TabBar.update_context(tb, tb.active_id, current_ctx)

    # Create file tab (TabBar.add auto-activates it)
    {tb, new_tab} = TabBar.add(tb, :file, label)

    # Leave agent UI view: reset to editor scope.
    state = AgentAccess.update_agent_ui(state, fn _ -> UIState.new() end)

    state =
      update_workspace(state, fn ws -> %{ws | keymap_scope: :editor} end)
      |> Map.put(:tab_bar, tb)

    state = sync_active_window_buffer(state)

    # Snapshot the new tab's context.
    new_ctx = snapshot_tab_context(state)
    tb2 = TabBar.update_context(state.tab_bar, new_tab.id, new_ctx)

    Log.debug(:editor, fn ->
      "[tab] add_buffer new tab=#{new_tab.id} label=#{label}"
    end)

    %{state | tab_bar: tb2}
  end

  @doc """
  Switches to the buffer at `idx`, making it active for the current window.

  Centralizes `Buffers.switch_to` + window sync so callers don't need to
  remember to call `sync_active_window_buffer/1`.
  """
  @spec switch_buffer(t(), non_neg_integer()) :: t()
  def switch_buffer(%__MODULE__{workspace: ws} = state, idx) do
    state = %{state | workspace: Workspace.switch_buffer(ws, idx)}
    sync_active_tab_label(state)
  end

  @doc """
  Snapshots the active buffer's cursor into the active window struct.

  Call this before rendering split views so inactive windows have a fresh
  cursor position for the active window when it becomes inactive later.

  This is an action delegate: fetches the cursor from BufferServer, then
  delegates to `Workspace.sync_active_window_cursor/2`.
  """
  @spec sync_active_window_cursor(t()) :: t()
  def sync_active_window_cursor(%__MODULE__{workspace: %{buffers: %{active: nil}}} = state),
    do: state

  def sync_active_window_cursor(%__MODULE__{workspace: %{buffers: %{active: buf}} = ws} = state) do
    cursor = BufferServer.cursor(buf)
    %{state | workspace: Workspace.sync_active_window_cursor(ws, cursor)}
  catch
    :exit, _ -> state
  end

  @doc """
  Switches focus to the given window, saving the current cursor to the
  outgoing window and restoring the target window's stored cursor.

  This is an action delegate: fetches the current cursor from BufferServer,
  calls `Workspace.focus_window/3` (pure calculation), then executes
  `BufferServer.move_to/2` as a side effect.

  No-op if `target_id` is already the active window or windows aren't set up.
  """
  @spec focus_window(t(), Window.id()) :: t()
  def focus_window(%__MODULE__{workspace: ws} = state, target_id) do
    # Fetch current cursor (side effect) before the pure calculation
    current_cursor =
      case ws.buffers.active do
        nil -> {0, 0}
        buf -> BufferServer.cursor(buf)
      end

    case Workspace.focus_window(ws, target_id, current_cursor) do
      {^ws, nil} ->
        state

      {updated_ws, target_cursor} ->
        # Restore target window's cursor into its buffer (side effect)
        if target_cursor do
          BufferServer.move_to(updated_ws.buffers.active, target_cursor)
        end

        %{state | workspace: updated_ws}
    end
  end

  @doc """
  Derives the keymap scope from a window's content type.

  Delegates to `Workspace.scope_for_content/2`.
  """
  @spec scope_for_content(Content.t(), Minga.Keymap.Scope.scope_name()) ::
          Minga.Keymap.Scope.scope_name()
  defdelegate scope_for_content(content, current_scope), to: Workspace

  @doc """
  Returns the appropriate keymap scope for the active window's content type.

  Delegates to `Workspace.scope_for_active_window/1`.
  """
  @spec scope_for_active_window(t()) :: atom()
  def scope_for_active_window(%__MODULE__{workspace: ws}) do
    Workspace.scope_for_active_window(ws)
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
    case BufferServer.buffer_name(pid) do
      nil ->
        case BufferServer.file_path(pid) do
          nil -> "[no file]"
          path -> Path.basename(path)
        end

      name ->
        name
    end
  end

  # ── Tab bar helpers ───────────────────────────────────────────────────────

  @doc """
  Captures the current workspace state for tab context storage.

  The returned workspace is stored in the outgoing tab so it can be
  restored when the user switches back.
  """
  @spec snapshot_tab_context(t()) :: Tab.context()
  def snapshot_tab_context(%__MODULE__{workspace: ws}) do
    %{workspace: ws}
  end

  # Internal: snapshots tab fields without syncing. Used by switch_tab.
  @spec snapshot_tab_context_no_sync(t()) :: Tab.context()
  defp snapshot_tab_context_no_sync(%__MODULE__{workspace: ws}) do
    %{workspace: ws}
  end

  @doc """
  Writes a tab context back into the live editor state.

  The context carries a `workspace` key containing a `Workspace.State`
  struct. Empty context means a brand-new tab; we build defaults with
  the current active buffer and viewport dimensions.

  Backward compatibility: old contexts with flat per-tab fields or
  nested structure are migrated to workspace format via
  `maybe_migrate_legacy_context/2`.
  """
  @spec restore_tab_context(t(), Tab.context()) :: t()
  def restore_tab_context(%__MODULE__{} = state, context) when is_map(context) do
    workspace =
      cond do
        map_size(context) == 0 ->
          build_workspace_defaults(state)

        Map.has_key?(context, :workspace) ->
          context.workspace

        true ->
          # Legacy context: migrate flat fields to workspace
          context
          |> maybe_migrate_legacy_context(state)
          |> maybe_migrate_vim_fields()
          |> flat_context_to_workspace(state)
      end

    %{state | workspace: workspace}
  end

  # Converts a flat legacy context map (with per-tab field keys) into a
  # Workspace.State struct. Falls back to current workspace values for
  # any missing fields.
  @spec flat_context_to_workspace(map(), t()) :: WorkspaceState.t()
  defp flat_context_to_workspace(context, %__MODULE__{workspace: current_ws}) do
    ws_fields = WorkspaceState.fields()

    Enum.reduce(ws_fields, current_ws, fn field, ws ->
      case Map.fetch(context, field) do
        {:ok, value} -> Map.put(ws, field, value)
        :error -> ws
      end
    end)
  end

  # Builds a workspace for a brand-new file tab.
  @spec build_workspace_defaults(t()) :: WorkspaceState.t()
  defp build_workspace_defaults(state) do
    ws = state.workspace
    win_id = ws.windows.next_id
    rows = ws.viewport.rows
    cols = ws.viewport.cols
    buf = ws.buffers.active

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

    %WorkspaceState{
      keymap_scope: :editor,
      buffers: %Buffers{
        active: buf,
        list: if(buf, do: [buf], else: []),
        active_index: ws.buffers.active_index
      },
      windows: windows,
      file_tree: %FileTreeState{},
      viewport: ws.viewport,
      mouse: %Mouse{},
      highlight: %Highlighting{},
      lsp_pending: %{},
      completion: nil,
      completion_trigger: CompletionTrigger.new(),
      injection_ranges: %{},
      search: %Search{},
      pending_conflict: nil,
      vim: VimState.new(),
      document_highlights: nil,
      agent_ui: UIState.new()
    }
  end

  @doc """
  Builds a complete workspace for an agent tab.

  Used by agent tab creation paths to ensure all workspace fields are
  populated. Accepts a pre-built `Windows` struct for the agent chat
  window and the agent buffer pid.
  """
  @spec build_agent_tab_defaults(t(), Windows.t(), pid() | nil) :: Tab.context()
  def build_agent_tab_defaults(state, windows, agent_buf) do
    %{
      workspace: %WorkspaceState{
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
        vim: VimState.new(),
        document_highlights: nil,
        agent_ui: UIState.new()
      }
    }
  end

  # Migrates legacy contexts (old nested format or oldest
  # bare-field format) to the new flat format with per-tab field keys.
  # The result is then passed to flat_context_to_workspace/2.
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
      vim: vim
    }
  end

  defp maybe_migrate_legacy_context(context, state) do
    # Oldest format: bare fields like :active_buffer, :windows, :mode
    ws = state.workspace

    windows = Map.get(context, :windows, ws.windows)
    file_tree = Map.get(context, :file_tree, ws.file_tree)

    buffers =
      case Map.fetch(context, :active_buffer) do
        {:ok, buf_pid} ->
          idx = Map.get(context, :active_buffer_index, ws.buffers.active_index)
          %{ws.buffers | active: buf_pid, active_index: idx}

        :error ->
          ws.buffers
      end

    keymap_scope = Map.get(context, :keymap_scope, :editor)

    # Build flat context from migrated fields, preserving vim-related
    # fields so maybe_migrate_vim_fields can handle them
    %{
      keymap_scope: keymap_scope,
      buffers: buffers,
      windows: windows,
      file_tree: file_tree,
      viewport: ws.viewport,
      mouse: Map.get(context, :mouse, ws.mouse),
      highlight: Map.get(context, :highlight, ws.highlight),
      lsp_pending: Map.get(context, :lsp_pending, ws.lsp_pending),
      completion: Map.get(context, :completion, ws.completion),
      completion_trigger: Map.get(context, :completion_trigger, ws.completion_trigger),
      injection_ranges: Map.get(context, :injection_ranges, ws.injection_ranges),
      search: Map.get(context, :search, ws.search),
      pending_conflict: Map.get(context, :pending_conflict, ws.pending_conflict),
      document_highlights: Map.get(context, :document_highlights, ws.document_highlights),
      agent_ui: Map.get(context, :agent_ui, ws.agent_ui)
    }
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

  # Migrates old contexts with separate vim fields to the new VimState substruct
  @spec maybe_migrate_vim_fields(Tab.context()) :: Tab.context()
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
    |> Map.put(:vim, vim)
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
  def switch_tab(%__MODULE__{tab_bar: nil} = state, _target_id), do: state

  def switch_tab(%__MODULE__{tab_bar: tb} = state, target_id) do
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
      state = %{state | tab_bar: tb}

      state = restore_tab_context(state, target.context)

      # If switching to an agent tab, rebuild agent state from the
      # Session process (the source of truth for status, pending
      # approval, and error).
      state = rebuild_agent_from_session(state, target)

      # Clear attention flag on the tab we're switching to.
      state = %{
        state
        | tab_bar: TabBar.update_tab(state.tab_bar, target_id, &Tab.set_attention(&1, false))
      }

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
  def active_tab(%__MODULE__{tab_bar: nil}), do: nil
  def active_tab(%__MODULE__{tab_bar: tb}), do: TabBar.active(tb)

  @doc "Finds a file tab whose context has the given buffer pid as active."
  @spec find_tab_by_buffer(t(), pid()) :: Tab.t() | nil
  def find_tab_by_buffer(%__MODULE__{tab_bar: nil}, _pid), do: nil

  def find_tab_by_buffer(%__MODULE__{tab_bar: tb}, pid) do
    Enum.find(tb.tabs, fn tab ->
      tab.kind == :file and tab_has_active_buffer?(tab, pid)
    end)
  end

  @spec tab_has_active_buffer?(Tab.t(), pid()) :: boolean()
  defp tab_has_active_buffer?(tab, pid) do
    case tab.context do
      %__MODULE__{workspace: %{buffers: %{active: ^pid}}} -> true
      # Legacy formats
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
  def active_tab_kind(%__MODULE__{tab_bar: nil}), do: :file

  def active_tab_kind(%__MODULE__{tab_bar: tb}) do
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
  def set_tab_session(%__MODULE__{tab_bar: tb} = state, tab_id, session_pid) do
    %{state | tab_bar: TabBar.update_tab(tb, tab_id, &Tab.set_session(&1, session_pid))}
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
  def transition_mode(%__MODULE__{workspace: ws} = state, mode, mode_state \\ nil) do
    %{state | workspace: Workspace.transition_mode(ws, mode, mode_state)}
  end

  # ── Tool prompt helpers ──────────────────────────────────────────────────────

  @doc """
  Returns true if the given tool should NOT be prompted for installation.

  A tool is skipped when it's already declined this session, already
  installed, currently being installed, or already in the prompt queue.
  """
  @spec skip_tool_prompt?(t(), atom()) :: boolean()
  def skip_tool_prompt?(%__MODULE__{} = state, tool_name) do
    MapSet.member?(state.tool_declined, tool_name) or
      ToolManager.installed?(tool_name) or
      MapSet.member?(ToolManager.installing(), tool_name) or
      tool_name in state.tool_prompt_queue
  end
end
