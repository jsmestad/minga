defmodule Minga.Workspace do
  @moduledoc """
  Pure calculation functions on `Workspace.State`.

  Every function in this module is a calculation: it takes a
  `WorkspaceState.t()` (and possibly extra arguments), returns an
  updated `WorkspaceState.t()` (or a derived value), and never calls
  a GenServer, monitors a process, or produces side effects.

  The `Minga.Editor.State` module is the action layer that fetches
  external data (e.g., `BufferServer.cursor/1`), calls these
  calculations, and then executes side effects (e.g.,
  `BufferServer.move_to/2`, `Process.monitor/1`).

  ## Moved from EditorState

  These functions previously lived in `Minga.Editor.State` and
  operated on the full `EditorState.t()`. They now operate on
  `WorkspaceState.t()` only. EditorState retains thin delegates
  that unwrap/rewrap the workspace.
  """

  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Windows
  alias Minga.Editor.VimState
  alias Minga.Editor.Viewport
  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content
  alias Minga.Mode
  alias Minga.Workspace.State, as: WorkspaceState

  # ── Window operations (pure) ─────────────────────────────────────────────

  @doc "Returns the active window struct, or nil if windows aren't initialized."
  @spec active_window_struct(WorkspaceState.t()) :: Window.t() | nil
  def active_window_struct(%WorkspaceState{windows: ws}), do: Windows.active_struct(ws)

  @doc "Returns true if the editor has more than one window."
  @spec split?(WorkspaceState.t()) :: boolean()
  def split?(%WorkspaceState{windows: ws}), do: Windows.split?(ws)

  @doc "Updates the window struct for the given window id via a mapper function."
  @spec update_window(WorkspaceState.t(), Window.id(), (Window.t() -> Window.t())) ::
          WorkspaceState.t()
  def update_window(%WorkspaceState{windows: ws} = wks, id, fun) do
    %{wks | windows: Windows.update(ws, id, fun)}
  end

  @doc """
  Invalidates render caches for all windows.

  Call when the screen layout changes (file tree toggle, agent panel toggle)
  because cached draws contain baked-in absolute coordinates that become
  wrong when column offsets shift.
  """
  @spec invalidate_all_windows(WorkspaceState.t()) :: WorkspaceState.t()
  def invalidate_all_windows(%WorkspaceState{windows: ws} = wks) do
    new_map =
      Map.new(ws.map, fn {id, window} -> {id, Window.invalidate(window)} end)

    %{wks | windows: %{ws | map: new_map}}
  end

  @doc """
  Returns the active window's viewport, falling back to the workspace
  viewport when no window is active.
  """
  @spec active_window_viewport(WorkspaceState.t()) :: Viewport.t()
  def active_window_viewport(%WorkspaceState{} = wks) do
    case active_window_struct(wks) do
      nil -> wks.viewport
      %Window{viewport: vp} -> vp
    end
  end

  @doc """
  Updates the active window's viewport. Falls back to updating
  the workspace viewport when no window is active.
  """
  @spec put_active_window_viewport(WorkspaceState.t(), Viewport.t()) :: WorkspaceState.t()
  def put_active_window_viewport(%WorkspaceState{} = wks, new_vp) do
    case active_window_struct(wks) do
      nil ->
        %{wks | viewport: new_vp}

      %Window{id: win_id} ->
        update_window(wks, win_id, fn w -> %{w | viewport: new_vp} end)
    end
  end

  @doc """
  Finds the agent chat window in the windows map.

  Returns `{win_id, window}` or `nil` if no agent chat window exists.
  """
  @spec find_agent_chat_window(WorkspaceState.t()) :: {Window.id(), Window.t()} | nil
  def find_agent_chat_window(%WorkspaceState{windows: ws}) do
    Enum.find_value(ws.map, fn
      {win_id, %Window{content: {:agent_chat, _}} = window} -> {win_id, window}
      _ -> nil
    end)
  end

  @doc """
  Scrolls the agent chat window's viewport by `delta` lines and updates
  pinned state. Delegates to `Window.scroll_viewport/3`.

  Note: Requires `total_lines` as an argument to stay pure. The caller
  must fetch the line count from `BufferServer.line_count/1`.

  Returns the workspace unchanged if no agent chat window exists.
  """
  @spec scroll_agent_chat_window(WorkspaceState.t(), integer(), non_neg_integer()) ::
          WorkspaceState.t()
  def scroll_agent_chat_window(%WorkspaceState{} = wks, delta, total_lines) do
    case find_agent_chat_window(wks) do
      nil ->
        wks

      {win_id, window} ->
        updated = Window.scroll_viewport(window, delta, total_lines)
        update_window(wks, win_id, fn _ -> updated end)
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
  def scope_for_content({:agent_chat, _pid}, _current_scope), do: :agent
  def scope_for_content({:buffer, _pid}, current_scope) when current_scope == :agent, do: :editor
  def scope_for_content({:buffer, _pid}, current_scope), do: current_scope

  @doc """
  Returns the appropriate keymap scope for the active window's content type.

  Used when leaving the file tree (toggle, close, navigate right) to restore
  the correct scope. Returns :agent for agent chat windows, :editor otherwise.
  """
  @spec scope_for_active_window(WorkspaceState.t()) :: atom()
  def scope_for_active_window(%WorkspaceState{windows: %{map: map, active: active_id}}) do
    case Map.get(map, active_id) do
      %{content: content} -> scope_for_content(content, :editor)
      nil -> :editor
    end
  end

  # ── Buffer operations (pure workspace part) ──────────────────────────────

  @doc """
  Switches to the buffer at `idx` and syncs the active window.

  Pure calculation: updates `buffers` via `Buffers.switch_to/2` and
  syncs the window's buffer reference. The EditorState delegate
  handles tab label sync (which needs `tab_bar`).
  """
  @spec switch_buffer(WorkspaceState.t(), non_neg_integer()) :: WorkspaceState.t()
  def switch_buffer(%WorkspaceState{buffers: bs} = wks, idx) do
    %{wks | buffers: Buffers.switch_to(bs, idx)}
    |> sync_active_window_buffer()
  end

  @doc """
  Adds a buffer pid to the workspace and syncs the active window.

  Pure calculation: updates `buffers` via `Buffers.add/2` and syncs
  the window's buffer reference. The EditorState delegate handles
  process monitoring and tab_bar logic.
  """
  @spec add_buffer(WorkspaceState.t(), pid()) :: WorkspaceState.t()
  def add_buffer(%WorkspaceState{buffers: bs} = wks, pid) do
    %{wks | buffers: Buffers.add(bs, pid)}
    |> sync_active_window_buffer()
  end

  @doc """
  Removes a dead buffer from the workspace.

  Pure calculation: removes the pid from the buffer list, clears
  special buffer slots, picks a new active buffer, and syncs the
  window. The EditorState delegate handles `buffer_monitors` cleanup
  and agent buffer ref clearing.
  """
  @spec remove_dead_buffer(WorkspaceState.t(), pid()) :: WorkspaceState.t()
  def remove_dead_buffer(%WorkspaceState{buffers: %Buffers{} = bs} = wks, pid) do
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

    %{wks | buffers: new_bs}
    |> sync_active_window_buffer()
  end

  @doc """
  Syncs the active window's buffer reference with `buffers.active`.

  Call after any operation that changes `buffers.active` to keep the
  window tree consistent. No-op when windows aren't initialized or
  the buffer hasn't changed.
  """
  @spec sync_active_window_buffer(WorkspaceState.t()) :: WorkspaceState.t()
  def sync_active_window_buffer(%WorkspaceState{buffers: %{active: nil}} = wks), do: wks

  def sync_active_window_buffer(
        %WorkspaceState{
          windows: %{map: windows, active: id} = wins,
          buffers: buffers
        } = wks
      ) do
    case Map.fetch(windows, id) do
      {:ok, %Window{buffer: existing} = window} when existing != buffers.active ->
        window = %{
          Window.invalidate(window)
          | buffer: buffers.active,
            content: Content.buffer(buffers.active)
        }

        %{wks | windows: %{wins | map: Map.put(windows, id, window)}}

      _ ->
        wks
    end
  end

  @doc """
  Pure part of focus_window: saves the current cursor to the outgoing
  window, updates the active pointer, switches the active buffer, and
  derives the new keymap scope.

  Returns `{updated_workspace, target_cursor}` where `target_cursor`
  is the cursor position stored in the target window. The caller must
  call `BufferServer.move_to/2` with the target cursor as a side effect.

  Returns `{workspace, nil}` unchanged if the target is already active,
  no buffer is active, or the window ids are invalid.
  """
  @spec focus_window(WorkspaceState.t(), Window.id(), Minga.Buffer.Document.position()) ::
          {WorkspaceState.t(), Minga.Buffer.Document.position() | nil}
  def focus_window(%WorkspaceState{windows: %{active: active}} = wks, target_id, _current_cursor)
      when target_id == active,
      do: {wks, nil}

  def focus_window(%WorkspaceState{buffers: %{active: nil}} = wks, _target_id, _current_cursor),
    do: {wks, nil}

  def focus_window(
        %WorkspaceState{
          windows: %{map: windows, active: old_id} = wins,
          buffers: buffers,
          keymap_scope: current_scope
        } = wks,
        target_id,
        current_cursor
      ) do
    case {Map.fetch(windows, old_id), Map.fetch(windows, target_id)} do
      {{:ok, old_win}, {:ok, target_win}} ->
        # Save current cursor to outgoing window
        windows = Map.put(windows, old_id, %{old_win | cursor: current_cursor})

        # Derive keymap_scope from the target window's content type
        scope = scope_for_content(target_win.content, current_scope)

        updated_wks = %{
          wks
          | windows: %{wins | map: windows, active: target_id},
            buffers: %{buffers | active: target_win.buffer},
            keymap_scope: scope
        }

        {updated_wks, target_win.cursor}

      _ ->
        {wks, nil}
    end
  end

  # ── Mode transitions ────────────────────────────────────────────────────────

  @doc """
  Transitions the workspace to a new vim mode.

  Pure calculation wrapper around `VimState.transition/3`.

  ## Examples

      Workspace.transition_mode(ws, :normal)
      Workspace.transition_mode(ws, :visual, %VisualState{...})
  """
  @spec transition_mode(WorkspaceState.t(), Mode.mode(), Mode.state() | nil) ::
          WorkspaceState.t()
  def transition_mode(%WorkspaceState{vim: vim} = wks, mode, mode_state \\ nil) do
    %{wks | vim: VimState.transition(vim, mode, mode_state)}
  end

  @doc """
  Syncs the active window's cursor from an externally fetched position.

  Pure calculation: stores the cursor in the active window struct.
  The caller must fetch the cursor from `BufferServer.cursor/1`.
  """
  @spec sync_active_window_cursor(WorkspaceState.t(), Minga.Buffer.Document.position()) ::
          WorkspaceState.t()
  def sync_active_window_cursor(%WorkspaceState{buffers: %{active: nil}} = wks, _cursor), do: wks

  def sync_active_window_cursor(
        %WorkspaceState{windows: %{map: windows, active: id} = wins} = wks,
        cursor
      ) do
    case Map.fetch(windows, id) do
      {:ok, window} ->
        %{wks | windows: %{wins | map: Map.put(windows, id, %{window | cursor: cursor})}}

      :error ->
        wks
    end
  end
end
