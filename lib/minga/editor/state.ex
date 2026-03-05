defmodule Minga.Editor.State do
  @moduledoc """
  Internal state for the Editor GenServer.

  Holds references to the buffer list, port manager, viewport, modal FSM
  state, which-key popup state, and the yank register.

  ## Composed sub-structs

  Related fields are grouped into internal sub-structs to keep the top-level
  struct manageable:

  * `Minga.Editor.State.Buffers`   — buffer list, active buffer, special buffers
  * `Minga.Editor.State.Picker`    — picker instance, source, restore index
  * `Minga.Editor.State.WhichKey`  — which-key popup node, timer, visibility
  * `Minga.Editor.State.Search`    — last search pattern/direction, project results
  * `Minga.Editor.State.Registers` — named registers and active register selection
  * `Minga.Editor.State.Windows`    — window tree, window map, active/next id
  * `Minga.Editor.State.Highlighting` — current highlight, version counter, per-buffer cache
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Completion
  alias Minga.Editor.ChangeRecorder
  alias Minga.Editor.CompletionTrigger
  alias Minga.Editor.DocumentSync
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Highlighting
  alias Minga.Editor.State.Mouse
  alias Minga.Editor.State.Picker
  alias Minga.Editor.State.Registers
  alias Minga.Editor.State.Search
  alias Minga.Editor.State.WhichKey
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.WindowTree
  alias Minga.FileTree
  alias Minga.Mode
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
            autopair_enabled: true,
            theme: Minga.Theme.get!(:doom_one),
            line_numbers: :hybrid,
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
            file_tree: nil,
            file_tree_focused: false

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
          autopair_enabled: boolean(),
          theme: Theme.t(),
          line_numbers: line_number_style(),
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
          file_tree: FileTree.t() | nil,
          file_tree_focused: boolean()
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

  # ── Other accessors ───────────────────────────────────────────────────────

  @doc """
  Returns the screen rect for layout computation, excluding the global
  minibuffer row and reserving space for the file tree panel when open.
  """
  @spec screen_rect(t()) :: WindowTree.rect()
  def screen_rect(%__MODULE__{viewport: vp, file_tree: nil}) do
    {0, 0, vp.cols, vp.rows - 1}
  end

  def screen_rect(%__MODULE__{viewport: vp, file_tree: %FileTree{width: tw}}) do
    # Tree occupies columns 0..tw-1, separator at column tw,
    # editor content starts at column tw+1.
    editor_col = tw + 1
    editor_width = max(vp.cols - editor_col, 1)
    {0, editor_col, editor_width, vp.rows - 1}
  end

  @doc "Returns the screen rect for the file tree panel, or nil if closed."
  @spec tree_rect(t()) :: WindowTree.rect() | nil
  def tree_rect(%__MODULE__{file_tree: nil}), do: nil

  def tree_rect(%__MODULE__{viewport: vp, file_tree: %FileTree{width: tw}}) do
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
        %{state | windows: %{ws | map: Map.put(windows, id, %{window | buffer: buffers.active})}}

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
end
