defmodule MingaEditor.State do
  @moduledoc """
  Internal state for the Editor GenServer.

  ## Field categories

  EditorState fields fall into three categories:

  **Workspace fields** live in `state.workspace` (`MingaEditor.Session.State`)
  and are saved/restored when switching tabs. Each tab carries a snapshot
  of the workspace so switching tabs restores the full editing context.

  **Shell fields** live in `state.shell_state` and hold presentation concerns: chrome, overlays, transient UI state. The active shell id is `state.shell_id`; `state.shell` is the registered module cached for hot-path compatibility. See `MingaEditor.Shell` for the behaviour definition.

  **Global fields** are shared across all tabs and never snapshotted:
  `port_manager`, `theme`, `render_timer`, `focus_stack`,
  `capabilities`.

  ## Composed sub-structs

  * `MingaEditor.Session.State`           — per-tab editing context (buffers, windows, vim, etc.)
  * `MingaEditor.Shell.Traditional.State`   — default presentation state (nav_flash, hover, dashboard, etc.)
  * `MingaEditor.State.WhichKey`     — which-key popup node, timer, visibility
  * `MingaEditor.State.Registers`    — named registers and active register selection
  """

  alias MingaAgent.Session, as: AgentSession
  alias MingaEditor.Agent.BufferSync, as: AgentBufferSync
  alias MingaEditor.Agent.UIState
  alias MingaEditor.FeatureState
  alias Minga.Buffer

  alias MingaEditor.BottomPanel
  alias MingaEditor.KeystrokeHistory
  alias MingaEditor.FileTree.Feature, as: FileTreeFeature
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.Sidebar.BuiltinSurfaces
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Dired, as: DiredState
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.Shell.Identity, as: ShellIdentity
  alias MingaEditor.Shell.StateStash
  alias MingaEditor.State.Session, as: EditorSessionState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.Mouse
  alias MingaEditor.State.Remote
  alias MingaEditor.State.ResourcePressure
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.WhichKey
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.Window.Content
  alias MingaEditor.WindowTree
  alias MingaEditor.Frontend.Capabilities
  alias Minga.Log
  alias Minga.Mode
  alias Minga.Project.FileRef
  alias Minga.Project.FileTree

  alias MingaEditor.UI.Notification
  alias MingaEditor.UI.NotificationCenter
  alias MingaEditor.UI.Panel.MessageStore
  alias MingaEditor.UI.Theme
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.Workspace, as: WorkspaceModel

  @typedoc "Line number display style."
  @type line_number_style :: :hybrid | :absolute | :relative | :none

  @typedoc "A document highlight range from the LSP server."
  @type document_highlight :: Minga.LSP.DocumentHighlight.t()

  @typedoc "Re-export of `Minga.Keymap.server/0` for editor-state callers."
  @type keymap_server :: Minga.Keymap.server()

  @typedoc "Re-export of `Minga.Config.Options.server/0` for editor-state callers."
  @type options_server :: Minga.Config.Options.server()

  @typedoc "Event bus registry used by this editor instance."
  @type events_registry :: Minga.Events.registry()

  @default_keymap_server Minga.Keymap.default_server()
  @default_options_server Minga.Config.Options.default_server()
  @default_events_registry Minga.Events.default_registry()

  alias MingaEditor.Observatory
  alias MingaEditor.Shell.Traditional.State, as: ShellState

  @enforce_keys [:port_manager, :workspace]
  defstruct backend: :headless,
            port_manager: nil,
            renderer: nil,
            keymap_server: @default_keymap_server,
            options_server: @default_options_server,
            events_registry: @default_events_registry,
            sidebar_registry: MingaEditor.Extension.Sidebar.default_table(),
            workspace: nil,
            terminal_viewport: Viewport.new(24, 80),
            editing_model: :vim,
            shell_id: :traditional,
            shell: MingaEditor.Shell.Traditional,
            shell_identity: nil,
            shell_state: %ShellState{},
            theme: MingaEditor.UI.Theme.Fallback.theme(),
            render_timer: nil,
            message_store: %MessageStore{},
            notifications: NotificationCenter.new(),
            git_remote_op: nil,
            lsp: %LSPState{},
            parser_status: :available,
            focus_stack: [],
            capabilities: %Capabilities{},
            layout: nil,
            focus_tree: nil,
            last_cursor_line: nil,
            last_test_command: nil,
            pending_quit: nil,
            buffer_monitors: %{},
            diff_views: %{},
            face_override_registries: %{},
            caches: MingaEditor.Renderer.Caches.new(),
            session: %EditorSessionState{},
            buffer_add_context: :open,
            remote: %Remote{},
            resource_pressure: ResourcePressure.new(),
            shell_state_stash: %{},
            keystroke_history: KeystrokeHistory.new(),
            git_commit_gen_ref: nil,
            font_size_override: nil

  @type backend :: :tui | :gui | :native_gui | :headless

  @type shell_id :: atom()
  @type shell_state :: term()
  @type shell_identity :: ShellIdentity.t() | nil
  @type shell_state_stash :: %{shell_id() => StateStash.t()}

  @type t :: %__MODULE__{
          backend: backend(),
          port_manager: GenServer.server() | nil,
          renderer: pid() | nil,
          keymap_server: keymap_server(),
          options_server: options_server(),
          events_registry: events_registry(),
          sidebar_registry: MingaEditor.Extension.Sidebar.table(),
          workspace: SessionState.t(),
          terminal_viewport: Viewport.t(),
          editing_model: :vim | :cua,
          shell_id: shell_id(),
          shell: module(),
          shell_identity: shell_identity(),
          shell_state: shell_state(),
          theme: Theme.t(),
          render_timer: reference() | nil,
          message_store: MessageStore.t(),
          notifications: NotificationCenter.t(),
          git_remote_op: git_remote_op(),
          lsp: LSPState.t(),
          parser_status: MingaEditor.Shell.Traditional.Modeline.parser_status(),
          focus_stack: [module()],
          capabilities: Capabilities.t(),
          layout: MingaEditor.Layout.t() | nil,
          focus_tree: MingaEditor.FocusTree.t() | nil,
          last_cursor_line: non_neg_integer() | nil,
          last_test_command: {String.t(), String.t()} | nil,
          pending_quit: :quit | :quit_all | nil,
          buffer_monitors: %{pid() => reference()},
          diff_views: %{pid() => diff_view_info()},
          face_override_registries: %{pid() => MingaEditor.UI.Face.Registry.t()},
          caches: MingaEditor.Renderer.Caches.t(),
          buffer_add_context: MingaEditor.Shell.buffer_add_context(),
          remote: Remote.t(),
          resource_pressure: ResourcePressure.t(),
          session: EditorSessionState.t(),
          shell_state_stash: shell_state_stash(),
          keystroke_history: KeystrokeHistory.t(),
          git_commit_gen_ref: reference() | nil,
          font_size_override: pos_integer() | nil
        }

  @doc "Returns the active sidebar registry table for this state."
  @spec sidebar_registry(t() | map()) :: MingaEditor.Extension.Sidebar.table()
  def sidebar_registry(state), do: MingaEditor.Extension.Sidebar.table_for(state)

  @spec set_renderer(t(), pid() | nil) :: t()
  def set_renderer(%__MODULE__{} = state, pid) when is_pid(pid) or is_nil(pid),
    do: %{state | renderer: pid}

  @doc "Updates the current frontend-reported resource pressure."
  @spec set_resource_pressure(
          t(),
          boolean(),
          ResourcePressure.thermal_state()
        ) :: t()
  def set_resource_pressure(%__MODULE__{} = state, low_power?, thermal_state)
      when is_boolean(low_power?) do
    %{
      state
      | resource_pressure:
          ResourcePressure.update(state.resource_pressure, low_power?, thermal_state)
    }
  end

  @doc "Adds or updates a GUI notification."
  @spec upsert_notification(t(), Notification.t()) :: t()
  def upsert_notification(%__MODULE__{} = state, %Notification{} = notification) do
    %{state | notifications: NotificationCenter.upsert(state.notifications, notification)}
  end

  @doc "Dismisses a GUI notification by id."
  @spec dismiss_notification(t(), String.t()) :: t()
  def dismiss_notification(%__MODULE__{} = state, id) when is_binary(id) do
    %{state | notifications: NotificationCenter.dismiss(state.notifications, id)}
  end

  @doc "Dismisses a GUI notification only when the auto-dismiss ref still matches."
  @spec dismiss_notification(t(), String.t(), reference()) :: t()
  def dismiss_notification(%__MODULE__{} = state, id, dismiss_ref) when is_binary(id) do
    %{state | notifications: NotificationCenter.dismiss(state.notifications, id, dismiss_ref)}
  end

  @doc "Looks up an inline notification action."
  @spec notification_action(t(), String.t(), String.t()) :: Notification.Action.t() | nil
  def notification_action(%__MODULE__{} = state, notification_id, action_id) do
    NotificationCenter.action(state.notifications, notification_id, action_id)
  end

  @doc "Returns the keymap server used for scope and binding lookups."
  @spec keymap_server(t()) :: keymap_server()
  def keymap_server(%__MODULE__{keymap_server: keymap_server}), do: keymap_server

  @doc "Returns the keymap context keyword list passed to scoped key resolution."
  @spec keymap_context(t()) :: [{:keymap_server, keymap_server()}]
  def keymap_context(%__MODULE__{} = state),
    do: [keymap_server: keymap_server(state)]

  @doc "Returns the options server used for typed option lookups."
  @spec options_server(t()) :: options_server()
  def options_server(%__MODULE__{options_server: options_server}), do: options_server

  @doc "Returns the event bus registry used by this editor instance."
  @spec events_registry(t()) :: events_registry()
  def events_registry(%__MODULE__{events_registry: events_registry}), do: events_registry

  # ── Workspace helpers ──────────────────────────────────────────────────────

  @doc "Applies a function to the workspace and returns the updated state."
  @spec update_workspace(t(), (SessionState.t() -> SessionState.t())) :: t()
  def update_workspace(%__MODULE__{workspace: ws} = state, fun) when is_function(fun, 1) do
    %{state | workspace: fun.(ws)}
  end

  @doc "Replaces the active workspace."
  @spec set_workspace(t(), SessionState.t()) :: t()
  def set_workspace(%__MODULE__{} = state, %SessionState{} = workspace) do
    workspace |> SessionState.file_tree_state() |> sync_file_tree_sidebar(sidebar_registry(state))
    %{state | workspace: workspace}
  end

  @spec sync_file_tree_sidebar(FileTreeState.t(), MingaEditor.Extension.Sidebar.table()) :: :ok
  defp sync_file_tree_sidebar(%FileTreeState{} = file_tree, sidebar_registry) do
    case FileTreeFeature.sync_sidebar(file_tree, sidebar_registry) do
      :ok -> :ok
      {:error, reason} -> Log.warning(:editor, "FileTree sidebar sync failed: #{inspect(reason)}")
    end
  end

  @doc "Returns source-owned feature state from the active workspace, or nil when inactive."
  @spec get_feature_state(t(), FeatureState.source(), FeatureState.feature_id()) :: term() | nil
  def get_feature_state(%__MODULE__{workspace: workspace}, source, feature_id) do
    SessionState.get_feature_state(workspace, source, feature_id)
  end

  @doc "Stores source-owned feature state on the active workspace."
  @spec put_feature_state(t(), FeatureState.source(), FeatureState.feature_id(), term()) :: t()
  def put_feature_state(%__MODULE__{} = state, source, feature_id, value) do
    update_workspace(state, &SessionState.put_feature_state(&1, source, feature_id, value))
  end

  @doc "Updates source-owned feature state on the active workspace."
  @spec update_feature_state(
          t(),
          FeatureState.source(),
          FeatureState.feature_id(),
          term(),
          (term() -> term())
        ) :: t()
  def update_feature_state(%__MODULE__{} = state, source, feature_id, default, fun)
      when is_function(fun, 1) do
    update_workspace(
      state,
      &SessionState.update_feature_state(&1, source, feature_id, default, fun)
    )
  end

  @doc "Drops one source-owned feature state entry from the active workspace."
  @spec drop_feature_state(t(), FeatureState.source(), FeatureState.feature_id()) :: t()
  def drop_feature_state(%__MODULE__{} = state, source, feature_id) do
    update_workspace(state, &SessionState.drop_feature_state(&1, source, feature_id))
  end

  @doc "Drops all feature state owned by a source from live and snapshotted workspaces."
  @spec drop_feature_state_source(t(), FeatureState.source()) :: t()
  def drop_feature_state_source(%__MODULE__{} = state, source) do
    state
    |> update_workspace(&SessionState.drop_feature_state_source(&1, source))
    |> drop_tab_context_feature_state_source(source)
    |> drop_board_feature_state_source(source)
  end

  @doc "Drops extension-owned feature state from live and snapshotted workspaces."
  @spec drop_extension_feature_state_sources(t()) :: t()
  def drop_extension_feature_state_sources(%__MODULE__{} = state) do
    state
    |> update_workspace(&SessionState.drop_extension_feature_state_sources/1)
    |> drop_tab_context_extension_feature_state_sources()
    |> drop_board_extension_feature_state_sources()
  end

  @doc "Sets the active workspace viewport."
  @spec set_viewport(t(), Viewport.t()) :: t()
  def set_viewport(%__MODULE__{} = state, %Viewport{} = viewport) do
    update_workspace(state, &SessionState.set_viewport(&1, viewport))
  end

  @doc "Sets the active workspace keymap scope."
  @spec set_keymap_scope(t(), Minga.Keymap.Scope.scope_name()) :: t()
  def set_keymap_scope(%__MODULE__{} = state, scope) do
    update_workspace(state, &SessionState.set_keymap_scope(&1, scope))
  end

  @doc "Returns the active workspace FileTree feature state."
  @spec file_tree_state(t() | map()) :: FileTreeState.t()
  def file_tree_state(%__MODULE__{workspace: workspace}) do
    SessionState.file_tree_state(workspace)
  end

  def file_tree_state(%{workspace: %SessionState{} = workspace}) do
    SessionState.file_tree_state(workspace)
  end

  def file_tree_state(%{__struct__: MingaEditor.RenderPipeline.Input} = input) do
    MingaEditor.RenderPipeline.Input.file_tree_state(input)
  end

  def file_tree_state(_state), do: %FileTreeState{}

  @doc "Replaces the active workspace FileTree feature state."
  @spec set_file_tree(t(), FileTreeState.t()) :: t()
  def set_file_tree(%__MODULE__{} = state, %FileTreeState{} = file_tree) do
    sync_file_tree_sidebar(file_tree, sidebar_registry(state))
    update_workspace(state, &SessionState.set_file_tree(&1, file_tree))
  end

  @doc "Updates the active workspace FileTree feature state."
  @spec update_file_tree(t(), (FileTreeState.t() -> FileTreeState.t())) :: t()
  def update_file_tree(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    set_file_tree(state, fun.(file_tree_state(state)))
  end

  @doc "Drops the active workspace FileTree feature state."
  @spec drop_file_tree(t()) :: t()
  def drop_file_tree(%__MODULE__{} = state) do
    sync_file_tree_sidebar(%FileTreeState{}, sidebar_registry(state))
    update_workspace(state, &SessionState.drop_file_tree/1)
  end

  @doc "Replaces the active workspace buffer state."
  @spec set_buffers(t(), Buffers.t()) :: t()
  def set_buffers(%__MODULE__{} = state, %Buffers{} = buffers) do
    update_workspace(state, &SessionState.set_buffers(&1, buffers))
  end

  @doc "Updates the active workspace buffer state."
  @spec update_buffers(t(), (Buffers.t() -> Buffers.t())) :: t()
  def update_buffers(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    update_workspace(state, fn workspace ->
      SessionState.set_buffers(workspace, fun.(workspace.buffers))
    end)
  end

  @doc "Replaces the active workspace window state."
  @spec set_windows(t(), Windows.t()) :: t()
  def set_windows(%__MODULE__{} = state, %Windows{} = windows) do
    update_workspace(state, &SessionState.set_windows(&1, windows))
  end

  @doc "Updates the active workspace window state."
  @spec update_windows(t(), (Windows.t() -> Windows.t())) :: t()
  def update_windows(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    update_workspace(state, fn workspace ->
      SessionState.set_windows(workspace, fun.(workspace.windows))
    end)
  end

  @doc "Replaces the active workspace dired state."
  @spec set_dired(t(), DiredState.t()) :: t()
  def set_dired(%__MODULE__{} = state, %DiredState{} = dired) do
    update_workspace(state, &SessionState.set_dired(&1, dired))
  end

  @doc "Updates the active workspace dired state."
  @spec update_dired(t(), (DiredState.t() -> DiredState.t())) :: t()
  def update_dired(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    update_workspace(state, fn workspace ->
      SessionState.set_dired(workspace, fun.(workspace.dired))
    end)
  end

  @doc "Replaces the active workspace mouse state."
  @spec set_mouse(t(), Mouse.t()) :: t()
  def set_mouse(%__MODULE__{} = state, %Mouse{} = mouse) do
    update_workspace(state, &SessionState.set_mouse(&1, mouse))
  end

  @doc "Updates the active workspace mouse state."
  @spec update_mouse(t(), (Mouse.t() -> Mouse.t())) :: t()
  def update_mouse(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    update_workspace(state, fn workspace ->
      SessionState.set_mouse(workspace, fun.(workspace.mouse))
    end)
  end

  @doc "Replaces the active workspace search state."
  @spec set_search(t(), Search.t()) :: t()
  def set_search(%__MODULE__{} = state, %Search{} = search) do
    update_workspace(state, &SessionState.set_search(&1, search))
  end

  @doc "Updates the active workspace search state."
  @spec update_search(t(), (Search.t() -> Search.t())) :: t()
  def update_search(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    update_workspace(state, fn workspace -> SessionState.update_search(workspace, fun) end)
  end

  @doc "Replaces the active workspace highlighting state."
  @spec set_highlight(t(), Highlighting.t()) :: t()
  def set_highlight(%__MODULE__{} = state, %Highlighting{} = highlight) do
    update_workspace(state, &SessionState.set_highlight(&1, highlight))
  end

  @doc "Updates the active workspace highlighting state."
  @spec update_highlight(t(), (Highlighting.t() -> Highlighting.t())) :: t()
  def update_highlight(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    update_workspace(state, fn workspace -> SessionState.update_highlight(workspace, fun) end)
  end

  @doc "Replaces the active workspace editing state."
  @spec set_editing(t(), VimState.t()) :: t()
  def set_editing(%__MODULE__{} = state, %VimState{} = editing) do
    update_workspace(state, &SessionState.set_editing(&1, editing))
  end

  @doc "Updates the active workspace editing state."
  @spec update_editing(t(), (VimState.t() -> VimState.t())) :: t()
  def update_editing(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    update_workspace(state, fn workspace -> SessionState.update_editing(workspace, fun) end)
  end

  @doc """
  Replaces the current vim mode state without changing the mode.

  Use this only for same-mode state updates where the replacement has the shape expected by the current mode. Use `transition_mode/3` when changing modes so `VimState` can keep `mode` and `mode_state` aligned.
  """
  @spec set_mode_state(t(), Mode.state()) :: t()
  def set_mode_state(%__MODULE__{} = state, mode_state) do
    update_editing(state, &VimState.set_mode_state(&1, mode_state))
  end

  @doc """
  Updates the current vim mode state without changing the mode.

  Use this only for same-mode state updates where the mapper preserves the state shape expected by the current mode. Use `transition_mode/3` when changing modes so `VimState` can keep `mode` and `mode_state` aligned.
  """
  @spec update_mode_state(t(), (Mode.state() -> Mode.state())) :: t()
  def update_mode_state(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    update_editing(state, fn vim -> VimState.set_mode_state(vim, fun.(vim.mode_state)) end)
  end

  @doc "Replaces the vim register state."
  @spec set_registers(t(), MingaEditor.State.Registers.t()) :: t()
  def set_registers(%__MODULE__{} = state, %MingaEditor.State.Registers{} = registers) do
    update_editing(state, &VimState.set_registers(&1, registers))
  end

  @doc "Replaces the vim marks map."
  @spec set_marks(t(), VimState.marks()) :: t()
  def set_marks(%__MODULE__{} = state, marks) when is_map(marks) do
    update_editing(state, &VimState.set_marks(&1, marks))
  end

  @doc "Records the cursor position before a jump."
  @spec set_last_jump_pos(t(), Buffer.position() | nil) :: t()
  def set_last_jump_pos(%__MODULE__{} = state, pos) do
    update_editing(state, &VimState.set_last_jump_pos(&1, pos))
  end

  @doc "Records the last find-char motion."
  @spec set_last_find_char(t(), VimState.last_find_char()) :: t()
  def set_last_find_char(%__MODULE__{} = state, find_char) do
    update_editing(state, &VimState.set_last_find_char(&1, find_char))
  end

  @doc "Replaces the vim macro recorder."
  @spec set_macro_recorder(t(), MingaEditor.MacroRecorder.t()) :: t()
  def set_macro_recorder(%__MODULE__{} = state, recorder) do
    update_editing(state, &VimState.set_macro_recorder(&1, recorder))
  end

  @doc "Replaces the vim change recorder."
  @spec set_change_recorder(t(), MingaEditor.ChangeRecorder.t()) :: t()
  def set_change_recorder(%__MODULE__{} = state, recorder) do
    update_editing(state, &VimState.set_change_recorder(&1, recorder))
  end

  @doc "Replaces the active workspace document highlights."
  @spec set_document_highlights(t(), [document_highlight()] | nil) :: t()
  def set_document_highlights(%__MODULE__{} = state, highlights) do
    update_workspace(state, &SessionState.set_document_highlights(&1, highlights))
  end

  @doc "Replaces the active workspace LSP pending request map."
  @spec set_lsp_pending(t(), %{reference() => atom() | tuple()}) :: t()
  def set_lsp_pending(%__MODULE__{} = state, pending) when is_map(pending) do
    update_workspace(state, &SessionState.set_lsp_pending(&1, pending))
  end

  @doc "Adds or replaces an active workspace LSP pending request."
  @spec put_lsp_pending(t(), reference(), atom() | tuple()) :: t()
  def put_lsp_pending(%__MODULE__{} = state, ref, kind) when is_reference(ref) do
    update_workspace(state, fn workspace ->
      SessionState.set_lsp_pending(workspace, Map.put(workspace.lsp_pending, ref, kind))
    end)
  end

  @doc "Deletes an active workspace LSP pending request."
  @spec delete_lsp_pending(t(), reference()) :: t()
  def delete_lsp_pending(%__MODULE__{} = state, ref) when is_reference(ref) do
    update_workspace(state, fn workspace ->
      SessionState.set_lsp_pending(workspace, Map.delete(workspace.lsp_pending, ref))
    end)
  end

  @doc "Replaces the active workspace agent UI state."
  @spec set_agent_ui(t(), UIState.t()) :: t()
  def set_agent_ui(%__MODULE__{} = state, %UIState{} = agent_ui) do
    update_workspace(state, &SessionState.set_agent_ui(&1, agent_ui))
  end

  @doc "Replaces the active workspace injection ranges map."
  @spec set_injection_ranges(t(), %{pid() => [Minga.Language.Highlight.InjectionRange.t()]}) ::
          t()
  def set_injection_ranges(%__MODULE__{} = state, ranges) when is_map(ranges) do
    update_workspace(state, &SessionState.set_injection_ranges(&1, ranges))
  end

  @doc "Updates the active workspace injection ranges map."
  @spec update_injection_ranges(t(), (%{pid() => [Minga.Language.Highlight.InjectionRange.t()]} ->
                                        %{pid() => [Minga.Language.Highlight.InjectionRange.t()]})) ::
          t()
  def update_injection_ranges(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    update_workspace(state, fn workspace ->
      SessionState.set_injection_ranges(workspace, fun.(workspace.injection_ranges))
    end)
  end

  # ── Render pipeline write-back ─────────────────────────────────────────────

  @doc """
  Applies render pipeline mutations back to the editor state.

  The render pipeline updates window caches (invalidation tracking,
  context fingerprints), click regions, and layout during rendering.
  This function writes those mutations back after the pipeline completes.

  The `render_output` is a `RenderPipeline.Input` struct with the mutated
  fields. Only `windows`, `shell_state`, `layout`, and `caches` carry meaningful
  changes; other fields are unchanged.
  """
  @spec apply_render_output(t(), MingaEditor.RenderPipeline.Input.t()) :: t()
  def apply_render_output(%__MODULE__{workspace: ws} = state, render_output) do
    %{
      state
      | workspace: %{ws | windows: render_output.workspace.windows},
        shell_state: render_output.shell_state,
        shell_identity: Map.get(render_output, :shell_identity, state.shell_identity),
        layout: render_output.layout,
        focus_tree: render_output.focus_tree,
        caches: render_output.caches
    }
  end

  @doc """
  Applies asynchronous renderer writeback without overwriting editor-owned state.

  Async rendering runs from an older `RenderPipeline.Input` snapshot while the
  Editor process continues handling input. The renderer may return stale copies
  of windows and shell state, so this function only merges fields owned by the
  renderer: global render caches, layout, per-window render caches, and chrome
  click regions.
  """
  @spec apply_renderer_writeback(t(), map()) :: t()
  def apply_renderer_writeback(%__MODULE__{} = state, %{caches: caches, layout: layout} = wb) do
    if renderer_writeback_shell_current?(state, wb) do
      state = %{state | caches: caches, layout: layout, focus_tree: Map.get(wb, :focus_tree)}
      state = merge_renderer_windows_from_writeback(state, wb)
      merge_renderer_shell_from_writeback(state, wb)
    else
      log_stale_renderer_writeback(state, wb)
      state
    end
  end

  @spec renderer_writeback_shell_current?(t(), map()) :: boolean()
  defp renderer_writeback_shell_current?(%__MODULE__{} = state, wb) do
    case Map.fetch(wb, :shell_identity) do
      {:ok, %ShellIdentity{} = identity} -> renderer_identity_current?(state, identity)
      _missing_or_invalid -> false
    end
  end

  @spec renderer_identity_current?(t(), ShellIdentity.t()) :: boolean()
  defp renderer_identity_current?(%__MODULE__{} = state, %ShellIdentity{} = identity) do
    case MingaEditor.Shell.Registry.get(active_shell_id(state)) do
      %MingaEditor.Shell.Entry{} = entry -> ShellIdentity.matches?(identity, entry)
      nil -> false
    end
  end

  @spec log_stale_renderer_writeback(t(), map()) :: :ok
  defp log_stale_renderer_writeback(%__MODULE__{} = state, wb) do
    Log.debug(:render, fn ->
      "Dropping stale renderer writeback frame=#{inspect(Map.get(wb, :frame_seq))} shell=#{inspect(Map.get(wb, :shell_id))} identity=#{inspect(Map.get(wb, :shell_identity))} active_shell=#{inspect(active_shell_id(state))}"
    end)
  end

  @spec merge_renderer_windows_from_writeback(t(), map()) :: t()
  defp merge_renderer_windows_from_writeback(%__MODULE__{workspace: ws} = state, wb) do
    case Map.fetch(wb, :windows) do
      {:ok, %Windows{} = rendered_windows} ->
        windows = merge_renderer_windows(ws.windows, rendered_windows)
        %{state | workspace: %{ws | windows: windows}}

      _ ->
        state
    end
  end

  @spec merge_renderer_windows(Windows.t(), Windows.t()) :: Windows.t()
  defp merge_renderer_windows(%Windows{} = live_windows, %Windows{} = rendered_windows) do
    map =
      Map.new(live_windows.map, fn {id, live_window} ->
        {id, merge_renderer_window(live_window, Map.get(rendered_windows.map, id))}
      end)

    %{live_windows | map: map}
  end

  @spec merge_renderer_window(Window.t(), Window.t() | nil) :: Window.t()
  defp merge_renderer_window(%Window{} = live_window, %Window{} = rendered_window) do
    %{live_window | render_cache: rendered_window.render_cache}
  end

  defp merge_renderer_window(%Window{} = live_window, _rendered_window), do: live_window

  @spec merge_renderer_shell_from_writeback(t(), map()) :: t()
  defp merge_renderer_shell_from_writeback(%__MODULE__{} = state, wb) do
    with {:ok, shell_id} <- Map.fetch(wb, :shell_id),
         ^shell_id <- active_shell_id(state),
         {:ok, rendered_shell_state} <- Map.fetch(wb, :shell_state) do
      %{
        state
        | shell_state: merge_renderer_shell_state(state.shell_state, rendered_shell_state)
      }
    else
      _other -> state
    end
  end

  @spec merge_renderer_shell_state(shell_state(), term()) :: shell_state()
  defp merge_renderer_shell_state(live_shell_state, rendered_shell_state) do
    live_shell_state
    |> merge_renderer_shell_field(rendered_shell_state, :modeline_click_regions)
    |> merge_renderer_shell_field(rendered_shell_state, :tab_bar_click_regions)
  end

  @spec merge_renderer_shell_field(shell_state(), term(), atom()) :: shell_state()
  defp merge_renderer_shell_field(live_shell_state, rendered_shell_state, field) do
    if Map.has_key?(live_shell_state, field) and Map.has_key?(rendered_shell_state, field) do
      Map.put(live_shell_state, field, Map.fetch!(rendered_shell_state, field))
    else
      live_shell_state
    end
  end

  @doc "Applies a function to the shell state and returns the updated state."
  @spec update_shell_state(t() | %{shell_state: shell_state()}, (shell_state() -> shell_state())) ::
          t() | %{shell_state: shell_state()}
  def update_shell_state(%{shell_state: ss} = state, fun) when is_function(fun, 1) do
    %{state | shell_state: fun.(ss)}
  end

  @doc "Returns the active shell id, preserving compatibility with tests that still set only `:shell`."
  @spec active_shell_id(t() | map()) :: shell_id()
  def active_shell_id(%{shell_id: id, shell: shell}) do
    case MingaEditor.Shell.Registry.get(id) do
      %{module: ^shell} -> id
      _other -> MingaEditor.Shell.Registry.id_for_module(shell) || id
    end
  end

  def active_shell_id(%{shell: shell}) when is_atom(shell) do
    MingaEditor.Shell.Registry.id_for_module(shell) || MingaEditor.Shell.Registry.default().id
  end

  def active_shell_id(_state), do: MingaEditor.Shell.Registry.default().id

  @doc "Returns the active shell module, refreshing from the registry when possible."
  @spec active_shell_module(t() | map()) :: module()
  def active_shell_module(%__MODULE__{} = state) do
    case MingaEditor.Shell.Registry.get(state.shell_id) do
      %MingaEditor.Shell.Entry{} = entry -> active_shell_module_for_entry(state, entry)
      nil -> active_shell_module_for_missing_entry(state)
    end
  end

  def active_shell_module(%{
        shell_id: id,
        shell: fallback,
        shell_identity: %ShellIdentity{} = identity
      }) do
    case MingaEditor.Shell.Registry.get(id) do
      %MingaEditor.Shell.Entry{} = entry ->
        if ShellIdentity.matches?(identity, entry), do: entry.module, else: fallback

      nil ->
        fallback
    end
  end

  def active_shell_module(%{shell_id: id, shell: fallback}) do
    entry = MingaEditor.Shell.Registry.get(id)
    fallback_id = MingaEditor.Shell.Registry.id_for_module(fallback)
    resolve_active_shell_module(entry, id, fallback, fallback_id)
  end

  def active_shell_module(%{shell: shell}) when is_atom(shell), do: shell
  def active_shell_module(_state), do: MingaEditor.Shell.Registry.default().module

  @spec active_shell_module_for_entry(t(), MingaEditor.Shell.Entry.t()) :: module()
  defp active_shell_module_for_entry(%__MODULE__{} = state, %MingaEditor.Shell.Entry{} = entry) do
    if active_shell_entry_matches?(state, entry), do: entry.module, else: state.shell
  end

  @spec active_shell_module_for_missing_entry(t()) :: module()
  defp active_shell_module_for_missing_entry(%__MODULE__{} = state) do
    (MingaEditor.Shell.Registry.id_for_module(state.shell) && state.shell) ||
      MingaEditor.Shell.Registry.default().module
  end

  @spec resolve_active_shell_module(
          MingaEditor.Shell.Entry.t() | nil,
          shell_id(),
          module(),
          shell_id() | nil
        ) :: module()
  defp resolve_active_shell_module(%{module: module}, id, _fallback, id), do: module
  defp resolve_active_shell_module(%{module: module}, _id, _fallback, nil), do: module
  defp resolve_active_shell_module(%{}, _id, fallback, _fallback_id), do: fallback

  defp resolve_active_shell_module(nil, _id, _fallback, nil),
    do: MingaEditor.Shell.Registry.default().module

  defp resolve_active_shell_module(nil, _id, fallback, _fallback_id), do: fallback

  @doc "Ensures the active shell still exists, falling back to the registry default if it was unregistered."
  @spec ensure_shell_available(t()) :: t()
  def ensure_shell_available(%__MODULE__{} = state) do
    shell_id = active_shell_id(state)

    case MingaEditor.Shell.Registry.get(shell_id) do
      %MingaEditor.Shell.Entry{} = entry -> ensure_registered_shell_identity(state, entry)
      nil -> switch_to_default_shell(%{state | shell_id: shell_id})
    end
  end

  @spec ensure_registered_shell_identity(t(), MingaEditor.Shell.Entry.t()) :: t()
  defp ensure_registered_shell_identity(%__MODULE__{} = state, %MingaEditor.Shell.Entry{} = entry) do
    if active_shell_entry_matches?(state, entry) do
      refresh_active_shell_identity(state, entry)
    else
      reset_active_shell_identity(state, entry)
    end
  end

  @spec refresh_active_shell_identity(t(), MingaEditor.Shell.Entry.t()) :: t()
  defp refresh_active_shell_identity(
         %__MODULE__{shell_identity: nil} = state,
         %MingaEditor.Shell.Entry{source: :builtin} = entry
       ) do
    %{state | shell_id: entry.id, shell: entry.module}
  end

  defp refresh_active_shell_identity(%__MODULE__{} = state, %MingaEditor.Shell.Entry{} = entry) do
    %{state | shell_id: entry.id, shell: entry.module, shell_identity: ShellIdentity.new(entry)}
  end

  @spec reset_active_shell_identity(t(), MingaEditor.Shell.Entry.t()) :: t()
  defp reset_active_shell_identity(%__MODULE__{} = state, %MingaEditor.Shell.Entry{} = entry) do
    Log.warning(
      :editor,
      "Shell #{inspect(entry.id)} registry identity changed; resetting shell state"
    )

    %{
      state
      | shell_id: entry.id,
        shell: entry.module,
        shell_identity: ShellIdentity.new(entry),
        shell_state: init_shell_state(entry.module, state.shell_state),
        shell_state_stash: Map.delete(state.shell_state_stash, entry.id),
        layout: nil,
        focus_tree: nil
    }
    |> set_status("Shell #{entry.display_name} reloaded")
  end

  @spec active_shell_entry_matches?(t(), MingaEditor.Shell.Entry.t()) :: boolean()
  defp active_shell_entry_matches?(
         %__MODULE__{shell: shell},
         %MingaEditor.Shell.Entry{source: :builtin, module: shell}
       ) do
    true
  end

  defp active_shell_entry_matches?(
         %__MODULE__{shell: shell, shell_identity: %ShellIdentity{} = identity},
         %MingaEditor.Shell.Entry{} = entry
       ) do
    shell == entry.module and ShellIdentity.matches?(identity, entry)
  end

  defp active_shell_entry_matches?(
         %__MODULE__{shell: shell, shell_identity: nil},
         %MingaEditor.Shell.Entry{source: :builtin, module: shell}
       ) do
    true
  end

  defp active_shell_entry_matches?(%__MODULE__{shell_identity: nil}, %MingaEditor.Shell.Entry{}),
    do: false

  @doc "Switches to a registered shell by id, stashing the current shell state by shell id."
  @spec switch_shell(t(), shell_id()) :: t()
  def switch_shell(%__MODULE__{} = state, shell_id) when is_atom(shell_id) do
    MingaEditor.Shell.Registry.seed_builtin()
    do_switch_shell(state, shell_id, MingaEditor.Shell.Registry.list())
  end

  @spec do_switch_shell(t(), shell_id(), [MingaEditor.Shell.Entry.t()]) :: t()
  defp do_switch_shell(%__MODULE__{} = state, shell_id, entries) do
    current_id = active_shell_id(state)
    route_shell_switch(state, current_id, shell_id, entries)
  end

  @spec route_shell_switch(t(), shell_id(), shell_id(), [MingaEditor.Shell.Entry.t()]) :: t()
  defp route_shell_switch(%__MODULE__{} = state, current_id, shell_id, [_only])
       when shell_id != current_id do
    set_status(state, "Only one shell is available")
  end

  defp route_shell_switch(%__MODULE__{} = state, shell_id, shell_id, _entries) do
    set_status(state, "Already using #{shell_display_name(shell_id)}")
  end

  defp route_shell_switch(%__MODULE__{} = state, _current_id, shell_id, _entries) do
    case MingaEditor.Shell.Registry.get(shell_id) do
      %{module: module} -> switch_to_registered_shell(state, shell_id, module)
      nil -> set_status(state, "Shell #{shell_id} is unavailable")
    end
  end

  @spec switch_to_default_shell(t()) :: t()
  defp switch_to_default_shell(%__MODULE__{} = state) do
    default = MingaEditor.Shell.Registry.default()

    Log.warning(
      :editor,
      "Active shell #{inspect(active_shell_id(state))} (#{inspect(state.shell)}) is unavailable; switching to #{inspect(default.id)}"
    )

    state
    |> switch_to_registered_shell(default.id, default.module)
    |> set_status("Shell unavailable, switched to #{default.display_name}")
  end

  @spec switch_to_registered_shell(t(), shell_id(), module()) :: t()
  defp switch_to_registered_shell(%__MODULE__{} = state, target_id, module) do
    current_entry = current_shell_entry_for_stash(state)
    target_entry = MingaEditor.Shell.Registry.get(target_id)

    stash =
      state.shell_state_stash
      |> stash_current_shell(current_entry, state.shell_state)
      |> Map.delete(target_id)

    shell_state =
      restore_shell_state(state.shell_state_stash, target_entry, module, state.shell_state)

    %{
      state
      | shell_id: target_id,
        shell: module,
        shell_identity: shell_identity(target_entry),
        shell_state: shell_state,
        shell_state_stash: stash,
        layout: nil,
        focus_tree: nil
    }
  end

  @spec current_shell_entry_for_stash(t()) :: MingaEditor.Shell.Entry.t() | nil
  defp current_shell_entry_for_stash(%__MODULE__{} = state) do
    case MingaEditor.Shell.Registry.get(state.shell_id) do
      %MingaEditor.Shell.Entry{} = entry -> current_shell_entry_for_stash(state, entry)
      nil -> nil
    end
  end

  @spec current_shell_entry_for_stash(t(), MingaEditor.Shell.Entry.t()) ::
          MingaEditor.Shell.Entry.t() | nil
  defp current_shell_entry_for_stash(%__MODULE__{} = state, %MingaEditor.Shell.Entry{} = entry) do
    if active_shell_entry_matches?(state, entry), do: entry, else: nil
  end

  @spec shell_identity(MingaEditor.Shell.Entry.t() | nil) :: ShellIdentity.t() | nil
  defp shell_identity(%MingaEditor.Shell.Entry{} = entry), do: ShellIdentity.new(entry)
  defp shell_identity(nil), do: nil

  @spec stash_current_shell(shell_state_stash(), MingaEditor.Shell.Entry.t() | nil, shell_state()) ::
          shell_state_stash()
  defp stash_current_shell(stash, nil, _shell_state), do: stash

  defp stash_current_shell(stash, current_entry, shell_state) do
    Map.put(stash, current_entry.id, StateStash.new(current_entry, shell_state))
  end

  @spec restore_shell_state(
          shell_state_stash(),
          MingaEditor.Shell.Entry.t() | nil,
          module(),
          shell_state()
        ) ::
          shell_state()
  defp restore_shell_state(
         stash,
         %MingaEditor.Shell.Entry{} = target_entry,
         module,
         previous_shell_state
       ) do
    case Map.get(stash, target_entry.id) do
      %StateStash{} = stashed ->
        restore_matching_shell_state(stashed, target_entry, module, previous_shell_state)

      _other ->
        init_shell_state(module, previous_shell_state)
    end
  end

  defp restore_shell_state(_stash, _target_entry, module, previous_shell_state) do
    init_shell_state(module, previous_shell_state)
  end

  @spec restore_matching_shell_state(
          StateStash.t(),
          MingaEditor.Shell.Entry.t(),
          module(),
          shell_state()
        ) ::
          shell_state()
  defp restore_matching_shell_state(stashed, target_entry, module, previous_shell_state) do
    if StateStash.matches?(stashed, target_entry) do
      stashed.state
    else
      init_shell_state(module, previous_shell_state)
    end
  end

  @spec init_shell_state(module(), shell_state()) :: shell_state()
  defp init_shell_state(MingaEditor.Shell.Traditional, previous_shell_state) do
    %ShellState{
      suppress_tool_prompts: Map.get(previous_shell_state, :suppress_tool_prompts, false)
    }
  end

  defp init_shell_state(module, _previous_shell_state), do: module.init([])

  @spec shell_display_name(shell_id()) :: String.t()
  defp shell_display_name(shell_id) do
    case MingaEditor.Shell.Registry.get(shell_id) do
      %{display_name: name} -> name
      nil -> Atom.to_string(shell_id)
    end
  end

  # ── Shell field delegates ────────────────────────────────────────────────
  # Thin wrappers that delegate to `ShellState` through `update_shell_state/2`.
  # Both `update_shell_state` and `ShellState` methods use bare-map patterns
  # so they work with Traditional state, Board state, and test stubs alike.
  # The canonical @doc lives in `MingaEditor.Shell.Traditional.State`.

  @spec status_msg(t()) :: String.t() | nil
  def status_msg(%{shell_state: ss}), do: ShellState.status_msg(ss)
  @spec set_status(t(), String.t()) :: t()
  def set_status(s, msg), do: update_shell_state(s, &ShellState.set_status(&1, msg))
  @spec clear_status(t()) :: t()
  def clear_status(s), do: update_shell_state(s, &ShellState.clear_status/1)

  @spec nav_flash(t()) :: MingaEditor.NavFlash.t() | nil
  def nav_flash(%{shell_state: ss}), do: ShellState.nav_flash(ss)
  @spec set_nav_flash(t(), MingaEditor.NavFlash.t()) :: t()
  def set_nav_flash(s, flash), do: update_shell_state(s, &ShellState.set_nav_flash(&1, flash))
  @spec cancel_nav_flash(t()) :: t()
  def cancel_nav_flash(s), do: update_shell_state(s, &ShellState.cancel_nav_flash/1)

  @spec yank_flash(t()) :: MingaEditor.YankFlash.t() | nil
  def yank_flash(%{shell_state: ss}), do: ShellState.yank_flash(ss)
  @spec set_yank_flash(t(), MingaEditor.YankFlash.t()) :: t()
  def set_yank_flash(s, flash), do: update_shell_state(s, &ShellState.set_yank_flash(&1, flash))
  @spec cancel_yank_flash(t()) :: t()
  def cancel_yank_flash(s), do: update_shell_state(s, &ShellState.cancel_yank_flash/1)

  @spec hover_popup(t()) :: MingaEditor.HoverPopup.t() | nil
  def hover_popup(%{shell_state: ss}), do: ShellState.hover_popup(ss)
  @spec set_hover_popup(t(), MingaEditor.HoverPopup.t()) :: t()
  def set_hover_popup(s, popup), do: update_shell_state(s, &ShellState.set_hover_popup(&1, popup))
  @spec dismiss_hover_popup(t()) :: t()
  def dismiss_hover_popup(s), do: update_shell_state(s, &ShellState.dismiss_hover_popup/1)

  @spec whichkey(t()) :: WhichKey.t()
  def whichkey(%{shell_state: ss}), do: ShellState.whichkey(ss)
  @spec set_whichkey(t(), WhichKey.t()) :: t()
  def set_whichkey(s, wk), do: update_shell_state(s, &ShellState.set_whichkey(&1, wk))

  @spec bottom_panel(t()) :: BottomPanel.t()
  def bottom_panel(%{shell_state: ss}), do: ShellState.bottom_panel(ss)
  @spec set_bottom_panel(t(), BottomPanel.t()) :: t()
  def set_bottom_panel(s, panel),
    do: update_shell_state(s, &ShellState.set_bottom_panel(&1, panel))

  @spec git_status_panel(t()) :: ShellState.git_status_panel() | nil
  def git_status_panel(%{shell_state: ss}), do: ShellState.git_status_panel(ss)
  @spec set_git_status_panel(t(), ShellState.git_status_panel() | nil) :: t()
  def set_git_status_panel(s, nil) do
    sync_git_status_sidebar(s, nil)
    update_shell_state(s, &ShellState.set_git_status_panel(&1, nil))
  end

  def set_git_status_panel(s, data) do
    panel = GitStatusPanel.new(data)
    sync_git_status_sidebar(s, panel)
    update_shell_state(s, &ShellState.set_git_status_panel(&1, panel))
  end

  @spec sync_git_status_sidebar(t(), GitStatusPanel.t() | nil) :: :ok
  defp sync_git_status_sidebar(state, panel) do
    case BuiltinSurfaces.sync_git_status_panel(panel, sidebar_registry(state)) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.warning(:editor, "Git Status sidebar sync failed: #{inspect(reason)}")
    end
  end

  @spec close_git_status_panel(t()) :: t()
  def close_git_status_panel(s) do
    sync_git_status_sidebar(s, nil)
    update_shell_state(s, &ShellState.close_git_status_panel/1)
  end

  @spec sidebar_active_id(t()) :: String.t() | nil
  def sidebar_active_id(%{shell_state: %{sidebar_active_id: id}}), do: id
  def sidebar_active_id(_state), do: nil

  @spec set_sidebar_active_id(t(), String.t() | nil) :: t()
  def set_sidebar_active_id(s, id) when is_binary(id) or is_nil(id) do
    sync_active_sidebar(s, id)

    update_shell_state(s, fn ss ->
      if Map.has_key?(ss, :sidebar_active_id),
        do: ShellState.set_sidebar_active_id(ss, id),
        else: ss
    end)
  end

  @spec sync_active_sidebar(t(), String.t() | nil) :: :ok
  defp sync_active_sidebar(state, id) do
    case MingaEditor.Extension.Sidebar.focus_left(sidebar_registry(state), id) do
      :ok -> :ok
      {:error, reason} -> Log.warning(:editor, "Sidebar focus sync failed: #{inspect(reason)}")
    end
  end

  @spec observatory_visible?(t()) :: boolean()
  def observatory_visible?(%{shell_state: ss}), do: ShellState.observatory_visible?(ss)

  @spec open_observatory(t(), {reference(), reference()} | nil) :: t()
  def open_observatory(s, timer) do
    sync_observatory_sidebar(s, true)
    update_shell_state(s, &ShellState.open_observatory(&1, timer))
  end

  @spec close_observatory(t()) :: t()
  def close_observatory(s) do
    sync_observatory_sidebar(s, false)
    update_shell_state(s, &ShellState.close_observatory/1)
  end

  @spec sync_observatory_sidebar(t(), boolean()) :: :ok
  defp sync_observatory_sidebar(state, visible?) do
    case BuiltinSurfaces.sync_observatory(visible?, sidebar_registry(state)) do
      :ok ->
        :ok

      {:error, reason} ->
        Log.warning(:editor, "Observatory sidebar sync failed: #{inspect(reason)}")
    end
  end

  @spec set_observatory_data(t(), Observatory.Data.t() | nil) :: t()
  def set_observatory_data(s, data),
    do: update_shell_state(s, &ShellState.set_observatory_data(&1, data))

  @spec set_observatory_timer(t(), {reference(), reference()} | nil) :: t()
  def set_observatory_timer(s, timer),
    do: update_shell_state(s, &ShellState.set_observatory_timer(&1, timer))

  @spec set_observatory_inspection(t(), Observatory.Inspection.t() | nil) :: t()
  def set_observatory_inspection(s, inspection),
    do: update_shell_state(s, &ShellState.set_observatory_inspection(&1, inspection))

  @spec set_git_toast(t(), ShellState.git_toast()) :: t()
  def set_git_toast(s, toast), do: update_shell_state(s, &ShellState.set_git_toast(&1, toast))

  @spec clear_git_toast(t()) :: t()
  def clear_git_toast(s), do: update_shell_state(s, &ShellState.clear_git_toast/1)

  @spec clear_git_toast(t(), reference()) :: t()
  def clear_git_toast(s, dismiss_ref),
    do: update_shell_state(s, &ShellState.clear_git_toast(&1, dismiss_ref))

  @spec tab_bar(t()) :: TabBar.t() | nil
  def tab_bar(%{shell_state: ss}), do: ShellState.tab_bar(ss)
  @spec set_tab_bar(t(), TabBar.t() | nil) :: t()
  def set_tab_bar(s, tb), do: update_shell_state(s, &ShellState.set_tab_bar(&1, tb))

  @spec drop_tab_context_feature_state_source(t(), FeatureState.source()) :: t()
  defp drop_tab_context_feature_state_source(
         %__MODULE__{shell_state: %ShellState{}} = state,
         source
       ) do
    case tab_bar(state) do
      %TabBar{} = tb -> set_tab_bar(state, TabBar.drop_feature_state_source(tb, source))
      _other -> state
    end
  end

  defp drop_tab_context_feature_state_source(%__MODULE__{} = state, _source), do: state

  @spec drop_tab_context_extension_feature_state_sources(t()) :: t()
  defp drop_tab_context_extension_feature_state_sources(
         %__MODULE__{shell_state: %ShellState{}} = state
       ) do
    case tab_bar(state) do
      %TabBar{} = tb -> set_tab_bar(state, TabBar.drop_extension_feature_state_sources(tb))
      _other -> state
    end
  end

  defp drop_tab_context_extension_feature_state_sources(%__MODULE__{} = state), do: state

  @spec drop_board_feature_state_source(t(), FeatureState.source()) :: t()
  defp drop_board_feature_state_source(%__MODULE__{} = state, source) do
    state
    |> update_active_shell_feature_state(:drop_feature_state_source, [source])
    |> update_stashed_shell_feature_state(:drop_feature_state_source, [source])
  end

  @spec drop_board_extension_feature_state_sources(t()) :: t()
  defp drop_board_extension_feature_state_sources(%__MODULE__{} = state) do
    state
    |> update_active_shell_feature_state(:drop_extension_feature_state_sources, [])
    |> update_stashed_shell_feature_state(:drop_extension_feature_state_sources, [])
  end

  @spec update_active_shell_feature_state(t(), atom(), [term()]) :: t()
  defp update_active_shell_feature_state(%__MODULE__{} = state, callback, args) do
    module = active_shell_module(state)

    case apply_optional_shell_callback(module, state.shell_state, callback, args) do
      {:ok, shell_state} -> %{state | shell_state: shell_state}
      :missing -> state
    end
  end

  @spec update_stashed_shell_feature_state(t(), atom(), [term()]) :: t()
  defp update_stashed_shell_feature_state(
         %__MODULE__{shell_state_stash: stash} = state,
         callback,
         args
       ) do
    stash =
      Map.new(stash, fn {shell_id, shell_state} ->
        {shell_id, clean_stashed_shell_state(shell_id, shell_state, callback, args)}
      end)

    %{state | shell_state_stash: stash}
  end

  @spec clean_stashed_shell_state(shell_id(), StateStash.t() | term(), atom(), [term()]) ::
          StateStash.t() | term()
  defp clean_stashed_shell_state(_shell_id, %StateStash{} = stashed, callback, args) do
    case apply_optional_shell_callback(stashed.module, stashed.state, callback, args) do
      {:ok, cleaned_shell_state} -> %StateStash{stashed | state: cleaned_shell_state}
      :missing -> stashed
    end
  end

  defp clean_stashed_shell_state(shell_id, shell_state, callback, args) do
    module = MingaEditor.Shell.Registry.module_for(shell_id)

    case apply_optional_shell_callback(module, shell_state, callback, args) do
      {:ok, cleaned_shell_state} -> cleaned_shell_state
      :missing -> shell_state
    end
  end

  @spec apply_optional_shell_callback(module() | nil, term(), atom(), [term()]) ::
          {:ok, term()} | :missing
  defp apply_optional_shell_callback(module, shell_state, callback, args)
       when is_atom(module) and not is_nil(module) do
    arity = length(args) + 1

    if shell_callback_exported?(module, callback, arity) do
      {:ok, apply(module, callback, [shell_state | args])}
    else
      :missing
    end
  end

  defp apply_optional_shell_callback(_module, _shell_state, _callback, _args), do: :missing

  @spec shell_callback_exported?(module(), atom(), arity()) :: boolean()
  defp shell_callback_exported?(module, callback, arity) do
    Code.ensure_loaded?(module) and Enum.member?(module.__info__(:functions), {callback, arity})
  end

  @spec agent(t()) :: AgentState.t()
  def agent(%{shell_state: ss}), do: ShellState.agent(ss)
  @spec set_agent(t(), AgentState.t()) :: t()
  def set_agent(s, agent), do: update_shell_state(s, &ShellState.set_agent(&1, agent))

  @spec modal(t()) :: MingaEditor.State.ModalOverlay.t()
  def modal(%{shell_state: ss}), do: ShellState.modal(ss)
  @spec set_modal(t(), MingaEditor.State.ModalOverlay.t()) :: t()
  def set_modal(s, modal), do: update_shell_state(s, &ShellState.set_modal(&1, modal))

  @spec inline_asks(t()) :: MingaEditor.State.InlineAsk.store()
  def inline_asks(%{shell_state: ss}), do: ShellState.inline_asks(ss)
  @spec set_inline_asks(t(), MingaEditor.State.InlineAsk.store()) :: t()
  def set_inline_asks(s, asks), do: update_shell_state(s, &ShellState.set_inline_asks(&1, asks))

  @spec inline_edits(t()) :: MingaEditor.State.InlineEdit.store()
  def inline_edits(%{shell_state: ss}), do: ShellState.inline_edits(ss)
  @spec set_inline_edits(t(), MingaEditor.State.InlineEdit.store()) :: t()
  def set_inline_edits(s, edits),
    do: update_shell_state(s, &ShellState.set_inline_edits(&1, edits))

  # ── Global field accessors ─────────────────────────────────────────────────

  @typedoc "Metadata for an open diff view buffer."
  @type diff_view_info :: %{
          required(:source_buf) => pid() | nil,
          required(:git_root) => String.t(),
          required(:rel_path) => String.t(),
          required(:staged) => boolean(),
          required(:line_metadata) => [Minga.Core.DiffView.line_meta()],
          required(:hunk_lines) => [non_neg_integer()],
          optional(:view_mode) => :unified | :side_by_side,
          optional(:pane_width) => pos_integer()
        }

  @typedoc "The git_remote_op tracking tuple, or nil when no operation is in flight."
  @type git_remote_op ::
          {msg_ref :: reference(), task_monitor :: reference(),
           {git_root :: String.t(), success_msg :: String.t(), error_prefix :: String.t()}}
          | nil

  @spec set_git_remote_op(t(), git_remote_op()) :: t()
  def set_git_remote_op(%__MODULE__{} = state, op), do: %{state | git_remote_op: op}

  @spec clear_git_remote_op(t()) :: t()
  def clear_git_remote_op(%__MODULE__{} = state), do: %{state | git_remote_op: nil}

  @spec register_diff_view(t(), pid(), diff_view_info()) :: t()
  def register_diff_view(%__MODULE__{} = state, diff_buf, info) when is_pid(diff_buf),
    do: %{state | diff_views: Map.put(state.diff_views, diff_buf, info)}

  @spec unregister_diff_view(t(), pid()) :: t()
  def unregister_diff_view(%__MODULE__{} = state, diff_buf) when is_pid(diff_buf),
    do: %{state | diff_views: Map.delete(state.diff_views, diff_buf)}

  @spec diff_view_info(t(), pid() | nil) :: diff_view_info() | nil
  def diff_view_info(%__MODULE__{}, nil), do: nil

  def diff_view_info(%__MODULE__{} = state, diff_buf) when is_pid(diff_buf),
    do: Map.get(state.diff_views, diff_buf)

  @spec diff_view_for_source(t(), pid()) :: {pid(), diff_view_info()} | nil
  def diff_view_for_source(%__MODULE__{} = state, source_buf) when is_pid(source_buf) do
    Enum.find(state.diff_views, fn {_diff_buf, info} -> info.source_buf == source_buf end)
  end

  @spec diff_views_for_source(t(), pid()) :: [{pid(), diff_view_info()}]
  def diff_views_for_source(%__MODULE__{} = state, source_buf) when is_pid(source_buf) do
    Enum.filter(state.diff_views, fn {_diff_buf, info} -> info.source_buf == source_buf end)
  end

  @spec set_pending_quit(t(), :quit | :quit_all) :: t()
  def set_pending_quit(%__MODULE__{} = state, kind) when kind in [:quit, :quit_all],
    do: %{state | pending_quit: kind}

  @spec clear_pending_quit(t()) :: t()
  def clear_pending_quit(%__MODULE__{} = state), do: %{state | pending_quit: nil}

  @spec set_last_test_command(t(), {String.t(), String.t()}) :: t()
  def set_last_test_command(%__MODULE__{} = state, {_cmd, _root} = val),
    do: %{state | last_test_command: val}

  @doc "Applies a function to remote session state."
  @spec update_remote(t(), (Remote.t() -> Remote.t())) :: t()
  def update_remote(%__MODULE__{remote: remote} = state, fun) when is_function(fun, 1) do
    %{state | remote: fun.(remote)}
  end

  @spec update_lsp(t(), (LSPState.t() -> LSPState.t())) :: t()
  def update_lsp(%__MODULE__{lsp: lsp} = state, fun) when is_function(fun, 1),
    do: %{state | lsp: fun.(lsp)}

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
  @spec start_buffer(String.t(), Minga.Config.Options.server() | nil) ::
          {:ok, pid()} | {:error, term()}
  def start_buffer(file_path, options_server \\ Minga.Config.Options.default_server()) do
    options_server = normalize_options_server(options_server)

    DynamicSupervisor.start_child(
      Minga.Buffer.Supervisor,
      {Minga.Buffer, file_path: file_path, options_server: options_server}
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

  @spec normalize_options_server(term() | nil) :: Minga.Config.Options.server()
  defp normalize_options_server(nil), do: Minga.Config.Options.default_server()
  defp normalize_options_server(server), do: Minga.Config.Options.validate_server!(server)

  @doc """
  Monitors a list of buffer pids. Convenience wrapper around `monitor_buffer/2`.
  """
  @spec monitor_buffers(t(), [pid()]) :: t()
  def monitor_buffers(state, pids) when is_list(pids) do
    Enum.reduce(pids, state, &monitor_buffer(&2, &1))
  end

  @doc """
  Pure variant of `remove_dead_buffer/2`. Returns `{state, effects}` instead
  of performing side effects directly.

  Removes the pid from the buffer list, clears it from special buffer slots,
  switches to another buffer if the active one died, and cleans up the
  monitor ref. This function is already pure (no process calls), so the
  effects list is always empty.
  """
  @spec close_buffer_pure(t(), pid()) :: {t(), [MingaEditor.effect()]}
  def close_buffer_pure(%__MODULE__{} = state, pid) do
    state = do_remove_dead_buffer(state, pid)
    state = ensure_shell_available(state)

    # Dispatch to the shell for presentation cleanup (tab removal, card updates, etc.)
    {shell_state, workspace, shell_effects} =
      active_shell_module(state).on_buffer_died(state.shell_state, state.workspace, pid)

    {%{state | shell_state: shell_state, workspace: workspace}, shell_effects}
  end

  @doc """
  Removes a dead buffer pid from all state locations.

  Called from the Editor's `:DOWN` handler. Removes the pid from the buffer
  list, clears it from special buffer slots (messages, warnings, help), and
  switches to another buffer if the active one died. Also cleans up the
  monitor ref.

  Thin wrapper around `close_buffer_pure/2` that applies effects inline.
  """
  @spec remove_dead_buffer(t(), pid()) :: t()
  def remove_dead_buffer(%__MODULE__{} = state, pid) do
    {state, effects} = close_buffer_pure(state, pid)
    apply_buffer_effects(state, effects)
  end

  @spec do_remove_dead_buffer(t(), pid()) :: t()
  defp do_remove_dead_buffer(
         %__MODULE__{workspace: %{buffers: %Buffers{} = bs}, buffer_monitors: monitors} = state,
         pid
       ) do
    monitors = Map.delete(monitors, pid)
    new_bs = Buffers.remove(bs, pid)

    state = %{
      update_workspace(state, &SessionState.set_buffers(&1, new_bs))
      | buffer_monitors: monitors
    }

    state =
      if state.shell_state.agent.buffer == pid do
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

    state = unregister_diff_view(state, pid)

    case tab_bar(state) do
      nil -> state
      tb -> set_tab_bar(state, TabBar.scrub_dead_buffer(tb, pid))
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
    do: SessionState.active_window_struct(ws)

  @doc "Returns true if the editor has more than one window."
  @spec split?(t()) :: boolean()
  def split?(%__MODULE__{workspace: ws}), do: SessionState.split?(ws)

  @doc "Updates the window struct for the given window id via a mapper function."
  @spec update_window(t(), Window.id(), (Window.t() -> Window.t())) :: t()
  def update_window(%__MODULE__{} = state, id, fun) do
    update_workspace(state, &SessionState.update_window(&1, id, fun))
  end

  @doc "Updates every window showing a buffer via a mapper function."
  @spec update_windows_for_buffer(t(), pid(), (Window.t() -> Window.t())) :: t()
  def update_windows_for_buffer(%__MODULE__{} = state, buffer, fun)
      when is_pid(buffer) and is_function(fun, 1) do
    update_workspace(state, &SessionState.update_windows_for_buffer(&1, buffer, fun))
  end

  @doc """
  Invalidates render caches for all windows.

  Call when the screen layout changes (file tree toggle, agent panel toggle)
  because cached draws contain baked-in absolute coordinates that become
  wrong when column offsets shift.
  """
  @spec invalidate_all_windows(t()) :: t()
  def invalidate_all_windows(%__MODULE__{} = state) do
    update_workspace(state, &SessionState.invalidate_all_windows/1)
  end

  @doc "Clears frontend-retained render state after a frontend ready/recovery event."
  @spec reset_frontend_render_state(t()) :: t()
  def reset_frontend_render_state(%__MODULE__{} = state) do
    state
    |> update_workspace(&SessionState.mark_frontend_reset_pending/1)
    |> then(fn state ->
      %{state | caches: MingaEditor.Renderer.Caches.reset_frontend_state(state.caches)}
    end)
  end

  @doc """
  Returns the terminal-level viewport: total screen rows/cols reported by
  the frontend on resize. Used for screen-spanning chrome (picker,
  popups, dashboard, completion menu placement) and for layout
  computation that needs the editor's full canvas.

  This is distinct from `current_viewport/1`, which scopes to the
  active window's viewport.
  """
  @spec terminal_viewport(t()) :: Viewport.t()
  def terminal_viewport(%__MODULE__{terminal_viewport: vp}), do: vp

  @doc """
  Stores a new terminal viewport. Called by the editor's resize handler
  when the frontend reports a new screen size.
  """
  @spec set_terminal_viewport(t(), Viewport.t()) :: t()
  def set_terminal_viewport(%__MODULE__{} = state, %Viewport{} = vp) do
    %{state | terminal_viewport: vp}
  end

  @doc """
  Returns the viewport for the user's current focus: the active window's
  viewport when a window is active, otherwise a derived terminal-size
  viewport (the no-window dashboard case). Use this for scroll commands
  that read/write the focused window's viewport.

  Replaces the older `active_window_viewport/1` (renamed for symmetry
  with `terminal_viewport/1`).
  """
  @spec current_viewport(t()) :: Viewport.t()
  def current_viewport(%__MODULE__{} = state) do
    case active_window_struct(state) do
      nil -> terminal_viewport(state)
      %Window{viewport: vp} -> vp
    end
  end

  @doc """
  Updates the active window's viewport. No-op when no window is active
  (the dashboard case has no per-window viewport to write).

  Replaces the older `put_active_window_viewport/2`.
  """
  @spec update_current_viewport(t(), Viewport.t()) :: t()
  def update_current_viewport(%__MODULE__{} = state, %Viewport{} = new_vp) do
    case active_window_struct(state) do
      nil -> state
      %Window{id: win_id} -> update_window(state, win_id, &Window.set_viewport(&1, new_vp))
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
  def screen_rect(%__MODULE__{terminal_viewport: vp} = state) do
    case file_tree_state(state).tree do
      %FileTree{width: tw} ->
        # Tree occupies columns 0..tw-1, separator at column tw,
        # editor content starts at column tw+1.
        editor_col = tw + 1
        editor_width = max(vp.cols - editor_col, 1)
        {0, editor_col, editor_width, vp.rows - 1}

      nil ->
        {0, 0, vp.cols, vp.rows - 1}
    end
  end

  @doc "Returns the screen rect for the file tree panel, or nil if closed."
  @spec tree_rect(t()) :: WindowTree.rect() | nil
  def tree_rect(%__MODULE__{terminal_viewport: vp} = state) do
    case file_tree_state(state).tree do
      %FileTree{width: tw} ->
        # Row 0 is the tab bar; file tree starts at row 1.
        {1, 0, tw, vp.rows - 2}

      nil ->
        nil
    end
  end

  # ── Cross-cutting window + buffer helpers ─────────────────────────────────

  @doc """
  Syncs the active window's buffer reference with `state.workspace.buffers.active`.

  Call this after any operation that changes `state.workspace.buffers.active` to keep the
  window tree consistent. No-op when windows aren't initialized.
  """
  @spec sync_active_window_buffer(t()) :: t()
  def sync_active_window_buffer(%__MODULE__{} = state) do
    update_workspace(state, &SessionState.sync_active_window_buffer/1)
  end

  @doc "Returns the set of buffer pids known to the live workspace and tab snapshots."
  @spec known_open_buffer_pids(t()) :: [pid()]
  def known_open_buffer_pids(%__MODULE__{} = state) do
    (state.workspace.buffers.list ++ tab_context_buffer_pids(state.shell_state.tab_bar))
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
  end

  @doc """
  Rebinds the logical file identity for matching tabs and their workspaces.

  Use this after a buffer save, save-as, or path retarget so the live tab and its workspace
  stop pointing at stale buffer refs and start pointing at the new path ref.
  """
  @spec rebind_buffer_file_identity(t(), pid()) :: t()
  def rebind_buffer_file_identity(%__MODULE__{} = state, buffer_pid) when is_pid(buffer_pid) do
    case {matching_file_tabs(state.shell_state.tab_bar, buffer_pid),
          buffer_file_ref(buffer_pid, state.workspace)} do
      {[], _} ->
        state

      {_, nil} ->
        state

      {tabs, %FileRef{} = file_ref} ->
        updated_tab_bar = rebind_tabs_to_file_ref(state.shell_state.tab_bar, tabs, file_ref)
        %{state | shell_state: %{state.shell_state | tab_bar: updated_tab_bar}}
    end
  end

  @spec rebind_tabs_to_file_ref(TabBar.t(), [Tab.t()], FileRef.t()) :: TabBar.t()
  defp rebind_tabs_to_file_ref(%TabBar{} = tab_bar, tabs, %FileRef{} = file_ref) do
    active_tab_id = tab_bar_active_id(tab_bar)

    tabs
    |> Enum.reduce(tab_bar, &set_tab_file_ref(&2, &1, file_ref))
    |> then(fn updated_tab_bar ->
      Enum.reduce(tabs, updated_tab_bar, &retarget_tab_workspace(&2, &1, file_ref, active_tab_id))
    end)
  end

  @spec set_tab_file_ref(TabBar.t(), Tab.t(), FileRef.t()) :: TabBar.t()
  defp set_tab_file_ref(%TabBar{} = tab_bar, %Tab{id: tab_id}, %FileRef{} = file_ref) do
    TabBar.update_tab(tab_bar, tab_id, &Tab.set_file_ref(&1, file_ref))
  end

  @spec retarget_tab_workspace(TabBar.t(), Tab.t(), FileRef.t(), Tab.id() | nil) :: TabBar.t()
  defp retarget_tab_workspace(
         %TabBar{} = tab_bar,
         %Tab{id: tab_id, group_id: workspace_id, file_ref: old_file_ref},
         %FileRef{} = file_ref,
         active_tab_id
       ) do
    TabBar.update_workspace(tab_bar, workspace_id, fn workspace ->
      WorkspaceModel.retarget_file(workspace, old_file_ref, file_ref, tab_id == active_tab_id)
    end)
  end

  @spec matching_file_tabs(TabBar.t() | nil, pid()) :: [Tab.t()]
  defp matching_file_tabs(nil, _buffer_pid), do: []

  defp matching_file_tabs(%TabBar{tabs: tabs}, buffer_pid) do
    Enum.filter(tabs, &tab_matches_buffer_identity?(&1, buffer_pid))
  end

  @spec tab_matches_buffer_identity?(Tab.t(), pid()) :: boolean()
  defp tab_matches_buffer_identity?(
         %Tab{kind: :file, file_ref: %FileRef{kind: :buffer, buffer_pid: pid}},
         pid
       ),
       do: true

  defp tab_matches_buffer_identity?(%Tab{kind: :file, context: context}, pid) do
    case TabContext.to_workspace_map(context) do
      %{buffers: %Buffers{active: ^pid}} -> true
      _ -> false
    end
  end

  defp tab_matches_buffer_identity?(_tab, _pid), do: false

  @spec tab_context_buffer_pids(TabBar.t() | nil) :: [pid()]
  defp tab_context_buffer_pids(nil), do: []

  defp tab_context_buffer_pids(%TabBar{tabs: tabs}) do
    Enum.flat_map(tabs, fn %Tab{context: context} ->
      case TabContext.to_workspace_map(context) do
        %{buffers: %Buffers{} = buffers} -> tab_buffer_pids(buffers)
        _ -> []
      end
    end)
  end

  @spec tab_buffer_pids(Buffers.t()) :: [pid()]
  defp tab_buffer_pids(%Buffers{active: active, list: list}) do
    [active | list]
    |> Enum.filter(&is_pid/1)
    |> Enum.uniq()
  end

  @spec tab_bar_active_id(TabBar.t()) :: Tab.id()
  defp tab_bar_active_id(%TabBar{active_id: active_id}), do: active_id

  @spec buffer_file_ref(pid(), SessionState.t()) :: FileRef.t() | nil
  defp buffer_file_ref(buffer_pid, %SessionState{} = workspace) do
    case {buffer_path(buffer_pid), SessionState.file_tree_state(workspace).project_root} do
      {path, root} when is_binary(path) and is_binary(root) ->
        case FileRef.from_path(root, path) do
          {:ok, file_ref} -> file_ref
          {:error, :outside_project} -> FileRef.from_buffer(buffer_pid)
        end

      _ ->
        FileRef.from_buffer(buffer_pid)
    end
  catch
    :exit, _ -> nil
  end

  @spec buffer_path(pid()) :: String.t() | nil
  defp buffer_path(pid) when is_pid(pid) do
    Buffer.file_path(pid)
  catch
    :exit, _ -> nil
  end

  @doc """
  Sets the context for the next `add_buffer` call.

  Used by picker preview to mark buffer additions as transient previews
  rather than permanent opens. The context is consumed and reset to
  `:open` by `add_buffer_pure/3`.
  """
  @spec set_buffer_add_context(t(), MingaEditor.Shell.buffer_add_context()) :: t()
  def set_buffer_add_context(%__MODULE__{} = state, context)
      when context in [:open, :preview] do
    %{state | buffer_add_context: context}
  end

  @doc """
  Pure variant of `add_buffer/2`. Returns `{state, effects}` instead of
  performing side effects directly.

  Generic concerns (buffer pool) are handled here. Shell-specific
  presentation logic (tab bar, card routing) is dispatched through
  `shell.on_buffer_added/5`. The only effect returned is `{:monitor, pid}`.

  The buffer-add context is read from `state.buffer_add_context` (set by
  picker preview) or overridden via `opts[:context]`. After dispatch the
  field is reset to `:open`.
  """
  @spec add_buffer_pure(t(), pid(), keyword()) :: {t(), [MingaEditor.effect()]}
  def add_buffer_pure(%__MODULE__{workspace: %{buffers: bs}} = state, pid, opts \\ []) do
    context = Keyword.get_lazy(opts, :context, fn -> state.buffer_add_context end)

    # Idempotent: if the buffer is already in the pool, just activate it
    # instead of appending a duplicate. This lets confirm call add_buffer
    # for a buffer that preview already loaded.
    already_pooled = pid in bs.list

    new_bs =
      if already_pooled do
        Buffers.switch_to(bs, Enum.find_index(bs.list, &(&1 == pid)))
      else
        Buffers.add(bs, pid)
      end

    prev_workspace = state.workspace

    state =
      state
      |> update_workspace(&SessionState.set_buffers(&1, new_bs))
      |> ensure_shell_available()

    # Dispatch to the active shell for presentation logic
    {shell_state, workspace, shell_effects} =
      active_shell_module(state).on_buffer_added(
        state.shell_state,
        prev_workspace,
        state.workspace,
        pid,
        context
      )

    state =
      state
      |> update_shell_state(fn _ -> shell_state end)
      |> set_workspace(workspace)
      |> Map.put(:buffer_add_context, :open)

    effects = if already_pooled, do: [], else: [{:monitor, pid}]
    {state, effects ++ shell_effects}
  end

  @doc """
  Adds a new buffer and makes it the active buffer for the current window.

  Thin wrapper around `add_buffer_pure/3` that applies effects inline.
  """
  @spec add_buffer(t(), pid(), keyword()) :: t()
  def add_buffer(%__MODULE__{} = state, pid, opts \\ []) do
    {state, effects} = add_buffer_pure(state, pid, opts)
    apply_buffer_effects(state, effects)
  end

  @doc """
  Switches to the buffer at `idx`, making it active for the current window.

  Centralizes `Buffers.switch_to` + window sync so callers don't need to
  remember to call `sync_active_window_buffer/1`. Shell-specific
  presentation logic (tab label updates, etc.) is dispatched through
  `shell.on_buffer_switched/2`.
  """
  @spec switch_buffer(t(), non_neg_integer()) :: t()
  def switch_buffer(%__MODULE__{} = state, idx) do
    state =
      state
      |> update_workspace(&SessionState.switch_buffer(&1, idx))
      |> ensure_shell_available()

    case state.buffer_add_context do
      :preview ->
        %{state | buffer_add_context: :open}

      :open ->
        {shell_state, workspace, shell_effects} =
          active_shell_module(state).on_buffer_switched(state.shell_state, state.workspace)

        state =
          state
          |> update_shell_state(fn _ -> shell_state end)
          |> set_workspace(workspace)

        apply_buffer_effects(state, shell_effects)
    end
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
  catch
    :exit, _ -> state
  end

  @doc """
  Derives the keymap scope from a window's content type.

  Agent chat windows always use `:agent` scope. Buffer windows use
  `:editor` when coming from `:agent` scope, and preserve the current
  scope otherwise (e.g., `:file_tree` stays as `:file_tree`).
  """
  @spec scope_for_content(Content.t(), Minga.Keymap.Scope.scope_name()) ::
          Minga.Keymap.Scope.scope_name()
  defdelegate scope_for_content(content, current_scope), to: SessionState

  @doc """
  Returns the appropriate keymap scope for the active window's content type.

  Used when leaving the file tree (toggle, close, navigate right) to restore
  the correct scope. Returns :agent for agent chat windows, :editor otherwise.
  """
  @spec scope_for_active_window(t()) :: atom()
  def scope_for_active_window(%{workspace: ws}) do
    SessionState.scope_for_active_window(ws)
  end

  # ── Tab bar helpers ───────────────────────────────────────────────────────

  @doc """
  Captures the current per-tab fields into a context struct.

  The returned struct is stored in the outgoing tab so it can be restored
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

  @spec snapshot_workspace_fields(SessionState.t()) :: Tab.context()
  defp snapshot_workspace_fields(%SessionState{} = ws) do
    ws
    |> SessionState.to_tab_context()
    |> put_non_default_shared_tab_fields(ws)
  end

  @spec put_non_default_shared_tab_fields(Tab.context(), SessionState.t()) :: Tab.context()
  defp put_non_default_shared_tab_fields(context, %SessionState{} = ws) do
    context
    |> put_shared_tab_field(:highlight, ws.highlight, %Highlighting{})
    |> put_shared_tab_field(:injection_ranges, ws.injection_ranges, %{})
    |> put_shared_tab_field(:agent_ui, ws.agent_ui, UIState.new())
  end

  @spec put_shared_tab_field(Tab.context(), TabContext.field_name(), term(), term()) ::
          Tab.context()
  defp put_shared_tab_field(context, _field, default_value, default_value), do: context

  defp put_shared_tab_field(context, field, value, _default_value) do
    TabContext.put_fields(context, %{field => value})
  end

  @doc """
  Writes a tab context back into the live editor state.

  The context carries workspace fields as an explicit struct. Empty context means a brand-new tab; we build defaults with the current active buffer and viewport dimensions.
  """
  @spec restore_tab_context(t(), Tab.context() | Tab.legacy_context()) :: t()
  def restore_tab_context(%__MODULE__{} = state, context) when is_map(context) do
    {context, state} =
      if TabContext.empty?(context) do
        synthesized = build_empty_tab_defaults(state)

        state =
          case tab_bar(state) do
            %TabBar{active_id: id} = tb ->
              set_tab_bar(state, TabBar.update_context(tb, id, synthesized))

            _ ->
              state
          end

        {synthesized, state}
      else
        {TabContext.from_map(context), state}
      end

    state
    |> set_workspace(SessionState.restore_tab_context(state.workspace, context))
    |> sync_agent_ui_from_active_workspace()
  end

  # Builds a typed context for a brand-new tab, using agent-shaped defaults for agent tabs.
  @spec build_empty_tab_defaults(t()) :: Tab.context()
  defp build_empty_tab_defaults(state) do
    case active_tab_for_defaults(state) do
      %Tab{kind: :agent} -> build_empty_agent_tab_defaults(state)
      _tab -> build_file_tab_defaults(state)
    end
  end

  @spec active_tab_for_defaults(t()) :: Tab.t() | nil
  defp active_tab_for_defaults(state) do
    case tab_bar(state) do
      %TabBar{} = tb -> TabBar.active(tb)
      _other -> nil
    end
  end

  @spec build_empty_agent_tab_defaults(t()) :: Tab.context()
  defp build_empty_agent_tab_defaults(state) do
    agent_buf = AgentBufferSync.start_buffer(normalize_options_server(state.options_server))
    rows = max(state.terminal_viewport.rows, 1)
    cols = max(state.terminal_viewport.cols, 1)
    windows = build_agent_chat_windows(agent_buf, rows, cols)
    build_agent_tab_defaults(state, windows, agent_buf)
  end

  @spec build_file_tab_defaults(t()) :: Tab.context()
  defp build_file_tab_defaults(state) do
    win_id = state.workspace.windows.next_id
    rows = state.terminal_viewport.rows
    cols = state.terminal_viewport.cols
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

    TabContext.from_workspace_map(%{
      keymap_scope: :editor,
      buffers: %Buffers{
        active: buf,
        list: if(buf, do: [buf], else: []),
        active_index: state.workspace.buffers.active_index
      },
      windows: windows,
      dired: %DiredState{},
      viewport: state.terminal_viewport,
      mouse: %Mouse{},
      lsp_pending: %{},
      search: %Search{},
      editing: VimState.new(),
      file_tree: file_tree_with_current_root(state),
      feature_state: FeatureState.new(),
      document_highlights: nil
    })
  end

  @doc """
  Builds a complete per-tab context for an agent tab.

  Used by agent tab creation paths to ensure all `@per_tab_fields` are
  populated. Accepts a pre-built `Windows` struct for the agent chat
  window and the agent buffer pid.
  """
  @spec build_agent_tab_defaults(t(), Windows.t(), pid() | nil) :: Tab.context()
  def build_agent_tab_defaults(state, windows, agent_buf) do
    TabContext.from_workspace_map(%{
      keymap_scope: :agent,
      buffers: %Buffers{
        active: agent_buf,
        list: if(agent_buf, do: [agent_buf], else: []),
        active_index: 0
      },
      windows: windows,
      dired: %DiredState{},
      viewport: state.terminal_viewport,
      mouse: %Mouse{},
      lsp_pending: %{},
      search: %Search{},
      editing: VimState.new(),
      file_tree: file_tree_with_current_root(state),
      feature_state: FeatureState.new(),
      document_highlights: nil
    })
  end

  @doc """
  Builds a fresh agent-shaped workspace context for shell-owned agent surfaces.

  Returns a `Tab.context()` carrying a single agent-chat window sized to the current viewport, with the agent keymap scope. The caller restores it via `restore_tab_context/2` and then activates the relevant shell-owned session pid against the window content.

  Falls back to an empty `Windows` map when no agent buffer is available; the caller's activation step then becomes a no-op.
  """
  @spec build_agent_workspace_context(t(), pid() | nil) :: Tab.context()
  def build_agent_workspace_context(%__MODULE__{} = state, agent_buf) do
    rows = max(state.workspace.viewport.rows, 1)
    cols = max(state.workspace.viewport.cols, 1)

    windows = build_agent_chat_windows(agent_buf, rows, cols)
    build_agent_tab_defaults(state, windows, agent_buf)
  end

  @spec build_agent_chat_windows(pid() | nil, pos_integer(), pos_integer()) :: Windows.t()
  defp build_agent_chat_windows(agent_buf, rows, cols) when is_pid(agent_buf) do
    win_id = 1
    agent_window = Window.new_agent_chat(win_id, agent_buf, rows, cols)

    %Windows{
      tree: WindowTree.new(win_id),
      map: %{win_id => agent_window},
      active: win_id,
      next_id: win_id + 1
    }
  end

  defp build_agent_chat_windows(_agent_buf, _rows, _cols), do: %Windows{}

  @spec file_tree_with_current_root(t()) :: FileTreeState.t()
  defp file_tree_with_current_root(%__MODULE__{} = state) do
    %FileTreeState{project_root: file_tree_state(state).project_root}
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

  @doc """
  Pure variant of `switch_tab/2`. Returns `{state, effects}` instead of
  performing side effects directly.

  Snapshots the current tab's context, updates the tab bar pointer,
  restores the target tab's context, invalidates layout. Side effects
  (spinner stop/start, agent session rebuild) are returned as effects.

  The returned effects list may include:
  - `:stop_spinner` — cancel the outgoing agent's spinner timer
  - `{:rebuild_agent_session, tab}` — rebuild agent state from session process
  - `:start_spinner` — conditionally restart spinner for incoming agent
  """
  @spec switch_tab_pure(t(), Tab.id()) :: {t(), [MingaEditor.effect()]}
  def switch_tab_pure(%__MODULE__{} = state, target_id) do
    state = ensure_shell_available(state)

    case tab_bar(state) do
      nil ->
        {state, []}

      %TabBar{active_id: ^target_id} ->
        {state, []}

      %TabBar{active_id: current_id} = tb ->
        log_switch_tab(tb, current_id, target_id)

        # Snapshot current tab (spinner stop is deferred as effect)
        context = snapshot_tab_context_no_sync(state)
        tb = TabBar.update_context(tb, current_id, context)

        # Switch pointer
        tb = TabBar.switch_to(tb, target_id)

        # Restore target tab's context
        %Tab{} = target = TabBar.active(tb)
        state = set_tab_bar(state, tb)

        state = restore_tab_context(state, target.context)
        state = sync_agent_ui_from_active_workspace(state)

        # If the active modal is completion belonging to the leaving tab,
        # dismiss it so it doesn't follow us to the new tab.
        state = MingaEditor.State.ModalOverlay.dismiss_if_stale(state)

        # Clear attention flag on the tab we're switching to.
        state =
          set_tab_bar(
            state,
            TabBar.update_tab(tab_bar(state), target_id, &Tab.set_attention(&1, false))
          )

        log_switch_tab_result(state)

        state =
          state
          |> invalidate_all_windows()
          |> Map.put(:layout, nil)

        # Collect side effects: stop outgoing spinner, rebuild session, maybe restart spinner
        effects = [:stop_spinner, {:rebuild_agent_session, target}, :start_spinner]

        {state, effects}
    end
  end

  @doc """
  Switches to the tab with `target_id`.

  Snapshots the current tab's context, stores it, updates the tab bar's
  active pointer, and restores the target tab's saved context into the
  live editor state. Invalidates layout and window caches since the
  entire visual context changes.

  Thin wrapper around `switch_tab_pure/2` that applies effects inline.
  """
  @spec switch_tab(t(), Tab.id()) :: t()
  def switch_tab(%__MODULE__{} = state, target_id) do
    {state, effects} = switch_tab_pure(state, target_id)
    apply_buffer_effects(state, effects)
  end

  @doc "Syncs the live workspace agent UI mirror from the active workspace."
  @spec sync_agent_ui_from_active_workspace(t()) :: t()
  def sync_agent_ui_from_active_workspace(
        %__MODULE__{shell_state: %{tab_bar: %TabBar{} = tab_bar}} = state
      ) do
    agent_ui =
      case TabBar.active_workspace(tab_bar) do
        %{agent_ui: %UIState{} = agent_ui} -> agent_ui
        _ -> UIState.new()
      end

    agent_ui = maybe_activate_synced_agent_ui(state, agent_ui)

    state = update_workspace(state, &SessionState.set_agent_ui(&1, agent_ui))
    drain_pending_catchup_events(state, tab_bar)
  end

  def sync_agent_ui_from_active_workspace(state), do: state

  @spec maybe_activate_synced_agent_ui(t(), UIState.t()) :: UIState.t()
  defp maybe_activate_synced_agent_ui(
         %__MODULE__{workspace: %{keymap_scope: :agent} = workspace},
         agent_ui
       ) do
    UIState.activate(agent_ui, workspace.windows, SessionState.file_tree_state(workspace))
  end

  defp maybe_activate_synced_agent_ui(%__MODULE__{}, agent_ui) do
    agent_ui
  end

  @spec drain_pending_catchup_events(t(), TabBar.t()) :: t()
  defp drain_pending_catchup_events(state, tab_bar) do
    case TabBar.active_workspace(tab_bar) do
      %WorkspaceModel{id: workspace_id, pending_catchup_events: [_ | _] = events} ->
        state = MingaEditor.Agent.Events.replay_catchup(state, events)

        tb =
          TabBar.update_workspace(
            tab_bar(state),
            workspace_id,
            &%{&1 | pending_catchup_events: []}
          )

        set_tab_bar(state, tb)

      _ ->
        state
    end
  end

  @spec active_tab(t()) :: Tab.t() | nil
  def active_tab(%__MODULE__{} = state) do
    state = ensure_shell_available(state)
    active_shell_module(state).active_tab(state.shell_state)
  end

  @spec find_tab_by_buffer(t(), pid()) :: Tab.t() | nil
  def find_tab_by_buffer(%__MODULE__{} = state, pid) do
    state = ensure_shell_available(state)
    active_shell_module(state).find_tab_by_buffer(state.shell_state, pid)
  end

  @spec active_tab_kind(t()) :: Tab.kind()
  def active_tab_kind(%__MODULE__{} = state) do
    state = ensure_shell_available(state)
    active_shell_module(state).active_tab_kind(state.shell_state)
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

  @spec set_tab_session(t(), Tab.id(), pid() | nil) :: t()
  def set_tab_session(%__MODULE__{} = state, tab_id, session_pid) do
    state = ensure_shell_available(state)

    shell_state =
      active_shell_module(state).set_tab_session(state.shell_state, tab_id, session_pid)

    %{state | shell_state: shell_state}
  end

  @doc """
  Rebuilds the agent rendering cache from the Session process when
  switching to an agent tab. The Session is the source of truth for
  status, pending approval, and error; the cache lives on
  `state.shell_state.agent` and is repopulated from the Tab's session
  pid on every tab switch.

  The session pid itself lives on `Tab.session` (see `set_tab_session/3`),
  not on the agent cache. `AgentAccess.session/1` reads it through the
  shell behaviour.
  """
  @spec rebuild_agent_from_session(t(), Tab.t()) :: t()
  def rebuild_agent_from_session(state, %Tab{kind: :agent, session: session_pid})
      when is_pid(session_pid) do
    state = bind_agent_buffer_from_active_window(state)

    case agent_snapshot(session_pid) do
      nil ->
        AgentAccess.update_agent(state, &AgentState.clear_active_tool_name/1)

      snapshot ->
        AgentAccess.update_agent(state, fn agent ->
          AgentState.apply_session_snapshot(
            agent,
            snapshot.status,
            snapshot.pending_approval,
            snapshot.error,
            Map.get(snapshot, :active_tool_name)
          )
        end)
    end
  end

  def rebuild_agent_from_session(state, _tab), do: state

  @spec bind_agent_buffer_from_active_window(t()) :: t()
  defp bind_agent_buffer_from_active_window(state) do
    case find_agent_chat_window(state) do
      {_win_id, %Window{content: {:agent_chat, _}, buffer: buffer}} when is_pid(buffer) ->
        AgentAccess.update_agent(state, &AgentState.set_buffer(&1, buffer))

      _ ->
        state
    end
  end

  @spec agent_snapshot(pid()) :: map() | nil
  defp agent_snapshot(session_pid) do
    AgentSession.editor_snapshot(session_pid)
  catch
    :exit, _ -> nil
  end

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
    update_workspace(state, &SessionState.transition_mode(&1, mode, mode_state))
  end

  # ── Tool prompt helpers ──────────────────────────────────────────────────────

  @doc """
  Returns true if the given tool should NOT be prompted for installation.

  A tool is skipped when it's already declined this session, already
  installed, currently being installed, or already in the prompt queue.
  """
  @spec skip_tool_prompt?(t(), atom()) :: boolean()
  def skip_tool_prompt?(%__MODULE__{shell_state: ss}, tool_name) do
    ShellState.skip_tool_prompt?(ss, tool_name)
  end

  # ── Buffer lifecycle effect application ──────────────────────────────────────
  #
  # Applies effects returned by `add_buffer_pure/2`, `switch_tab_pure/2`, and
  # `close_buffer_pure/2`. These thin wrappers live here (not in Editor) to
  # avoid a circular dependency. Only handles the effect types produced by
  # buffer lifecycle operations.

  @spec apply_buffer_effects(t(), [MingaEditor.effect()]) :: t()
  defp apply_buffer_effects(state, []), do: state

  defp apply_buffer_effects(state, [effect | rest]) do
    state = apply_buffer_effect(state, effect)
    apply_buffer_effects(state, rest)
  end

  @spec apply_buffer_effect(t(), MingaEditor.effect()) :: t()
  defp apply_buffer_effect(state, {:monitor, pid}) when is_pid(pid),
    do: monitor_buffer(state, pid)

  defp apply_buffer_effect(state, :stop_spinner),
    do: stop_outgoing_spinner(state)

  defp apply_buffer_effect(state, :start_spinner),
    do: maybe_restart_incoming_spinner(state)

  # Race safety: agent events queued during the blocking editor_snapshot/1 call
  # cannot misroute. GenServer serialisation means no handle_info runs until this
  # callback returns. Once it does, stale events from the outgoing session fail
  # the AgentAccess.session/1 identity check (minga_editor.ex:692) and fall into
  # the background path, where find_by_session matches by session pid (unique per
  # tab, never reassigned on switch). See #1401 for the full analysis.
  defp apply_buffer_effect(state, {:rebuild_agent_session, %Tab{kind: :agent} = tab}) do
    state
    |> rebuild_agent_from_session(tab)
    |> sync_active_agent_buffer()
  end

  defp apply_buffer_effect(state, {:rebuild_agent_session, tab}),
    do: rebuild_agent_from_session(state, tab)

  @spec sync_active_agent_buffer(t()) :: t()
  defp sync_active_agent_buffer(state) do
    agent = AgentAccess.agent(state)
    session = AgentAccess.session(state)

    if is_pid(agent.buffer) and is_pid(session) do
      sync_agent_buffer_from_session(state, agent.buffer, session, agent.pending_approval)
    else
      state
    end
  end

  @spec sync_agent_buffer_from_session(t(), pid(), pid(), term()) :: t()
  defp sync_agent_buffer_from_session(state, buffer, session, pending_approval) do
    messages = safe_session_messages(session)

    case messages do
      [] ->
        state

      _ ->
        sync_opts = if pending_approval, do: [pending_approval: pending_approval], else: []
        sync_opts = put_session_message_ids(sync_opts, session)

        {line_index, display_messages, display_message_pairs} =
          AgentBufferSync.sync(buffer, messages, sync_opts)

        AgentAccess.update_panel(
          state,
          &%{
            &1
            | cached_line_index: line_index,
              cached_display_messages: display_messages,
              cached_display_message_pairs: display_message_pairs
          }
        )
    end
  end

  @spec safe_session_messages(pid()) :: [term()]
  defp safe_session_messages(session) do
    AgentSession.messages(session)
  catch
    :exit, _ -> []
  end

  @spec put_session_message_ids(keyword(), pid()) :: keyword()
  defp put_session_message_ids(opts, session) do
    Keyword.put(opts, :message_ids, AgentSession.messages_with_ids(session))
  catch
    :exit, _ -> opts
  end
end
