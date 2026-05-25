defmodule MingaEditor.Session.State do
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
  alias MingaEditor.FeatureState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Dired, as: DiredState
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.Mouse
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab.Context, as: TabContext
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
          dired: DiredState.t(),
          viewport: Viewport.t(),
          mouse: Mouse.t(),
          highlight: Highlighting.t(),
          lsp_pending: %{reference() => atom() | tuple()},
          injection_ranges: %{pid() => [Minga.Language.Highlight.InjectionRange.t()]},
          search: Search.t(),
          editing: VimState.t(),
          feature_state: FeatureState.t(),
          document_highlights: [document_highlight()] | nil,
          agent_ui: UIState.t()
        }

  @enforce_keys [:viewport]
  defstruct keymap_scope: :editor,
            buffers: %Buffers{},
            windows: %Windows{},
            dired: %DiredState{},
            viewport: nil,
            mouse: %Mouse{},
            highlight: %Highlighting{},
            lsp_pending: %{},
            injection_ranges: %{},
            search: %Search{},
            editing: VimState.new(),
            feature_state: FeatureState.new(),
            document_highlights: nil,
            agent_ui: UIState.new()

  @doc "Returns the list of field names (for snapshot/restore compatibility)."
  @spec field_names() :: [TabContext.field_name()]
  def field_names, do: TabContext.field_names()

  @doc """
  Converts a workspace into a typed tab context suitable for storing on a `MingaEditor.State.Tab` and later restoring via `restore_tab_context/2`.

  The single chokepoint for snapshots. Delegates to `TabContext.from_workspace/1` which constructs the context struct directly from the session struct (no intermediate map). The vim state is normalised so the snapshotted editing state is a valid resting state, not a transient mid-transition pair where `mode_state` belongs to the leaving mode (see `VimState.normalize/1`). Use this everywhere the editor captures `state.workspace` into a tab context.
  """
  @spec to_tab_context(t()) :: TabContext.t()
  def to_tab_context(%__MODULE__{} = ws) do
    TabContext.from_workspace(ws)
  end

  @doc "Restores a tab context into a workspace. Empty contexts are ignored by this pure helper; EditorState handles brand-new tab defaults because those need editor dimensions. Dead buffer pids in the restored context are scrubbed to prevent activating a dead process."
  @spec restore_tab_context(t(), TabContext.t() | TabContext.legacy()) :: t()
  def restore_tab_context(%__MODULE__{} = ws, context) when is_map(context) do
    ws =
      context
      |> TabContext.to_workspace_map()
      |> Enum.reduce(ws, fn {field, value}, acc -> Map.put(acc, field, value) end)

    update_in(ws.buffers, &Buffers.scrub_dead_active/1)
  end

  # ── Pure workspace operations ─────────────────────────────────────────────
  #
  # These are pure functions (no side effects) on SessionState. The
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

  @doc "Updates every window that shows the given buffer via a mapper function."
  @spec update_windows_for_buffer(t(), pid(), (Window.t() -> Window.t())) :: t()
  def update_windows_for_buffer(%__MODULE__{windows: ws} = wspace, buffer, fun)
      when is_pid(buffer) and is_function(fun, 1) do
    %{wspace | windows: Windows.update_by_buffer(ws, buffer, fun)}
  end

  @doc """
  Invalidates render caches for all windows.

  Call when the screen layout changes (file tree toggle, agent panel toggle)
  because cached draws contain baked-in absolute coordinates that become
  wrong when column offsets shift.
  """
  @spec invalidate_all_windows(t()) :: t()
  def invalidate_all_windows(%__MODULE__{windows: ws} = wspace) do
    windows =
      Enum.reduce(ws.map, ws, fn {id, _window}, acc ->
        Windows.update(acc, id, &Window.invalidate/1)
      end)

    %{wspace | windows: windows}
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

  def sync_active_window_buffer(%__MODULE__{windows: ws, buffers: buffers} = wspace) do
    id = ws.active

    case Windows.fetch(ws, id) do
      {:ok, %Window{buffer: existing, content: {:buffer, _}}} when existing != buffers.active ->
        windows =
          Windows.update(ws, id, fn window ->
            %{
              window
              | buffer: buffers.active,
                content: Content.buffer(buffers.active)
            }
            |> Window.set_document_symbols([])
            |> Window.invalidate()
          end)

        %{wspace | windows: windows}

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

  @file_tree_source {:extension, :minga_file_tree}
  @file_tree_feature :file_tree
  @empty_file_tree %{
    tree: nil,
    buffer: nil,
    project_root: nil,
    original_root: nil,
    focused: false
  }

  @doc "Returns opaque FileTree UI state from source-owned feature state."
  @spec file_tree_state(t()) :: map()
  def file_tree_state(%__MODULE__{} = wspace) do
    case get_feature_state(wspace, @file_tree_source, @file_tree_feature) do
      value when is_map(value) -> value
      _missing -> @empty_file_tree
    end
  end

  @doc "Replaces the FileTree feature-owned UI state."
  @spec set_file_tree(t(), map()) :: t()
  def set_file_tree(%__MODULE__{} = wspace, file_tree) when is_map(file_tree) do
    put_feature_state(wspace, @file_tree_source, @file_tree_feature, file_tree)
  end

  @doc "Updates the FileTree feature-owned UI state."
  @spec update_file_tree(t(), (map() -> map())) :: t()
  def update_file_tree(%__MODULE__{} = wspace, fun) when is_function(fun, 1) do
    set_file_tree(wspace, fun.(file_tree_state(wspace)))
  end

  @doc "Drops FileTree feature-owned UI state."
  @spec drop_file_tree(t()) :: t()
  def drop_file_tree(%__MODULE__{} = wspace) do
    drop_feature_state(wspace, @file_tree_source, @file_tree_feature)
  end

  @doc "Replaces the dired sub-struct."
  @spec set_dired(t(), DiredState.t()) :: t()
  def set_dired(%__MODULE__{} = wspace, %DiredState{} = dired) do
    %{wspace | dired: dired}
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

  @doc "Returns source-owned feature state, or nil when inactive."
  @spec get_feature_state(t(), FeatureState.source(), FeatureState.feature_id()) :: term() | nil
  def get_feature_state(%__MODULE__{feature_state: feature_state}, source, feature_id) do
    FeatureState.get(feature_state, source, feature_id)
  end

  @doc "Returns source-owned feature state, or a caller-provided default when inactive."
  @spec get_feature_state(t(), FeatureState.source(), FeatureState.feature_id(), default) ::
          term() | default
        when default: var
  def get_feature_state(%__MODULE__{feature_state: feature_state}, source, feature_id, default) do
    FeatureState.get(feature_state, source, feature_id, default)
  end

  @doc "Stores source-owned feature state."
  @spec put_feature_state(t(), FeatureState.source(), FeatureState.feature_id(), term()) :: t()
  def put_feature_state(
        %__MODULE__{feature_state: feature_state} = wspace,
        source,
        feature_id,
        value
      ) do
    %{wspace | feature_state: FeatureState.put(feature_state, source, feature_id, value)}
  end

  @doc "Updates source-owned feature state. Missing values are initialized with `default`."
  @spec update_feature_state(
          t(),
          FeatureState.source(),
          FeatureState.feature_id(),
          term(),
          (term() -> term())
        ) :: t()
  def update_feature_state(
        %__MODULE__{feature_state: feature_state} = wspace,
        source,
        feature_id,
        default,
        fun
      )
      when is_function(fun, 1) do
    %{
      wspace
      | feature_state: FeatureState.update(feature_state, source, feature_id, default, fun)
    }
  end

  @doc "Drops one source-owned feature state entry. Missing state is treated as inactive."
  @spec drop_feature_state(t(), FeatureState.source(), FeatureState.feature_id()) :: t()
  def drop_feature_state(%__MODULE__{feature_state: feature_state} = wspace, source, feature_id) do
    %{wspace | feature_state: FeatureState.drop(feature_state, source, feature_id)}
  end

  @doc "Drops all feature state owned by a source."
  @spec drop_feature_state_source(t(), FeatureState.source()) :: t()
  def drop_feature_state_source(%__MODULE__{feature_state: feature_state} = wspace, source) do
    %{wspace | feature_state: FeatureState.drop_source(feature_state, source)}
  end

  @doc "Drops every extension-owned feature state entry."
  @spec drop_extension_feature_state_sources(t()) :: t()
  def drop_extension_feature_state_sources(%__MODULE__{feature_state: feature_state} = wspace) do
    %{wspace | feature_state: FeatureState.drop_extension_sources(feature_state)}
  end

  @doc "Replaces the feature-state registry."
  @spec set_feature_state(t(), FeatureState.t()) :: t()
  def set_feature_state(%__MODULE__{} = wspace, %FeatureState{} = feature_state) do
    %{wspace | feature_state: feature_state}
  end

  @doc "Updates the agent UI state."
  @spec set_agent_ui(t(), UIState.t()) :: t()
  def set_agent_ui(%__MODULE__{} = wspace, agent_ui) do
    %{wspace | agent_ui: agent_ui}
  end

  @doc "Updates the injection ranges map."
  @spec set_injection_ranges(t(), %{pid() => [Minga.Language.Highlight.InjectionRange.t()]}) ::
          t()
  def set_injection_ranges(%__MODULE__{} = wspace, ranges) do
    %{wspace | injection_ranges: ranges}
  end
end
