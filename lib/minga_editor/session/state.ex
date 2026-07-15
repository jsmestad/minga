defmodule MingaEditor.Session.State do
  @moduledoc """
  Core editing context that exists regardless of presentation.

  A workspace is the editing state that gets saved/restored when
  switching tabs. It works identically whether rendered as a tab in
  the traditional editor, an extension shell surface, or running headless
  without any UI.

  This struct formalizes the `@per_tab_fields` boundary from
  `MingaEditor.State`: every field here is snapshotted per tab and
  restored on tab switch.
  """

  alias MingaEditor.Agent.UIState
  alias MingaEditor.FeatureState
  alias MingaEditor.Session.HoverObservation
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Dired, as: DiredState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Mouse
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias Minga.Keymap.Scope

  @typedoc "A document highlight range from the LSP server."
  @type document_highlight :: Minga.LSP.DocumentHighlight.t()

  @typedoc "A buffer position as `{line, byte_col}`."
  @type position :: {non_neg_integer(), non_neg_integer()}

  @typedoc "Transient Cmd/Ctrl-hover go-to-definition link range."
  @type cmd_hover_link :: HoverObservation.link()

  @typedoc "The pointer cell used to deduplicate Cmd/Ctrl-hover resolution."
  @type cmd_hover_cell :: position() | nil

  @type t :: %__MODULE__{
          keymap_scope: Scope.scope_name(),
          buffers: Buffers.t(),
          windows: Windows.t(),
          dired: DiredState.t(),
          file_tree: FileTreeState.t(),
          viewport: Viewport.t(),
          mouse: Mouse.t(),
          lsp_pending: %{reference() => atom() | tuple()},
          search: Search.t(),
          editing: VimState.t(),
          feature_state: FeatureState.t(),
          document_highlights: [document_highlight()] | nil,
          hover_observation: HoverObservation.t(),
          agent_ui: UIState.t(),
          launchpad: MingaEditor.State.Launchpad.t() | nil
        }

  @enforce_keys [:viewport]
  defstruct keymap_scope: :editor,
            buffers: %Buffers{},
            windows: %Windows{},
            dired: %DiredState{},
            file_tree: %FileTreeState{},
            viewport: nil,
            mouse: %Mouse{},
            lsp_pending: %{},
            search: %Search{},
            editing: VimState.new(),
            feature_state: FeatureState.new(),
            document_highlights: nil,
            hover_observation: %HoverObservation{},
            agent_ui: UIState.new(),
            launchpad: nil

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
      # The Cmd/Ctrl-hover link is transient pointer state, not snapshotted per
      # tab. Force it off on every restore so a switch never carries a stale
      # underline (or GUI hand cursor) from the previous tab's buffer (#2630).
      |> clear_cmd_hover_link()

    update_in(ws.buffers, &Buffers.scrub_dead_active/1)
  end

  # ── Pure workspace operations ─────────────────────────────────────────────
  #
  # These are pure functions (no side effects) on SessionState. The
  # Editor workflows compose these values with process and presentation work.

  alias MingaEditor.Window
  alias MingaEditor.Window.Content

  @doc "Returns the active window struct, or nil."
  @spec active_window_struct(t()) :: Window.t() | nil
  def active_window_struct(%__MODULE__{windows: ws}), do: Windows.active_struct(ws)

  @doc "Returns the focused window viewport or the supplied terminal fallback."
  @spec current_viewport(t(), Viewport.t()) :: Viewport.t()
  def current_viewport(%__MODULE__{} = workspace, %Viewport{} = fallback) do
    case active_window_struct(workspace) do
      %Window{viewport: viewport} -> viewport
      nil -> fallback
    end
  end

  @doc "Finds the semantic agent chat window, when one exists."
  @spec find_agent_chat_window(t()) :: {Window.id(), Window.t()} | nil
  def find_agent_chat_window(%__MODULE__{windows: windows}) do
    Enum.find_value(windows.map, fn
      {id, %Window{content: {:agent_chat, _}} = window} -> {id, window}
      _other -> nil
    end)
  end

  @doc "Returns true if the workspace has more than one window."
  @spec split?(t()) :: boolean()
  def split?(%__MODULE__{windows: ws}), do: Windows.split?(ws)

  @doc "Replaces one session-owned window with a concrete value."
  @spec replace_window(t(), Window.id(), Window.t()) :: t()
  def replace_window(%__MODULE__{windows: windows} = workspace, id, %Window{} = window) do
    %{workspace | windows: Windows.replace_window(windows, id, window)}
  end

  @doc "Records a renderer observation for one session-owned window."
  @spec observe_window(t(), Window.id(), pid(), Viewport.t(), non_neg_integer()) :: t()
  def observe_window(
        %__MODULE__{windows: windows} = workspace,
        id,
        buffer,
        %Viewport{} = viewport,
        version
      )
      when is_pid(buffer) and is_integer(version) and version >= 0 do
    case Windows.fetch(windows, id) do
      {:ok,
       %Window{content: {:buffer, ^buffer}, render_cache: %{buffer_version: current}} = window}
      when current <= version ->
        replace_window(workspace, id, Window.observe_render(window, viewport, version))

      _stale_or_missing ->
        workspace
    end
  end

  @doc "Replaces every window showing a buffer with concrete values."
  @spec replace_buffer_windows(t(), pid(), %{Window.id() => Window.t()}) :: t()
  def replace_buffer_windows(%__MODULE__{windows: windows} = workspace, buffer, replacements)
      when is_pid(buffer) and is_map(replacements) do
    %{workspace | windows: Windows.replace_buffer_windows(windows, buffer, replacements)}
  end

  @doc "Updates the active window viewport, when a window is active."
  @spec update_current_viewport(t(), Viewport.t()) :: t()
  def update_current_viewport(%__MODULE__{} = workspace, %Viewport{} = viewport) do
    case active_window_struct(workspace) do
      nil ->
        workspace

      %Window{id: id} = window ->
        replace_window(workspace, id, Window.set_viewport(window, viewport))
    end
  end

  @doc "Marks the active window for authoritative scroll receipt handling."
  @spec mark_authoritative_scroll(t()) :: t()
  def mark_authoritative_scroll(%__MODULE__{} = workspace) do
    case active_window_struct(workspace) do
      nil ->
        workspace

      %Window{id: id} = window ->
        replace_window(workspace, id, Window.mark_authoritative_scroll(window))
    end
  end

  @doc "Scrolls the agent chat window viewport when one exists."
  @spec scroll_agent_chat_window(t(), integer()) :: t()
  def scroll_agent_chat_window(%__MODULE__{} = workspace, delta) do
    case Enum.find_value(workspace.windows.map, fn
           {id, %Window{content: {:agent_chat, _}} = window} -> {id, window}
           _other -> nil
         end) do
      nil ->
        workspace

      {id, window} ->
        total_lines = Enum.count(workspace.agent_ui.panel.cached_line_index)
        updated = Window.scroll_viewport(window, delta, total_lines)
        replace_window(workspace, id, updated)
    end
  end

  @doc """
  Invalidates render caches for all windows.

  Call when the screen layout changes (file tree toggle, agent panel toggle)
  because cached draws contain baked-in absolute coordinates that become
  wrong when column offsets shift.
  """
  @spec invalidate_all_windows(t()) :: t()
  def invalidate_all_windows(%__MODULE__{} = wspace), do: wspace

  @doc "Marks all window retained-GUI render caches reset-pending after frontend state loss."
  @spec mark_frontend_reset_pending(t()) :: t()
  def mark_frontend_reset_pending(%__MODULE__{} = wspace), do: wspace

  @typedoc "A leaf-owned buffer selection to activate in this session."
  @type buffer_activation :: integer() | Buffers.t()

  @doc """
  Activates a buffer selection and synchronizes every session-owned observation.

  Integer selections delegate wrapping and index semantics to `Buffers`. A prepared `Buffers` value supports close, restore, and add workflows that already performed their leaf transition. By default non-buffer surfaces remain visible; `replace_window_content?: true` lets a shell intentionally replace one with the activated buffer.
  """
  @spec activate_buffer(t(), buffer_activation()) :: t()
  @spec activate_buffer(t(), buffer_activation(), keyword()) :: t()
  def activate_buffer(workspace, activation, opts \\ [])

  def activate_buffer(%__MODULE__{buffers: buffers} = workspace, index, opts)
      when is_integer(index) do
    activate_buffer(workspace, Buffers.switch_to(buffers, index), opts)
  end

  def activate_buffer(%__MODULE__{} = workspace, %Buffers{} = buffers, opts) do
    workspace = %{
      workspace
      | buffers: buffers,
        hover_observation: HoverObservation.clear(workspace.hover_observation)
    }

    synchronize_activated_window(
      workspace,
      Keyword.get(opts, :replace_window_content?, false)
    )
  end

  @doc "Commits a pure window-focus transition after its required buffer calls succeed."
  @spec focus_window(t(), Window.id(), position() | nil) :: t()

  def focus_window(%__MODULE__{windows: %{active: active}} = workspace, target_id, _cursor)
      when target_id == active,
      do: workspace

  def focus_window(%__MODULE__{windows: windows} = workspace, target_id, outgoing_cursor) do
    with {:ok, old_window} <- Windows.fetch(windows, windows.active),
         {:ok, target_window} <- Windows.fetch(windows, target_id) do
      windows = remember_outgoing_cursor(windows, old_window, outgoing_cursor)
      commit_focused_window(workspace, windows, target_id, target_window)
    else
      :error -> workspace
    end
  end

  @doc "Commits focus to a surviving window after the active split was removed."
  @spec focus_surviving_window(t(), Windows.t(), Window.id()) :: t()

  def focus_surviving_window(%__MODULE__{} = workspace, %Windows{} = windows, target_id) do
    case Windows.fetch(windows, target_id) do
      {:ok, target_window} ->
        commit_focused_window(workspace, windows, target_id, target_window)

      :error ->
        workspace
    end
  end

  @doc "Stores the active buffer cursor in its matching active window."
  @spec remember_active_window_cursor(t(), position()) :: t()

  def remember_active_window_cursor(
        %__MODULE__{windows: windows, buffers: %{active: buffer}} = workspace,
        cursor
      )
      when is_pid(buffer) do
    case Windows.fetch(windows, windows.active) do
      {:ok, %Window{content: {:buffer, ^buffer}}} ->
        %{
          workspace
          | windows:
              Windows.replace_window(
                windows,
                windows.active,
                Window.remember_cursor(Map.fetch!(windows.map, windows.active), cursor)
              )
        }

      _ ->
        workspace
    end
  end

  def remember_active_window_cursor(%__MODULE__{} = workspace, _cursor), do: workspace

  @spec synchronize_activated_window(t(), boolean()) :: t()
  defp synchronize_activated_window(%__MODULE__{buffers: %{active: nil}} = workspace, _replace?),
    do: workspace

  defp synchronize_activated_window(
         %__MODULE__{windows: windows, buffers: %{active: buffer}} = workspace,
         replace?
       ) do
    case Windows.fetch(windows, windows.active) do
      {:ok, %Window{content: {:buffer, ^buffer}}} ->
        normalize_buffer_surface(workspace, buffer)

      {:ok, %Window{content: {:buffer, _}}} ->
        activate_buffer_surface(workspace, windows, buffer)

      {:ok, %Window{content: {:empty, :semantic}}} ->
        activate_buffer_surface(workspace, windows, buffer)

      {:ok, %Window{}} when replace? ->
        activate_buffer_surface(workspace, windows, buffer)

      _ ->
        workspace
    end
  end

  @spec activate_buffer_surface(t(), Windows.t(), pid()) :: t()
  defp activate_buffer_surface(workspace, windows, buffer) do
    workspace = %{
      workspace
      | windows:
          Windows.replace_window(
            windows,
            windows.active,
            Window.show_buffer(Map.fetch!(windows.map, windows.active), buffer)
          )
    }

    normalize_buffer_surface(workspace, buffer)
  end

  @spec normalize_buffer_surface(t(), pid()) :: t()
  defp normalize_buffer_surface(workspace, buffer) do
    %{
      workspace
      | keymap_scope: scope_for_content(Content.buffer(buffer), workspace.keymap_scope),
        launchpad: nil
    }
  end

  @spec remember_outgoing_cursor(Windows.t(), Window.t(), position() | nil) :: Windows.t()
  defp remember_outgoing_cursor(windows, %Window{content: {:buffer, _}}, {_, _} = cursor),
    do:
      Windows.replace_window(
        windows,
        windows.active,
        Window.remember_cursor(Map.fetch!(windows.map, windows.active), cursor)
      )

  defp remember_outgoing_cursor(windows, _window, _cursor), do: windows

  @spec commit_focused_window(t(), Windows.t(), Window.id(), Window.t()) :: t()
  defp commit_focused_window(workspace, windows, target_id, target_window) do
    buffers = buffers_for_focused_window(workspace.buffers, target_window)

    %{
      workspace
      | windows: Windows.set_active(windows, target_id),
        buffers: buffers,
        keymap_scope: scope_for_content(target_window.content, workspace.keymap_scope),
        launchpad: launchpad_after_focus(workspace.launchpad, target_window),
        hover_observation: HoverObservation.clear(workspace.hover_observation)
    }
  end

  @spec buffers_for_focused_window(Buffers.t(), Window.t()) :: Buffers.t()
  defp buffers_for_focused_window(buffers, %Window{content: {:buffer, buffer}})
       when is_pid(buffer) do
    selected = Buffers.switch_to_pid(buffers, buffer)
    if selected.active == buffer, do: selected, else: Buffers.set_active_override(buffers, buffer)
  end

  defp buffers_for_focused_window(buffers, %Window{}),
    do: Buffers.set_active_override(buffers, nil)

  @spec launchpad_after_focus(MingaEditor.State.Launchpad.t() | nil, Window.t()) ::
          MingaEditor.State.Launchpad.t() | nil
  defp launchpad_after_focus(launchpad, %Window{}), do: launchpad

  @doc """
  Enters the zero-buffers launchpad (#2689).

  Clears the active buffer, switches the active window's content to the
  empty-state surface, and snapshots launchpad data (session, recents).
  The window tree is untouched: the last window stays open.
  """
  @spec enter_empty_state(t()) :: t()
  @spec enter_empty_state(t(), keyword()) :: t()
  def enter_empty_state(wspace, launchpad_opts \\ [])

  def enter_empty_state(%__MODULE__{} = wspace, launchpad_opts) do
    windows =
      Windows.replace_window(
        wspace.windows,
        wspace.windows.active,
        Window.show_empty_state(Map.fetch!(wspace.windows.map, wspace.windows.active))
      )

    %{
      wspace
      | windows: windows,
        buffers: %Buffers{},
        launchpad: MingaEditor.State.Launchpad.new(launchpad_opts)
    }
  end

  @doc "True when the workspace is showing the zero-buffers launchpad."
  @spec empty_state?(t()) :: boolean()
  def empty_state?(%__MODULE__{launchpad: launchpad}), do: launchpad != nil

  @doc "Transitions the editing model to a new mode."
  @spec transition_mode(t(), atom(), term()) :: t()
  def transition_mode(%__MODULE__{editing: vim} = wspace, mode, mode_state \\ nil) do
    %{wspace | editing: VimState.transition(vim, mode, mode_state)}
  end

  @doc """
  Derives the keymap scope from a window's content type.

  Agent chat windows use `:agent`, launchpad windows use `:editor`, and buffer windows return from `:agent` to `:editor` while preserving other scopes.
  """
  @spec scope_for_content(Content.t(), Scope.scope_name()) :: Scope.scope_name()
  def scope_for_content({:agent_chat, _pid}, _current_scope), do: :agent
  def scope_for_content({:empty, :semantic}, _current_scope), do: :editor
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

  @doc "Returns FileTree UI state."
  @spec file_tree_state(t()) :: FileTreeState.t()
  def file_tree_state(%__MODULE__{file_tree: file_tree}), do: file_tree

  @doc "Replaces the FileTree UI state."
  @spec set_file_tree(t(), FileTreeState.t()) :: t()
  def set_file_tree(%__MODULE__{} = wspace, %FileTreeState{} = file_tree) do
    %{wspace | file_tree: file_tree}
  end

  @doc "Resets FileTree UI state."
  @spec drop_file_tree(t()) :: t()
  def drop_file_tree(%__MODULE__{} = wspace) do
    %{wspace | file_tree: %FileTreeState{}}
  end

  @doc "Replaces the dired sub-struct."
  @spec set_dired(t(), DiredState.t()) :: t()
  def set_dired(%__MODULE__{} = wspace, %DiredState{} = dired) do
    %{wspace | dired: dired}
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

  @doc "Records the transient Cmd/Ctrl-hover link range."
  @spec set_cmd_hover_link(t(), cmd_hover_link()) :: t()
  def set_cmd_hover_link(%__MODULE__{} = workspace, link) do
    %{
      workspace
      | hover_observation: HoverObservation.observe_link(workspace.hover_observation, link)
    }
  end

  @doc "Records the pointer cell that produced the hover observation."
  @spec set_cmd_hover_cell(t(), cmd_hover_cell()) :: t()
  def set_cmd_hover_cell(%__MODULE__{} = workspace, cell) do
    %{
      workspace
      | hover_observation: HoverObservation.observe_cell(workspace.hover_observation, cell)
    }
  end

  @doc "Clears the complete transient Cmd/Ctrl-hover observation."
  @spec clear_cmd_hover_link(t()) :: t()
  def clear_cmd_hover_link(%__MODULE__{} = workspace) do
    %{workspace | hover_observation: HoverObservation.clear(workspace.hover_observation)}
  end

  @doc "Updates the search sub-struct."
  @spec set_search(t(), Search.t()) :: t()
  def set_search(%__MODULE__{} = wspace, search) do
    %{wspace | search: search}
  end

  @doc "Updates the LSP pending requests map."
  @spec set_lsp_pending(t(), %{reference() => atom() | tuple()}) :: t()

  def set_lsp_pending(%__MODULE__{} = wspace, pending) do
    %{wspace | lsp_pending: pending}
  end

  @doc "Adds one pending LSP request to the workspace correlation table."
  @spec put_lsp_pending(t(), reference(), atom() | tuple()) :: t()
  def put_lsp_pending(%__MODULE__{} = workspace, ref, kind) when is_reference(ref) do
    set_lsp_pending(workspace, Map.put(workspace.lsp_pending, ref, kind))
  end

  @doc "Removes one pending LSP request from the workspace correlation table."
  @spec delete_lsp_pending(t(), reference()) :: t()
  def delete_lsp_pending(%__MODULE__{} = workspace, ref) when is_reference(ref) do
    set_lsp_pending(workspace, Map.delete(workspace.lsp_pending, ref))
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

  @doc "Records a concrete source-owned feature value."
  @spec record_feature_value(
          t(),
          FeatureState.source(),
          FeatureState.feature_id(),
          term()
        ) :: t()
  def record_feature_value(
        %__MODULE__{} = wspace,
        source,
        feature_id,
        value
      ) do
    put_feature_state(wspace, source, feature_id, value)
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

  @doc "Forgets a retired process when it owns the agent prompt buffer."
  @spec retire_agent_prompt_buffer(t(), pid()) :: t()
  def retire_agent_prompt_buffer(%__MODULE__{} = workspace, pid) when is_pid(pid) do
    %{workspace | agent_ui: UIState.retire_prompt_buffer(workspace.agent_ui, pid)}
  end

  @doc "Sets or clears the launchpad (zero-buffers empty state)."
  @spec set_launchpad(t(), MingaEditor.State.Launchpad.t() | nil) :: t()
  def set_launchpad(%__MODULE__{} = wspace, launchpad) do
    %{wspace | launchpad: launchpad}
  end
end
