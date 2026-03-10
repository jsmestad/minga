defmodule Minga.Editor.State do
  @moduledoc """
  Internal state for the Editor GenServer.

  Holds references to the buffer list, port manager, viewport, modal FSM
  state, which-key popup state, and the yank register.

  ## Composed sub-structs

  Related fields are grouped into internal sub-structs to keep the top-level
  struct manageable:

  * `Minga.Editor.State.Buffers`      — buffer list, active buffer, special buffers
  * `Minga.Editor.State.Picker`       — picker instance, source, restore index
  * `Minga.Editor.State.WhichKey`     — which-key popup node, timer, visibility
  * `Minga.Editor.State.Search`       — last search pattern/direction, project results
  * `Minga.Editor.State.Registers`    — named registers and active register selection
  * `Minga.Editor.State.Windows`      — window tree, window map, active/next id
  * `Minga.Editor.State.Highlighting` — current highlight, version counter, per-buffer cache
  """

  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Completion
  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.CompletionTrigger
  alias Minga.Editor.DocumentSync
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Highlighting
  alias Minga.Editor.State.Mouse
  alias Minga.Editor.State.Picker
  alias Minga.Editor.State.Registers
  alias Minga.Editor.State.Search
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.WhichKey
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.FileTree
  alias Minga.Log

  alias Minga.Mode
  alias Minga.Port.Capabilities
  alias Minga.Theme

  @typedoc "Stored last find-char motion for ; and , repeat."
  @type last_find_char :: {Minga.Mode.State.find_direction(), String.t()} | nil

  @typedoc "Buffer-local marks: outer key is buffer pid, inner key is mark name (single letter)."
  @type marks :: %{pid() => %{String.t() => Document.position()}}

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @enforce_keys [:port_manager, :viewport, :mode, :mode_state]
  defstruct port_manager: nil,
            viewport: nil,
            mode: :normal,
            mode_state: nil,
            buffers: %Buffers{},
            picker_ui: %Picker{},
            whichkey: %WhichKey{},
            search: %Search{},
            reg: %Registers{},
            mouse: %Mouse{},
            last_find_char: nil,
            change_recorder: ChangeRecorder.new(),
            theme: Minga.Theme.get!(:doom_one),
            status_msg: nil,
            pending_conflict: nil,
            marks: %{},
            last_jump_pos: nil,
            macro_recorder: MacroRecorder.new(),
            highlight: %Highlighting{},
            lsp: DocumentSync.new(),
            completion: nil,
            completion_trigger: CompletionTrigger.new(),
            render_timer: nil,
            windows: %Windows{},
            file_tree: %FileTreeState{},
            git_buffers: %{},
            injection_ranges: %{},
            agent: %AgentState{},
            focus_stack: [],
            keymap_scope: :editor,
            agentic: %ViewState{},
            tab_bar: nil,
            capabilities: %Capabilities{},
            layout: nil,
            modeline_click_regions: [],
            tab_bar_click_regions: []

  @type t :: %__MODULE__{
          port_manager: GenServer.server() | nil,
          viewport: Viewport.t(),
          mode: Mode.mode(),
          mode_state: Mode.state(),
          buffers: Buffers.t(),
          picker_ui: Picker.t(),
          whichkey: WhichKey.t(),
          search: Search.t(),
          reg: Registers.t(),
          mouse: Mouse.t(),
          last_find_char: last_find_char(),
          change_recorder: ChangeRecorder.t(),
          theme: Theme.t(),
          status_msg: String.t() | nil,
          pending_conflict: {pid(), String.t()} | nil,
          marks: marks(),
          last_jump_pos: Document.position() | nil,
          macro_recorder: MacroRecorder.t(),
          highlight: Highlighting.t(),
          lsp: DocumentSync.t(),
          completion: Completion.t() | nil,
          completion_trigger: CompletionTrigger.t(),
          render_timer: reference() | nil,
          windows: Windows.t(),
          file_tree: FileTreeState.t(),
          git_buffers: %{pid() => pid()},
          injection_ranges: %{
            pid() => [
              %{start_byte: non_neg_integer(), end_byte: non_neg_integer(), language: String.t()}
            ]
          },
          agent: AgentState.t(),
          focus_stack: [module()],
          keymap_scope: Minga.Keymap.Scope.scope_name(),
          agentic: ViewState.t(),
          tab_bar: TabBar.t() | nil,
          capabilities: Capabilities.t(),
          layout: Minga.Editor.Layout.t() | nil,
          modeline_click_regions: [Minga.Editor.Modeline.click_region()],
          tab_bar_click_regions: [Minga.Editor.TabBarRenderer.click_region()]
        }

  # ── Convenience accessors ─────────────────────────────────────────────────

  @doc "Returns the active buffer pid."
  @spec buffer(t()) :: pid() | nil
  def buffer(%__MODULE__{buffers: %{active: b}}), do: b

  @doc "Returns the buffer list."
  @spec buffers(t()) :: [pid()]
  def buffers(%__MODULE__{buffers: %{list: bs}}), do: bs

  @doc "Returns the active buffer index."
  @spec active_buffer(t()) :: non_neg_integer()
  def active_buffer(%__MODULE__{buffers: %{active_index: idx}}), do: idx

  # ── Window delegates ────────────────────────────────────────────────────────
  # Pure window-only logic lives in `Windows`. These delegators keep the
  # call-site API stable so callers pass the full editor state.

  @doc "Returns the active window struct, or nil if windows aren't initialized."
  @spec active_window_struct(t()) :: Window.t() | nil
  def active_window_struct(%__MODULE__{windows: ws}), do: Windows.active_struct(ws)

  @doc "Returns true if the editor has more than one window."
  @spec split?(t()) :: boolean()
  def split?(%__MODULE__{windows: ws}), do: Windows.split?(ws)

  @doc "Updates the window struct for the given window id via a mapper function."
  @spec update_window(t(), Window.id(), (Window.t() -> Window.t())) :: t()
  def update_window(%__MODULE__{windows: ws} = state, id, fun) do
    %{state | windows: Windows.update(ws, id, fun)}
  end

  @doc """
  Invalidates render caches for all windows.

  Call when the screen layout changes (file tree toggle, agent panel toggle)
  because cached draws contain baked-in absolute coordinates that become
  wrong when column offsets shift.
  """
  @spec invalidate_all_windows(t()) :: t()
  def invalidate_all_windows(%__MODULE__{windows: ws} = state) do
    new_map =
      Map.new(ws.map, fn {id, window} -> {id, Window.invalidate(window)} end)

    %{state | windows: %{ws | map: new_map}}
  end

  # ── Other accessors ───────────────────────────────────────────────────────

  @doc """
  Returns the screen rect for layout computation, excluding the global
  minibuffer row and reserving space for the file tree panel when open.
  """
  @spec screen_rect(t()) :: WindowTree.rect()
  def screen_rect(%__MODULE__{viewport: vp, file_tree: %{tree: nil}}) do
    {0, 0, vp.cols, vp.rows - 1}
  end

  def screen_rect(%__MODULE__{viewport: vp, file_tree: %{tree: %FileTree{width: tw}}}) do
    # Tree occupies columns 0..tw-1, separator at column tw,
    # editor content starts at column tw+1.
    editor_col = tw + 1
    editor_width = max(vp.cols - editor_col, 1)
    {0, editor_col, editor_width, vp.rows - 1}
  end

  @doc "Returns the screen rect for the file tree panel, or nil if closed."
  @spec tree_rect(t()) :: WindowTree.rect() | nil
  def tree_rect(%__MODULE__{file_tree: %{tree: nil}}), do: nil

  def tree_rect(%__MODULE__{viewport: vp, file_tree: %{tree: %FileTree{width: tw}}}) do
    {0, 0, tw, vp.rows - 1}
  end

  # ── Cross-cutting window + buffer helpers ─────────────────────────────────

  @doc """
  Syncs the active window's buffer reference with `state.buffers.active`.

  Call this after any operation that changes `state.buffers.active` to keep the
  window tree consistent. No-op when windows aren't initialized.
  """
  @spec sync_active_window_buffer(t()) :: t()
  def sync_active_window_buffer(%__MODULE__{buffers: %{active: nil}} = state), do: state

  def sync_active_window_buffer(
        %__MODULE__{windows: %{map: windows, active: id} = ws, buffers: buffers} = state
      ) do
    case Map.fetch(windows, id) do
      {:ok, %Window{buffer: existing} = window} when existing != buffers.active ->
        # Buffer changed: invalidate all caches. The new buffer has
        # different content, and cached draws from the old buffer are
        # completely wrong. Also reset tracking fields so
        # detect_invalidation forces a full redraw on the next frame.
        window = %{Window.invalidate(window) | buffer: buffers.active}

        %{state | windows: %{ws | map: Map.put(windows, id, window)}}

      _ ->
        state
    end
  end

  @doc """
  Adds a new buffer and makes it the active buffer for the current window.

  Also creates a file tab for the buffer in the tab bar. The current tab
  is snapshotted before switching so its context is preserved.
  """
  @spec add_buffer(t(), pid()) :: t()
  def add_buffer(%__MODULE__{buffers: bs, tab_bar: %TabBar{} = tb} = state, pid) do
    label = buffer_label(pid)

    Log.debug(:editor, fn ->
      "[tab] add_buffer label=#{label} from_tab=#{tb.active_id} agentic=#{state.agentic.active}"
    end)

    # Snapshot the current tab before we modify anything.
    current_ctx =
      snapshot_tab_context(state)
      |> Map.put(:mode, :normal)
      |> Map.put(:mode_state, Minga.Mode.initial_state())

    tb = TabBar.update_context(tb, tb.active_id, current_ctx)

    # Add the buffer to the pool (Buffers.add auto-activates it)
    state = %{state | buffers: Buffers.add(bs, pid)}

    # Create a file tab (TabBar.add auto-activates it)
    {tb, new_tab} = TabBar.add(tb, :file, label)

    # If leaving agentic view, reset to file-tab defaults.
    state =
      if state.agentic.active do
        %{state | agentic: %ViewState{}, keymap_scope: :editor}
      else
        state
      end

    # Snapshot the new tab's context with the correct active buffer.
    state = %{state | tab_bar: tb} |> sync_active_window_buffer()

    new_ctx =
      snapshot_tab_context(state)
      |> Map.put(:mode, :normal)
      |> Map.put(:mode_state, Minga.Mode.initial_state())

    tb = TabBar.update_context(state.tab_bar, new_tab.id, new_ctx)

    Log.debug(:editor, fn ->
      "[tab] add_buffer complete: tab=#{new_tab.id} agentic=#{state.agentic.active} scope=#{state.keymap_scope}"
    end)

    %{state | tab_bar: tb}
  end

  def add_buffer(%__MODULE__{buffers: bs} = state, pid) do
    %{state | buffers: Buffers.add(bs, pid)}
    |> sync_active_window_buffer()
  end

  @doc """
  Switches to the buffer at `idx`, making it active for the current window.

  Centralizes `Buffers.switch_to` + window sync so callers don't need to
  remember to call `sync_active_window_buffer/1`.
  """
  @spec switch_buffer(t(), non_neg_integer()) :: t()
  def switch_buffer(%__MODULE__{buffers: bs} = state, idx) do
    %{state | buffers: Buffers.switch_to(bs, idx)}
    |> sync_active_window_buffer()
  end

  @doc """
  Snapshots the active buffer's cursor into the active window struct.

  Call this before rendering split views so inactive windows have a fresh
  cursor position for the active window when it becomes inactive later.
  """
  @spec sync_active_window_cursor(t()) :: t()
  def sync_active_window_cursor(%__MODULE__{buffers: %{active: nil}} = state), do: state

  def sync_active_window_cursor(
        %__MODULE__{windows: %{map: windows, active: id} = ws, buffers: %{active: buf}} = state
      ) do
    case Map.fetch(windows, id) do
      {:ok, window} ->
        cursor = BufferServer.cursor(buf)
        %{state | windows: %{ws | map: Map.put(windows, id, %{window | cursor: cursor})}}

      :error ->
        state
    end
  end

  @doc """
  Switches focus to the given window, saving the current cursor to the
  outgoing window and restoring the target window's stored cursor.

  No-op if `target_id` is already the active window or windows aren't set up.
  """
  @spec focus_window(t(), Window.id()) :: t()
  def focus_window(%__MODULE__{windows: %{active: active}} = state, target_id)
      when target_id == active,
      do: state

  def focus_window(%__MODULE__{buffers: %{active: nil}} = state, _target_id), do: state

  def focus_window(
        %__MODULE__{windows: %{map: windows, active: old_id} = ws, buffers: buffers} = state,
        target_id
      ) do
    case {Map.fetch(windows, old_id), Map.fetch(windows, target_id)} do
      {{:ok, old_win}, {:ok, target_win}} ->
        # Save current cursor to outgoing window
        current_cursor = BufferServer.cursor(buffers.active)
        windows = Map.put(windows, old_id, %{old_win | cursor: current_cursor})

        # Restore target window's cursor into its buffer
        BufferServer.move_to(target_win.buffer, target_win.cursor)

        %{
          state
          | windows: %{ws | map: windows, active: target_id},
            buffers: %{buffers | active: target_win.buffer}
        }

      _ ->
        state
    end
  end

  @spec buffer_label(pid()) :: String.t()
  defp buffer_label(pid) when is_pid(pid) do
    if Process.alive?(pid), do: live_buffer_label(pid), else: "[dead]"
  end

  defp buffer_label(_), do: "[unknown]"

  @spec live_buffer_label(pid()) :: String.t()
  defp live_buffer_label(pid) do
    case BufferServer.buffer_name(pid) do
      nil -> BufferServer.file_path(pid) |> path_or_scratch()
      name -> name
    end
  end

  @spec path_or_scratch(String.t() | nil) :: String.t()
  defp path_or_scratch(nil), do: "[scratch]"
  defp path_or_scratch(path), do: Path.basename(path)

  # ── Tab bar helpers ───────────────────────────────────────────────────────

  @doc """
  Captures the current per-tab fields into a context map.

  The returned map is stored in the outgoing tab so it can be restored
  when the user switches back.
  """
  @spec snapshot_tab_context(t()) :: Tab.context()
  def snapshot_tab_context(%__MODULE__{} = state) do
    %{
      windows: state.windows,
      file_tree: state.file_tree,
      mode: state.mode,
      mode_state: state.mode_state,
      keymap_scope: state.keymap_scope,
      active_buffer: state.buffers.active,
      active_buffer_index: state.buffers.active_index,
      agent: state.agent,
      agentic: state.agentic
    }
  end

  @doc """
  Writes a tab context back into the live editor state.

  Fields not present in the context map are left unchanged (safe for
  partial contexts from older tab snapshots).
  """
  @spec restore_tab_context(t(), Tab.context()) :: t()
  def restore_tab_context(%__MODULE__{} = state, context) when is_map(context) do
    # Empty context means a brand-new tab. Build file-tab defaults from
    # the live state so we get a proper window tree, viewport-sized window,
    # and clean editor scope.
    context =
      if map_size(context) == 0 do
        build_file_tab_defaults(state)
      else
        context
      end

    state
    |> maybe_restore(:windows, context)
    |> maybe_restore(:file_tree, context)
    |> maybe_restore(:mode, context)
    |> maybe_restore(:mode_state, context)
    |> maybe_restore(:keymap_scope, context)
    |> maybe_restore(:agent, context)
    |> maybe_restore(:agentic, context)
    |> restore_active_buffer(context)
  end

  # Builds a complete file-tab context from the live state. This is the
  # single source of truth for "what does a fresh file tab look like?"
  # Uses the active buffer and viewport dimensions to create a proper
  # window tree so splits, scrolling, and cursor positioning all work.
  @spec build_file_tab_defaults(t()) :: Tab.context()
  defp build_file_tab_defaults(state) do
    win_id = state.windows.next_id
    rows = state.viewport.rows
    cols = state.viewport.cols
    buf = state.buffers.active

    windows =
      if buf && Process.alive?(buf) do
        window = Window.new(win_id, buf, max(rows, 1), max(cols, 1))

        %Windows{
          tree: WindowTree.new(win_id),
          map: %{win_id => window},
          active: win_id,
          next_id: win_id + 1
        }
      else
        %Windows{}
      end

    %{
      windows: windows,
      mode: :normal,
      mode_state: Minga.Mode.initial_state(),
      keymap_scope: :editor,
      agentic: %ViewState{},
      active_buffer: buf,
      active_buffer_index: state.buffers.active_index
    }
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
      "[tab] switch_tab restored: agentic=#{state.agentic.active} scope=#{state.keymap_scope} buf=#{inspect(state.buffers.active)}"
    end)
  end

  @spec maybe_restore(t(), atom(), Tab.context()) :: t()
  defp maybe_restore(state, key, context) do
    case Map.fetch(context, key) do
      {:ok, value} -> Map.put(state, key, value)
      :error -> state
    end
  end

  @spec restore_active_buffer(t(), Tab.context()) :: t()
  defp restore_active_buffer(state, context) do
    case Map.fetch(context, :active_buffer) do
      {:ok, buf_pid} ->
        idx = Map.get(context, :active_buffer_index, state.buffers.active_index)

        %{state | buffers: %{state.buffers | active: buf_pid, active_index: idx}}
        |> sync_active_window_buffer()

      :error ->
        state
    end
  end

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
      context = snapshot_tab_context(state)
      tb = TabBar.update_context(tb, current_id, context)

      # Switch pointer
      tb = TabBar.switch_to(tb, target_id)

      # Restore target tab's context
      %Tab{} = target = TabBar.active(tb)
      state = %{state | tab_bar: tb}

      state = restore_tab_context(state, target.context)

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

  @doc "Finds a file tab whose context has the given buffer pid as active_buffer."
  @spec find_tab_by_buffer(t(), pid()) :: Tab.t() | nil
  def find_tab_by_buffer(%__MODULE__{tab_bar: nil}, _pid), do: nil

  def find_tab_by_buffer(%__MODULE__{tab_bar: tb}, pid) do
    Enum.find(tb.tabs, fn tab ->
      tab.kind == :file and Map.get(tab.context, :active_buffer) == pid
    end)
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

  # ══════════════════════════════════════════════════════════════════════════
  # Per-tab agent event routing
  # ══════════════════════════════════════════════════════════════════════════

  @typedoc """
  Result of resolving which tab an agent event belongs to.

  - `{:active, tab}` — the event targets the currently active tab, so
    the caller should update `state.agent` / `state.agentic` directly.
  - `{:background, tab}` — the event targets a background tab. The caller
    should use `update_background_agent/3` or `update_background_agentic/3`.
  - `:not_found` — no tab owns this session (stale event after tab close).
  """
  @type route_result :: {:active, Tab.t()} | {:background, Tab.t()} | :not_found

  @doc """
  Resolves which tab an agent event belongs to, based on the session pid.

  Checks the active tab's live `state.agent.session` first (fast path),
  then falls back to scanning background tabs via `Tab.session`.
  """
  @spec route_agent_event(t(), pid()) :: route_result()
  def route_agent_event(%__MODULE__{tab_bar: nil}, _session_pid), do: :not_found

  def route_agent_event(%__MODULE__{agent: %{session: sid}, tab_bar: tb}, session_pid)
      when sid == session_pid do
    {:active, TabBar.active(tb)}
  end

  def route_agent_event(%__MODULE__{tab_bar: tb}, session_pid) do
    find_session_in_tabs(tb, session_pid)
  end

  # ── Spinner lifecycle for tab switching ──────────────────────────────────────

  @spec stop_outgoing_spinner(t()) :: t()
  defp stop_outgoing_spinner(%__MODULE__{agent: %AgentState{} = agent} = state) do
    %{state | agent: AgentState.stop_spinner_timer(agent)}
  end

  @spec maybe_restart_incoming_spinner(t()) :: t()
  defp maybe_restart_incoming_spinner(%__MODULE__{agent: %AgentState{} = agent} = state) do
    if AgentState.busy?(agent) and agent.spinner_timer == nil do
      %{state | agent: AgentState.start_spinner_timer(agent)}
    else
      state
    end
  end

  @spec find_session_in_tabs(TabBar.t(), pid()) :: route_result()
  defp find_session_in_tabs(tb, session_pid) do
    case TabBar.find_by_session(tb, session_pid) do
      %Tab{id: id} = tab when id == tb.active_id -> {:active, tab}
      %Tab{} = tab -> {:background, tab}
      nil -> :not_found
    end
  end

  @doc """
  Updates the `agent` field inside a background tab's stored context.

  The function `fun` receives the tab's stored `%AgentState{}` and must
  return a new `%AgentState{}`. Does nothing if the tab has no agent
  context (file tabs, empty context).
  """
  @spec update_background_agent(t(), Tab.id(), (AgentState.t() -> AgentState.t())) :: t()
  def update_background_agent(%__MODULE__{tab_bar: tb} = state, tab_id, fun) do
    case TabBar.get(tb, tab_id) do
      %Tab{context: %{agent: agent}} = _tab when is_struct(agent, AgentState) ->
        new_agent = fun.(agent)
        new_ctx = Map.put(TabBar.get(tb, tab_id).context, :agent, new_agent)
        %{state | tab_bar: TabBar.update_context(tb, tab_id, new_ctx)}

      _ ->
        state
    end
  end

  @doc """
  Updates the `agentic` (ViewState) field inside a background tab's stored context.
  """
  @spec update_background_agentic(t(), Tab.id(), (ViewState.t() -> ViewState.t())) :: t()
  def update_background_agentic(%__MODULE__{tab_bar: tb} = state, tab_id, fun) do
    case TabBar.get(tb, tab_id) do
      %Tab{context: %{agentic: agentic}} = _tab when is_struct(agentic, ViewState) ->
        new_agentic = fun.(agentic)
        new_ctx = Map.put(TabBar.get(tb, tab_id).context, :agentic, new_agentic)
        %{state | tab_bar: TabBar.update_context(tb, tab_id, new_ctx)}

      _ ->
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
end
