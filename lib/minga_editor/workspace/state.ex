defmodule MingaEditor.Workspace.State do
  @moduledoc """
  Core editing context that exists regardless of presentation.

  A workspace is the editing state that gets saved/restored when
  switching tabs. It works identically whether rendered as a tab in
  the traditional editor, a card on The Board, or running headless
  without any UI.

  This struct formalizes the `@per_tab_fields` boundary from
  `MingaEditor.State`: every field here is snapshotted per tab and
  restored on tab switch.
  """

  alias MingaEditor.Agent.UIState
  alias Minga.Editing.Completion
  alias MingaEditor.CompletionTrigger
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.Mouse
  alias MingaEditor.State.Search
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias Minga.Keymap.Scope

  @typedoc "A document highlight range from the LSP server."
  @type document_highlight :: Minga.LSP.DocumentHighlight.t()

  @type t :: %__MODULE__{
          keymap_scope: Scope.scope_name(),
          buffers: Buffers.t(),
          windows: Windows.t(),
          file_tree: FileTreeState.t(),
          viewport: Viewport.t(),
          mouse: Mouse.t(),
          highlight: Highlighting.t(),
          lsp_pending: %{reference() => atom() | tuple()},
          completion: Completion.t() | nil,
          completion_trigger: CompletionTrigger.t(),
          injection_ranges: %{pid() => [MingaEditor.UI.Highlight.InjectionRange.t()]},
          search: Search.t(),
          pending_conflict: {pid(), String.t()} | nil,
          editing: VimState.t(),
          document_highlights: [document_highlight()] | nil,
          agent_ui: UIState.t()
        }

  @enforce_keys [:viewport]
  defstruct keymap_scope: :editor,
            buffers: %Buffers{},
            windows: %Windows{},
            file_tree: %FileTreeState{},
            viewport: nil,
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

  @doc "Returns the list of field names (for snapshot/restore compatibility)."
  @spec field_names() :: [atom()]
  def field_names do
    %__MODULE__{viewport: %Viewport{top: 0, left: 0, rows: 1, cols: 1}}
    |> Map.keys()
    |> Enum.reject(&(&1 == :__struct__))
  end

  # ── Pure workspace operations ─────────────────────────────────────────────
  #
  # These are pure functions (no side effects) on WorkspaceState. The
  # Editor GenServer calls these through EditorState wrappers that handle
  # cross-cutting concerns (tab bar sync, process monitoring, etc.).

  alias MingaEditor.Window
  alias MingaEditor.Window.Content

  @doc "Returns the active window struct, or nil."
  @spec active_window_struct(t()) :: Window.t() | nil
  def active_window_struct(%__MODULE__{windows: ws}), do: Windows.active_struct(ws)

  @doc "Returns true if the workspace has more than one window."
  @spec split?(t()) :: boolean()
  def split?(%__MODULE__{windows: ws}), do: Windows.split?(ws)

  @doc "Updates the window struct for the given window id via a mapper function."
  @spec update_window(t(), Window.id(), (Window.t() -> Window.t())) :: t()
  def update_window(%__MODULE__{windows: ws} = wspace, id, fun) do
    %{wspace | windows: Windows.update(ws, id, fun)}
  end

  @doc """
  Invalidates render caches for all windows.

  Call when the screen layout changes (file tree toggle, agent panel toggle)
  because cached draws contain baked-in absolute coordinates that become
  wrong when column offsets shift.
  """
  @spec invalidate_all_windows(t()) :: t()
  def invalidate_all_windows(%__MODULE__{windows: ws} = wspace) do
    new_map =
      Map.new(ws.map, fn {id, window} -> {id, Window.invalidate(window)} end)

    %{wspace | windows: %{ws | map: new_map}}
  end

  @doc """
  Switches to the buffer at `idx`, making it active for the current window.

  Pure workspace operation: updates Buffers and syncs the active window.
  """
  @spec switch_buffer(t(), non_neg_integer()) :: t()
  def switch_buffer(%__MODULE__{buffers: bs} = wspace, idx) do
    %{wspace | buffers: Buffers.switch_to(bs, idx)}
    |> sync_active_window_buffer()
  end

  @doc """
  Syncs the active window's buffer reference with `buffers.active`.

  Call after any operation that changes `buffers.active` to keep the
  window tree consistent. No-op when windows aren't initialized.
  """
  @spec sync_active_window_buffer(t()) :: t()
  def sync_active_window_buffer(%__MODULE__{buffers: %{active: nil}} = wspace), do: wspace

  def sync_active_window_buffer(
        %__MODULE__{windows: %{map: windows, active: id} = ws, buffers: buffers} = wspace
      ) do
    case Map.fetch(windows, id) do
      {:ok, %Window{buffer: existing, content: {:buffer, _}} = window}
      when existing != buffers.active ->
        window = %{
          Window.invalidate(window)
          | buffer: buffers.active,
            content: Content.buffer(buffers.active)
        }

        %{wspace | windows: %{ws | map: Map.put(windows, id, window)}}

      _ ->
        wspace
    end
  end

  @doc "Transitions the editing model to a new mode."
  @spec transition_mode(t(), atom(), term()) :: t()
  def transition_mode(%__MODULE__{editing: vim} = wspace, mode, mode_state \\ nil) do
    %{wspace | editing: VimState.transition(vim, mode, mode_state)}
  end

  @doc """
  Derives the keymap scope from a window's content type.

  Agent chat windows always use `:agent` scope. Buffer windows use
  `:editor` when coming from `:agent` scope, and preserve the current
  scope otherwise.
  """
  @spec scope_for_content(Content.t(), Scope.scope_name()) :: Scope.scope_name()
  def scope_for_content({:agent_chat, _pid}, _current_scope), do: :agent
  def scope_for_content({:buffer, _pid}, :agent), do: :editor
  def scope_for_content({:buffer, _pid}, current_scope), do: current_scope

  @doc """
  Returns the appropriate keymap scope for the active window's content type.
  """
  @spec scope_for_active_window(t()) :: atom()
  def scope_for_active_window(%__MODULE__{windows: %{map: map, active: active_id}}) do
    case Map.get(map, active_id) do
      %{content: content} -> scope_for_content(content, :editor)
      nil -> :editor
    end
  end

  # ── Field mutation functions (Rule 2 enforcement) ──────────────────────

  @doc "Updates the editing (VimState) sub-struct."
  @spec update_editing(t(), (VimState.t() -> VimState.t())) :: t()
  def update_editing(%__MODULE__{editing: vim} = wspace, fun) when is_function(fun, 1) do
    %{wspace | editing: fun.(vim)}
  end

  @doc "Replaces the editing (VimState) sub-struct."
  @spec set_editing(t(), VimState.t()) :: t()
  def set_editing(%__MODULE__{} = wspace, vim) do
    %{wspace | editing: vim}
  end

  @doc "Sets the keymap scope."
  @spec set_keymap_scope(t(), Scope.scope_name()) :: t()
  def set_keymap_scope(%__MODULE__{} = wspace, scope) do
    %{wspace | keymap_scope: scope}
  end

  @doc "Updates the completion state."
  @spec set_completion(t(), Completion.t() | nil) :: t()
  def set_completion(%__MODULE__{} = wspace, completion) do
    %{wspace | completion: completion}
  end

  @doc "Updates the completion trigger bridge."
  @spec set_completion_trigger(t(), CompletionTrigger.t()) :: t()
  def set_completion_trigger(%__MODULE__{} = wspace, trigger) do
    %{wspace | completion_trigger: trigger}
  end

  @doc "Clears completion and resets the trigger bridge."
  @spec clear_completion(t(), CompletionTrigger.t()) :: t()
  def clear_completion(%__MODULE__{} = wspace, new_bridge) do
    %{wspace | completion: nil, completion_trigger: new_bridge}
  end

  @doc "Updates the highlighting sub-struct."
  @spec set_highlight(t(), Highlighting.t()) :: t()
  def set_highlight(%__MODULE__{} = wspace, highlight) do
    %{wspace | highlight: highlight}
  end

  @doc "Updates the highlighting sub-struct via a mapper function."
  @spec update_highlight(t(), (Highlighting.t() -> Highlighting.t())) :: t()
  def update_highlight(%__MODULE__{highlight: hl} = wspace, fun) when is_function(fun, 1) do
    %{wspace | highlight: fun.(hl)}
  end

  @doc "Updates the mouse sub-struct."
  @spec set_mouse(t(), Mouse.t()) :: t()
  def set_mouse(%__MODULE__{} = wspace, mouse) do
    %{wspace | mouse: mouse}
  end

  @doc "Updates the document highlights from LSP."
  @spec set_document_highlights(t(), [document_highlight()] | nil) :: t()
  def set_document_highlights(%__MODULE__{} = wspace, highlights) do
    %{wspace | document_highlights: highlights}
  end

  @doc "Updates the search sub-struct."
  @spec set_search(t(), Search.t()) :: t()
  def set_search(%__MODULE__{} = wspace, search) do
    %{wspace | search: search}
  end

  @doc "Updates the search sub-struct via a mapper function."
  @spec update_search(t(), (Search.t() -> Search.t())) :: t()
  def update_search(%__MODULE__{search: s} = wspace, fun) when is_function(fun, 1) do
    %{wspace | search: fun.(s)}
  end

  @doc "Sets the pending conflict state."
  @spec set_pending_conflict(t(), {pid(), String.t()} | nil) :: t()
  def set_pending_conflict(%__MODULE__{} = wspace, conflict) do
    %{wspace | pending_conflict: conflict}
  end

  @doc "Updates the LSP pending requests map."
  @spec set_lsp_pending(t(), %{reference() => atom() | tuple()}) :: t()
  def set_lsp_pending(%__MODULE__{} = wspace, pending) do
    %{wspace | lsp_pending: pending}
  end

  @doc "Sets the viewport dimensions."
  @spec set_viewport(t(), Viewport.t()) :: t()
  def set_viewport(%__MODULE__{} = wspace, viewport) do
    %{wspace | viewport: viewport}
  end

  @doc "Replaces the windows sub-struct."
  @spec set_windows(t(), Windows.t()) :: t()
  def set_windows(%__MODULE__{} = wspace, windows) do
    %{wspace | windows: windows}
  end

  @doc "Replaces the buffers sub-struct."
  @spec set_buffers(t(), Buffers.t()) :: t()
  def set_buffers(%__MODULE__{} = wspace, buffers) do
    %{wspace | buffers: buffers}
  end

  @doc "Updates the agent UI state."
  @spec set_agent_ui(t(), UIState.t()) :: t()
  def set_agent_ui(%__MODULE__{} = wspace, agent_ui) do
    %{wspace | agent_ui: agent_ui}
  end

  @doc "Updates the injection ranges map."
  @spec set_injection_ranges(t(), %{pid() => [MingaEditor.UI.Highlight.InjectionRange.t()]}) ::
          t()
  def set_injection_ranges(%__MODULE__{} = wspace, ranges) do
    %{wspace | injection_ranges: ranges}
  end
end
