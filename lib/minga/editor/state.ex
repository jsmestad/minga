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
            modeline_click_regions: []

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
          modeline_click_regions: [Minga.Editor.Modeline.click_region()]
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

  Centralizes `Buffers.add` + window sync so callers don't need to remember
  to call `sync_active_window_buffer/1`.
  """
  @spec add_buffer(t(), pid()) :: t()
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
      # Snapshot current tab
      context = snapshot_tab_context(state)
      tb = TabBar.update_context(tb, current_id, context)

      # Switch pointer
      tb = TabBar.switch_to(tb, target_id)

      # Restore target tab's context
      target = TabBar.active(tb)
      state = %{state | tab_bar: tb}

      if target do
        state
        |> restore_tab_context(target.context)
        |> invalidate_all_windows()
        |> Map.put(:layout, nil)
      else
        state
      end
    end
  end

  @doc """
  Returns the active tab, or nil if the tab bar isn't initialized.
  """
  @spec active_tab(t()) :: Tab.t() | nil
  def active_tab(%__MODULE__{tab_bar: nil}), do: nil
  def active_tab(%__MODULE__{tab_bar: tb}), do: TabBar.active(tb)

  @doc """
  Returns the kind of the active tab, or `:file` as default.
  """
  @spec active_tab_kind(t()) :: Tab.kind()
  def active_tab_kind(%__MODULE__{tab_bar: nil}), do: :file

  def active_tab_kind(%__MODULE__{tab_bar: tb}) do
    case TabBar.active(tb) do
      %Tab{kind: kind} -> kind
      nil -> :file
    end
  end
end
