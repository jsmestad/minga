defmodule MingaEditor.State do
  @moduledoc """
  Internal state for the Editor GenServer.

  ## Field categories

  EditorState fields fall into three categories:

  **Workspace fields** live in `state.workspace` (`MingaEditor.Session.State`)
  and are saved/restored when switching tabs. Each tab carries a snapshot
  of the workspace so switching tabs restores the full editing context.

  **Shell runtime** lives in `state.shell_runtime` and owns the resolved active entry, shell-specific presentation state, and exact-identity state stash. See `MingaEditor.Shell.Runtime`.

  **Global fields** are shared across all tabs and never snapshotted:
  `port_manager`, `parser_manager`, `highlighting`, `injection_ranges`, `theme`, `render_correlation`, `focus_stack`, `lsp`, and `capabilities`.

  ## Composed sub-structs

  * `MingaEditor.Session.State`           — per-tab editing context (buffers, windows, vim, etc.)
  * `MingaEditor.Shell.Traditional.State`   — default presentation state (nav_flash, hover, status_msg, etc.)
  * `MingaEditor.State.WhichKey`     — which-key popup node, timer, visibility
  * `MingaEditor.State.Registers`    — named registers and active register selection
  * `MingaEditor.State.Highlighting` — live per-buffer highlight presentation caches
  """

  alias MingaAgent.Session, as: AgentSession
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
  alias MingaEditor.Shell.Runtime, as: ShellRuntime
  alias MingaEditor.Shell.Workflow, as: ShellWorkflow
  alias MingaEditor.State.Session, as: EditorSessionState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Highlighting
  alias MingaEditor.State.Mouse
  alias MingaEditor.State.Remote
  alias MingaEditor.State.RenderCorrelation
  alias MingaEditor.State.ResourcePressure
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.WhichKey
  alias MingaEditor.State.Windows
  alias MingaEditor.Renderer.WindowObservation
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
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

  @typedoc "Transient Cmd/Ctrl-hover go-to-definition link range, or nil."
  @type cmd_hover_link :: SessionState.cmd_hover_link()

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
            rendering: :enabled,
            port_manager: nil,
            parser_manager: Minga.Parser.Manager,
            renderer: nil,
            agent_ingest: nil,
            agent_provider_module: nil,
            agent_provider_opts: [],
            keymap_server: @default_keymap_server,
            options_server: @default_options_server,
            events_registry: @default_events_registry,
            sidebar_registry: MingaEditor.Extension.Sidebar.default_table(),
            agent_semantic_ui_registry: MingaEditor.Agent.SemanticUI.Registry.default_table(),
            workspace: nil,
            highlighting: %Highlighting{},
            injection_ranges: %{},
            terminal_viewport: Viewport.new(24, 80),
            editing_model: :vim,
            shell_runtime: ShellRuntime.new(ShellRuntime.default_entry(), %ShellState{}),
            theme: MingaEditor.UI.Theme.Fallback.theme(),
            render_correlation: RenderCorrelation.new(),
            message_store: %MessageStore{},
            notifications: NotificationCenter.new(),
            git_remote_op: nil,
            effect_scheduler: nil,
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
            session: %EditorSessionState{},
            buffer_add_context: :open,
            remote: %Remote{},
            resource_pressure: ResourcePressure.new(),
            keystroke_history: KeystrokeHistory.new(),
            git_commit_gen_ref: nil,
            font_size_override: nil,
            # Latest frontend-originated input correlation sequence (ticket #2215).
            # Echoed back on commit_frame so the frontend can resolve a
            # keystroke-to-write latency sample. 0 means "no correlation".
            last_input_seq: 0,
            # Cached native settings snapshot emitted in-frame as the config_state
            # semantic model (#2119). Rebuilt only when a settings option changes
            # (see MingaEditor.refresh_gui_config_state/1), so the render pipeline
            # reads it for free each frame. nil until the first GUI frontend attaches.
            gui_config_state: nil,
            # Latched once the first `ready` runs the one-time startup work, so a
            # renderer reconnect (dev hot-reload) re-runs the idempotent ready path
            # without re-triggering it. See `Startup.ensure_session_started/1`.
            session_started?: false

  @type backend :: :tui | :gui | :native_gui | :headless
  @type rendering_policy :: :enabled | :disabled

  @type shell_state :: MingaEditor.Shell.shell_state()

  @type t :: %__MODULE__{
          backend: backend(),
          rendering: rendering_policy(),
          port_manager: GenServer.server() | nil,
          parser_manager: GenServer.server(),
          renderer: pid() | nil,
          agent_ingest: pid() | nil,
          agent_provider_module: module() | nil,
          agent_provider_opts: keyword(),
          keymap_server: keymap_server(),
          options_server: options_server(),
          events_registry: events_registry(),
          sidebar_registry: MingaEditor.Extension.Sidebar.table(),
          agent_semantic_ui_registry: MingaEditor.Agent.SemanticUI.Registry.table(),
          workspace: SessionState.t(),
          highlighting: Highlighting.t(),
          injection_ranges: %{pid() => [Minga.Language.Highlight.InjectionRange.t()]},
          terminal_viewport: Viewport.t(),
          editing_model: :vim | :cua,
          shell_runtime: ShellRuntime.t(),
          theme: Theme.t(),
          render_correlation: RenderCorrelation.t(),
          message_store: MessageStore.t(),
          notifications: NotificationCenter.t(),
          git_remote_op: git_remote_op(),
          effect_scheduler: GenServer.server() | nil,
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
          buffer_add_context: MingaEditor.Shell.buffer_add_context(),
          remote: Remote.t(),
          resource_pressure: ResourcePressure.t(),
          session: EditorSessionState.t(),
          keystroke_history: KeystrokeHistory.t(),
          git_commit_gen_ref: reference() | nil,
          font_size_override: pos_integer() | nil,
          last_input_seq: non_neg_integer(),
          gui_config_state: Minga.RenderModel.UI.ConfigState.t() | nil,
          session_started?: boolean()
        }

  @doc "Returns whether this editor instance emits rendered frames."
  @spec rendering_enabled?(t()) :: boolean()
  def rendering_enabled?(%__MODULE__{rendering: :enabled}), do: true
  def rendering_enabled?(%__MODULE__{rendering: :disabled}), do: false

  @doc "Returns the cached native settings snapshot emitted in-frame (#2119)."
  @spec gui_config_state(t()) :: Minga.RenderModel.UI.ConfigState.t() | nil
  def gui_config_state(%__MODULE__{gui_config_state: snapshot}), do: snapshot

  @doc "Stores the cached native settings snapshot emitted in-frame (#2119)."
  @spec put_gui_config_state(t(), Minga.RenderModel.UI.ConfigState.t() | nil) :: t()
  def put_gui_config_state(%__MODULE__{} = state, snapshot),
    do: %{state | gui_config_state: snapshot}

  @doc "Returns the active sidebar registry table for this state."
  @spec sidebar_registry(t() | map()) :: MingaEditor.Extension.Sidebar.table()
  def sidebar_registry(state), do: MingaEditor.Extension.Sidebar.table_for(state)

  @doc "Stores the semantic agent UI registry table for this editor state."
  @spec put_agent_semantic_ui_registry(t(), MingaEditor.Agent.SemanticUI.Registry.table()) :: t()
  def put_agent_semantic_ui_registry(%__MODULE__{} = state, table) when is_atom(table) do
    %{state | agent_semantic_ui_registry: table}
  end

  @spec set_renderer(t(), pid() | nil) :: t()
  def set_renderer(%__MODULE__{} = state, pid) when is_pid(pid) or is_nil(pid),
    do: %{state | renderer: pid}

  @doc "Stores the agent stream-ingest coalescer pid (see `MingaEditor.Agent.Ingest`)."
  @spec set_agent_ingest(t(), pid() | nil) :: t()
  def set_agent_ingest(%__MODULE__{} = state, pid) when is_pid(pid) or is_nil(pid),
    do: %{state | agent_ingest: pid}

  @doc "Returns the agent stream-ingest coalescer pid, or nil if not started."
  @spec agent_ingest(t()) :: pid() | nil
  def agent_ingest(%__MODULE__{agent_ingest: pid}), do: pid

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
    |> drop_shell_feature_state_source(source)
  end

  @doc "Drops extension-owned feature state from live and snapshotted workspaces."
  @spec drop_extension_feature_state_sources(t()) :: t()
  def drop_extension_feature_state_sources(%__MODULE__{} = state) do
    state
    |> update_workspace(&SessionState.drop_extension_feature_state_sources/1)
    |> drop_tab_context_extension_feature_state_sources()
    |> drop_shell_extension_feature_state_sources()
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

  @doc "Replaces the live syntax-highlight presentation caches."
  @spec set_highlight(t(), Highlighting.t()) :: t()
  def set_highlight(%__MODULE__{} = state, %Highlighting{} = highlighting) do
    %{state | highlighting: highlighting}
  end

  @doc "Updates the live syntax-highlight presentation caches."
  @spec update_highlight(t(), (Highlighting.t() -> Highlighting.t())) :: t()
  def update_highlight(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    set_highlight(state, fun.(state.highlighting))
  end

  @doc """
  Switches the active editor theme and re-colors existing syntax highlights.

  Sets `state.theme` and rebuilds each buffer's highlight `face_registry`
  from the new theme so tree-sitter colors update immediately. Buffers with
  a syntax override keep their custom palette.
  """
  @spec apply_theme(t(), Theme.t()) :: t()
  def apply_theme(%__MODULE__{} = state, %Theme{} = theme) do
    state
    |> Map.put(:theme, theme)
    |> update_highlight(&Highlighting.retheme_all(&1, theme))
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

  @doc "Sets the desired screen column for vertical movement (Vim's curswant)."
  @spec set_desired_col(t(), non_neg_integer() | nil) :: t()
  def set_desired_col(%__MODULE__{} = state, col) do
    update_editing(state, &VimState.set_desired_col(&1, col))
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

  @doc "Replaces the transient Cmd/Ctrl-hover go-to-definition link range."
  @spec set_cmd_hover_link(t(), cmd_hover_link()) :: t()
  def set_cmd_hover_link(%__MODULE__{} = state, link) do
    update_workspace(state, &SessionState.set_cmd_hover_link(&1, link))
  end

  @doc "Records the pointer cell the Cmd/Ctrl-hover link was last resolved at."
  @spec set_cmd_hover_cell(t(), SessionState.cmd_hover_cell()) :: t()
  def set_cmd_hover_cell(%__MODULE__{} = state, cell) do
    update_workspace(state, &SessionState.set_cmd_hover_cell(&1, cell))
  end

  @doc "Clears the Cmd/Ctrl-hover link preview and its dedup cell."
  @spec clear_cmd_hover_link(t()) :: t()
  def clear_cmd_hover_link(%__MODULE__{} = state) do
    update_workspace(state, &SessionState.clear_cmd_hover_link/1)
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

  @doc "Replaces the live parser injection ranges map."
  @spec set_injection_ranges(t(), %{pid() => [Minga.Language.Highlight.InjectionRange.t()]}) ::
          t()
  def set_injection_ranges(%__MODULE__{} = state, ranges) when is_map(ranges) do
    %{state | injection_ranges: ranges}
  end

  @doc "Updates the live parser injection ranges map."
  @spec update_injection_ranges(t(), (%{pid() => [Minga.Language.Highlight.InjectionRange.t()]} ->
                                        %{pid() => [Minga.Language.Highlight.InjectionRange.t()]})) ::
          t()
  def update_injection_ranges(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    set_injection_ranges(state, fun.(state.injection_ranges))
  end

  @doc "Drops all parser-derived presentation caches for a buffer."
  @spec drop_parser_presentation(t(), pid()) :: t()
  def drop_parser_presentation(%__MODULE__{} = state, buffer_pid) when is_pid(buffer_pid) do
    %{
      state
      | highlighting: Highlighting.remove_buffer(state.highlighting, buffer_pid),
        injection_ranges: Map.delete(state.injection_ranges, buffer_pid)
    }
  end

  # ── Render pipeline write-back ─────────────────────────────────────────────

  @type render_receipt_result ::
          :applied | {:stale, RenderCorrelation.freshness_reason() | :shell_identity}

  @doc "Returns whether the Editor already owns a scheduled render timer."
  @spec render_scheduled?(t()) :: boolean()
  def render_scheduled?(%__MODULE__{render_correlation: correlation}),
    do: RenderCorrelation.scheduled?(correlation)

  @doc "Stores one externally created render timer in the correlation owner."
  @spec schedule_render_timer(t(), reference()) :: t()
  def schedule_render_timer(%__MODULE__{} = state, timer) when is_reference(timer) do
    {:scheduled, correlation} = RenderCorrelation.schedule(state.render_correlation, timer)
    %{state | render_correlation: correlation}
  end

  @doc "Clears the active render timer after delivery or synchronous rendering."
  @spec clear_render_timer(t()) :: t()
  def clear_render_timer(%__MODULE__{} = state) do
    %{state | render_correlation: RenderCorrelation.clear_timer(state.render_correlation)}
  end

  @doc "Marks the next completed frame as a required keyframe."
  @spec request_render_keyframe(t()) :: t()
  def request_render_keyframe(%__MODULE__{} = state) do
    %{state | render_correlation: RenderCorrelation.request_keyframe(state.render_correlation)}
  end

  @doc "Marks a newly ready frontend for correlated keyframe recovery."
  @spec frontend_render_ready(t()) :: t()
  def frontend_render_ready(%__MODULE__{} = state) do
    %{state | render_correlation: RenderCorrelation.frontend_ready(state.render_correlation)}
  end

  @doc "Advances editor-owned correlation before submitting a render intent."
  @spec submit_render_intent(t()) :: {t(), pos_integer()}
  def submit_render_intent(%__MODULE__{} = state) do
    {correlation, revision} = RenderCorrelation.submit(state.render_correlation)
    {%{state | render_correlation: correlation}, revision}
  end

  @doc "Atomically integrates a synchronous focused renderer receipt."
  @spec integrate_synchronous_renderer_receipt(t(), MingaEditor.Renderer.RenderReceipt.t()) :: t()
  def integrate_synchronous_renderer_receipt(
        %__MODULE__{} = state,
        %MingaEditor.Renderer.RenderReceipt{} = receipt
      ) do
    correlation =
      RenderCorrelation.accept_synchronous_receipt(
        state.render_correlation,
        receipt.intent_revision,
        receipt.frame_seq,
        receipt.keyframe?
      )

    commit_renderer_receipt(state, receipt, correlation)
  end

  @doc "Atomically integrates a fresh asynchronous receipt or returns its stale reason."
  @spec integrate_renderer_receipt(t(), MingaEditor.Renderer.RenderReceipt.t()) ::
          {t(), render_receipt_result()}
  def integrate_renderer_receipt(
        %__MODULE__{} = state,
        %MingaEditor.Renderer.RenderReceipt{} = receipt
      ) do
    case RenderCorrelation.classify_receipt(
           state.render_correlation,
           receipt.intent_revision,
           receipt.frame_seq
         ) do
      {:stale, reason} ->
        {state, {:stale, reason}}

      {:fresh, revision} ->
        receipt = MingaEditor.Renderer.RenderReceipt.correlate(receipt, revision)
        integrate_fresh_renderer_receipt(state, receipt)
    end
  end

  @spec integrate_fresh_renderer_receipt(t(), MingaEditor.Renderer.RenderReceipt.t()) ::
          {t(), render_receipt_result()}
  defp integrate_fresh_renderer_receipt(state, receipt) do
    if renderer_receipt_shell_current?(state, receipt) do
      correlation =
        RenderCorrelation.accept_receipt(
          state.render_correlation,
          receipt.intent_revision,
          receipt.frame_seq,
          receipt.keyframe?
        )

      {commit_renderer_receipt(state, receipt, correlation), :applied}
    else
      {state, {:stale, :shell_identity}}
    end
  end

  @spec commit_renderer_receipt(
          t(),
          MingaEditor.Renderer.RenderReceipt.t(),
          RenderCorrelation.t()
        ) :: t()
  defp commit_renderer_receipt(state, receipt, correlation) do
    shell_runtime = merge_renderer_receipt(state.shell_runtime, receipt)
    workspace = apply_window_observations(state.workspace, receipt.window_observations)

    %{
      state
      | layout: receipt.layout,
        focus_tree: receipt.focus_tree,
        shell_runtime: shell_runtime,
        workspace: workspace,
        render_correlation: correlation
    }
  end

  @spec apply_window_observations(SessionState.t(), map()) :: SessionState.t()
  defp apply_window_observations(%SessionState{} = workspace, observations) do
    Enum.reduce(observations, workspace, fn
      {id,
       %WindowObservation{
         buffer: buffer,
         buffer_version: version,
         viewport: %Viewport{} = viewport
       }},
      acc ->
        SessionState.update_window(acc, id, fn window ->
          observe_renderer_window(window, buffer, viewport, version)
        end)
    end)
  end

  @spec observe_renderer_window(Window.t(), pid(), Viewport.t(), non_neg_integer()) :: Window.t()
  defp observe_renderer_window(
         %Window{buffer: buffer, render_cache: %{buffer_version: current_version}} = window,
         buffer,
         viewport,
         version
       )
       when current_version <= version,
       do: Window.observe_render(window, viewport, version)

  defp observe_renderer_window(window, _buffer, _viewport, _version), do: window

  @spec renderer_receipt_shell_current?(t(), MingaEditor.Renderer.RenderReceipt.t()) :: boolean()
  defp renderer_receipt_shell_current?(%__MODULE__{} = state, receipt) do
    case receipt.shell_identity do
      %ShellIdentity{} = identity ->
        receipt.shell_id == ShellRuntime.id(state.shell_runtime) and
          ShellRuntime.matches_identity?(state.shell_runtime, identity)

      _missing_or_invalid ->
        false
    end
  end

  @spec merge_renderer_receipt(ShellRuntime.t(), MingaEditor.Renderer.RenderReceipt.t()) ::
          ShellRuntime.t()
  defp merge_renderer_receipt(runtime, receipt) do
    case receipt.shell_identity do
      %ShellIdentity{} = identity ->
        ShellRuntime.merge_renderer_observation(runtime, receipt.shell_id, identity, %{
          modeline_click_regions: receipt.modeline_click_regions,
          tab_bar_click_regions: receipt.tab_bar_click_regions
        })

      _missing_or_invalid ->
        runtime
    end
  end

  @doc "Installs a pure shell Runtime transition into the Editor root."
  @spec apply_shell_runtime_transition(t(), ShellRuntime.t()) :: t()
  def apply_shell_runtime_transition(%__MODULE__{} = state, %ShellRuntime{} = runtime) do
    %{state | shell_runtime: runtime}
  end

  @doc "Invalidates shell-owned layout values after an activation transition."
  @spec reset_shell_layout(t()) :: t()
  def reset_shell_layout(%__MODULE__{} = state), do: %{state | layout: nil, focus_tree: nil}

  # ── Traditional shell forwarding helpers ────────────────────────────────
  # These transitional helpers move in later shell-state work.
  # The resolved Traditional entry guards extension state.

  @spec update_traditional_shell_state(t(), (shell_state() -> shell_state())) :: t()
  defp update_traditional_shell_state(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    runtime = ShellRuntime.update_traditional_state(state.shell_runtime, fun)
    apply_shell_runtime_transition(state, runtime)
  end

  @spec status_msg(t()) :: String.t() | nil
  def status_msg(%{
        shell_runtime: %ShellRuntime{
          entry: %{module: MingaEditor.Shell.Traditional},
          state: shell_state
        }
      }),
      do: ShellState.status_msg(shell_state)

  def status_msg(_state), do: nil
  @spec set_status(t(), String.t()) :: t()
  def set_status(s, msg), do: update_traditional_shell_state(s, &ShellState.set_status(&1, msg))
  @spec clear_status(t()) :: t()
  def clear_status(s), do: update_traditional_shell_state(s, &ShellState.clear_status/1)

  @spec set_suppress_tool_prompts(t(), boolean()) :: t()
  def set_suppress_tool_prompts(s, suppress?) when is_boolean(suppress?) do
    update_traditional_shell_state(s, &ShellState.set_suppress_tool_prompts(&1, suppress?))
  end

  @spec nav_flash(t()) :: MingaEditor.NavFlash.t() | nil
  def nav_flash(%{shell_runtime: %ShellRuntime{state: ss}}), do: ShellState.nav_flash(ss)
  @spec set_nav_flash(t(), MingaEditor.NavFlash.t()) :: t()
  def set_nav_flash(s, flash),
    do: update_traditional_shell_state(s, &ShellState.set_nav_flash(&1, flash))

  @spec cancel_nav_flash(t()) :: t()
  def cancel_nav_flash(s), do: update_traditional_shell_state(s, &ShellState.cancel_nav_flash/1)

  @spec yank_flash(t()) :: MingaEditor.YankFlash.t() | nil
  def yank_flash(%{shell_runtime: %ShellRuntime{state: ss}}), do: ShellState.yank_flash(ss)
  @spec set_yank_flash(t(), MingaEditor.YankFlash.t()) :: t()
  def set_yank_flash(s, flash),
    do: update_traditional_shell_state(s, &ShellState.set_yank_flash(&1, flash))

  @spec cancel_yank_flash(t()) :: t()
  def cancel_yank_flash(s), do: update_traditional_shell_state(s, &ShellState.cancel_yank_flash/1)

  @spec hover_popup(t()) :: MingaEditor.HoverPopup.t() | nil
  def hover_popup(%{shell_runtime: %ShellRuntime{state: ss}}), do: ShellState.hover_popup(ss)
  @spec set_hover_popup(t(), MingaEditor.HoverPopup.t()) :: t()
  def set_hover_popup(s, popup),
    do: update_traditional_shell_state(s, &ShellState.set_hover_popup(&1, popup))

  @spec dismiss_hover_popup(t()) :: t()
  def dismiss_hover_popup(s),
    do: update_traditional_shell_state(s, &ShellState.dismiss_hover_popup/1)

  @spec whichkey(t()) :: WhichKey.t()
  def whichkey(%{shell_runtime: %ShellRuntime{state: ss}}), do: ShellState.whichkey(ss)
  @spec set_whichkey(t(), WhichKey.t()) :: t()
  def set_whichkey(s, wk), do: update_traditional_shell_state(s, &ShellState.set_whichkey(&1, wk))

  @spec bottom_panel(t()) :: BottomPanel.t()
  def bottom_panel(%{shell_runtime: %ShellRuntime{state: ss}}), do: ShellState.bottom_panel(ss)
  @spec set_bottom_panel(t(), BottomPanel.t()) :: t()
  def set_bottom_panel(s, panel),
    do: update_traditional_shell_state(s, &ShellState.set_bottom_panel(&1, panel))

  @spec git_status_panel(t()) :: ShellState.git_status_panel() | nil
  def git_status_panel(%{shell_runtime: %ShellRuntime{state: ss}}),
    do: ShellState.git_status_panel(ss)

  @spec set_git_status_tui_state(t(), term()) :: t()
  def set_git_status_tui_state(state, tui_state) do
    update_traditional_shell_state(
      state,
      &ShellState.set_git_status_tui_state(&1, tui_state)
    )
  end

  @spec set_git_status_panel(t(), ShellState.git_status_panel() | nil) :: t()
  def set_git_status_panel(s, nil) do
    sync_git_status_sidebar(s, nil)
    update_traditional_shell_state(s, &ShellState.set_git_status_panel(&1, nil))
  end

  def set_git_status_panel(s, data) do
    panel = GitStatusPanel.new(data)
    sync_git_status_sidebar(s, panel)
    update_traditional_shell_state(s, &ShellState.set_git_status_panel(&1, panel))
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
    update_traditional_shell_state(s, &ShellState.close_git_status_panel/1)
  end

  @spec sidebar_active_id(t()) :: String.t() | nil
  def sidebar_active_id(%{
        shell_runtime: %ShellRuntime{
          entry: %{module: MingaEditor.Shell.Traditional},
          state: %{sidebar_active_id: id}
        }
      }),
      do: id

  def sidebar_active_id(_state), do: nil

  @spec set_sidebar_active_id(t(), String.t() | nil) :: t()
  def set_sidebar_active_id(s, id) when is_binary(id) or is_nil(id) do
    sync_active_sidebar(s, id)

    update_traditional_shell_state(s, fn ss ->
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
  def observatory_visible?(%{shell_runtime: %ShellRuntime{state: ss}}),
    do: ShellState.observatory_visible?(ss)

  @spec open_observatory(t(), {reference(), reference()} | nil) :: t()
  def open_observatory(s, timer) do
    sync_observatory_sidebar(s, true)
    update_traditional_shell_state(s, &ShellState.open_observatory(&1, timer))
  end

  @spec close_observatory(t()) :: t()
  def close_observatory(s) do
    sync_observatory_sidebar(s, false)
    update_traditional_shell_state(s, &ShellState.close_observatory/1)
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
    do: update_traditional_shell_state(s, &ShellState.set_observatory_data(&1, data))

  @spec set_observatory_timer(t(), {reference(), reference()} | nil) :: t()
  def set_observatory_timer(s, timer),
    do: update_traditional_shell_state(s, &ShellState.set_observatory_timer(&1, timer))

  @spec set_observatory_inspection(t(), Observatory.Inspection.t() | nil) :: t()
  def set_observatory_inspection(s, inspection),
    do: update_traditional_shell_state(s, &ShellState.set_observatory_inspection(&1, inspection))

  @spec set_git_toast(t(), ShellState.git_toast()) :: t()
  def set_git_toast(s, toast),
    do: update_traditional_shell_state(s, &ShellState.set_git_toast(&1, toast))

  @spec clear_git_toast(t()) :: t()
  def clear_git_toast(s), do: update_traditional_shell_state(s, &ShellState.clear_git_toast/1)

  @spec clear_git_toast(t(), reference()) :: t()
  def clear_git_toast(s, dismiss_ref),
    do: update_traditional_shell_state(s, &ShellState.clear_git_toast(&1, dismiss_ref))

  @spec tab_bar(t()) :: TabBar.t() | nil
  def tab_bar(%{shell_runtime: %ShellRuntime{state: ss}}), do: ShellState.tab_bar(ss)
  @spec set_tab_bar(t(), TabBar.t() | nil) :: t()
  def set_tab_bar(s, tb), do: update_traditional_shell_state(s, &ShellState.set_tab_bar(&1, tb))

  @spec drop_tab_context_feature_state_source(t(), FeatureState.source()) :: t()
  defp drop_tab_context_feature_state_source(
         %__MODULE__{shell_runtime: %ShellRuntime{state: %ShellState{}}} = state,
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
         %__MODULE__{shell_runtime: %ShellRuntime{state: %ShellState{}}} = state
       ) do
    case tab_bar(state) do
      %TabBar{} = tb -> set_tab_bar(state, TabBar.drop_extension_feature_state_sources(tb))
      _other -> state
    end
  end

  defp drop_tab_context_extension_feature_state_sources(%__MODULE__{} = state), do: state

  @spec drop_shell_feature_state_source(t(), FeatureState.source()) :: t()
  defp drop_shell_feature_state_source(%__MODULE__{} = state, source) do
    runtime =
      ShellRuntime.drop_feature_state_source(
        state.shell_runtime,
        MingaEditor.Shell.Workflow.resolved_entries(),
        source
      )

    apply_shell_runtime_transition(state, runtime)
  end

  @spec drop_shell_extension_feature_state_sources(t()) :: t()
  defp drop_shell_extension_feature_state_sources(%__MODULE__{} = state) do
    runtime =
      ShellRuntime.drop_extension_feature_state_sources(
        state.shell_runtime,
        MingaEditor.Shell.Workflow.resolved_entries()
      )

    apply_shell_runtime_transition(state, runtime)
  end

  @spec agent(t()) :: AgentState.t()
  def agent(%{shell_runtime: %ShellRuntime{state: ss}}), do: ShellState.agent(ss)
  @spec set_agent(t(), AgentState.t()) :: t()
  def set_agent(s, agent), do: update_traditional_shell_state(s, &ShellState.set_agent(&1, agent))

  @spec modal(t()) :: MingaEditor.State.ModalOverlay.t()
  def modal(%{shell_runtime: %ShellRuntime{state: ss}}), do: ShellState.modal(ss)
  @spec set_modal(t(), MingaEditor.State.ModalOverlay.t()) :: t()
  def set_modal(s, modal), do: update_traditional_shell_state(s, &ShellState.set_modal(&1, modal))

  @spec inline_asks(t()) :: MingaEditor.State.InlineAsk.store()
  def inline_asks(%{shell_runtime: %ShellRuntime{state: ss}}), do: ShellState.inline_asks(ss)
  @spec set_inline_asks(t(), MingaEditor.State.InlineAsk.store()) :: t()
  def set_inline_asks(s, asks),
    do: update_traditional_shell_state(s, &ShellState.set_inline_asks(&1, asks))

  @spec inline_edits(t()) :: MingaEditor.State.InlineEdit.store()
  def inline_edits(%{shell_runtime: %ShellRuntime{state: ss}}), do: ShellState.inline_edits(ss)
  @spec set_inline_edits(t(), MingaEditor.State.InlineEdit.store()) :: t()
  def set_inline_edits(s, edits),
    do: update_traditional_shell_state(s, &ShellState.set_inline_edits(&1, edits))

  @doc "Replaces Traditional signature-help presentation state."
  @spec set_signature_help(t(), MingaEditor.SignatureHelp.t() | nil) :: t()
  def set_signature_help(state, signature_help) do
    update_traditional_shell_state(state, &ShellState.set_signature_help(&1, signature_help))
  end

  @doc "Replaces the Traditional delayed warning-popup timer."
  @spec set_warning_popup_timer(t(), reference() | nil) :: t()
  def set_warning_popup_timer(state, timer) do
    update_traditional_shell_state(state, &ShellState.set_warning_popup_timer(&1, timer))
  end

  @doc "Replaces the Traditional tool-install prompt queue."
  @spec set_tool_prompt_queue(t(), [atom()]) :: t()
  def set_tool_prompt_queue(state, queue) do
    update_traditional_shell_state(state, &ShellState.set_tool_prompt_queue(&1, queue))
  end

  @doc "Replaces Traditional tool-prompt decisions and pending queue atomically."
  @spec set_tool_prompt_state(t(), [atom()], MapSet.t(atom())) :: t()
  def set_tool_prompt_state(state, queue, declined) do
    update_traditional_shell_state(
      state,
      &ShellState.set_tool_prompt_state(&1, queue, declined)
    )
  end

  @doc "Sets whether the Traditional CUA space-leader sequence is pending."
  @spec set_space_leader_pending(t(), boolean()) :: t()
  def set_space_leader_pending(state, value) do
    update_traditional_shell_state(state, &ShellState.set_space_leader_pending(&1, value))
  end

  @doc "Replaces the Traditional CUA space-leader timer."
  @spec set_space_leader_timer(t(), reference() | nil) :: t()
  def set_space_leader_timer(state, timer) do
    update_traditional_shell_state(state, &ShellState.set_space_leader_timer(&1, timer))
  end

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

    MingaEditor.HugeFile.guard(file_path, options_server, fn ->
      DynamicSupervisor.start_child(
        Minga.Buffer.Supervisor,
        {Minga.Buffer, file_path: file_path, options_server: options_server}
      )
    end)
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
    state = state |> do_remove_dead_buffer(pid) |> MingaEditor.Shell.Workflow.ensure_available()

    {runtime, workspace, shell_effects} =
      ShellRuntime.route_buffer_died(state.shell_runtime, state.workspace, pid)

    state =
      state
      |> apply_shell_runtime_transition(runtime)
      |> set_workspace(workspace)

    {state, shell_effects}
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
    state = drop_parser_presentation(state, pid)
    monitors = Map.delete(monitors, pid)
    new_bs = Buffers.remove(bs, pid)

    state = %{
      update_workspace(state, &SessionState.set_buffers(&1, new_bs))
      | buffer_monitors: monitors
    }

    ws = state.workspace

    state =
      if ws.agent_ui.panel.prompt_buffer == pid do
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
      %{state | message_store: MessageStore.reset_sent_cursor(state.message_store)}
    end)
    |> frontend_render_ready()
  end

  @doc """
  Returns the terminal-level viewport: total screen rows/cols reported by
  the frontend on resize. Used for screen-spanning chrome (picker,
  popups, completion menu placement) and for layout
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
  viewport (the no-window fallback case). Use this for scroll commands
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
  (the no-window fallback case has no per-window viewport to write).

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
  Marks the active window's next rendered frame as an authoritative BEAM scroll
  that must discard any frontend-held local offset (#2652).

  Called at dispatch for the always-authoritative viewport commands (the
  `MingaEditor.Commands` `@authoritative_scroll_commands` set and `goto_line`)
  and from the success branches of failable jumps (search hits, mark jumps,
  bracket match, LSP goto) — see that MapSet's comment for the policy. No-op
  when no window is active. See `MingaEditor.Window.mark_authoritative_scroll/1`
  for the marker lifecycle.
  """
  @spec mark_authoritative_scroll(t()) :: t()
  def mark_authoritative_scroll(%__MODULE__{} = state) do
    case active_window_struct(state) do
      nil -> state
      %Window{id: win_id} -> update_window(state, win_id, &Window.mark_authoritative_scroll/1)
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
        total_lines = Enum.count(state.workspace.agent_ui.panel.cached_line_index)
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

  @doc "Returns the set of buffer pids known to the live workspace and tab snapshots."
  @spec known_open_buffer_pids(t()) :: [pid()]
  def known_open_buffer_pids(%__MODULE__{} = state) do
    (state.workspace.buffers.list ++ tab_context_buffer_pids(tab_bar(state)))
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
    tab_bar = tab_bar(state)

    case {matching_file_tabs(tab_bar, buffer_pid), buffer_file_ref(buffer_pid, state.workspace)} do
      {[], _} ->
        state

      {_, nil} ->
        state

      {tabs, %FileRef{} = file_ref} ->
        set_tab_bar(state, rebind_tabs_to_file_ref(tab_bar, tabs, file_ref))
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
      |> MingaEditor.Shell.Workflow.ensure_available()

    {runtime, workspace, shell_effects} =
      ShellRuntime.route_buffer_added(
        state.shell_runtime,
        prev_workspace,
        state.workspace,
        pid,
        context
      )

    state =
      state
      |> apply_shell_runtime_transition(runtime)
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
  Enters the zero-buffers launchpad (#2689).

  Removes all file tabs from the tab bar (agent tabs stay), clears the
  buffer list, and switches the active window to the empty-state surface.
  `MingaEditor.Session.State.activate_buffer/2` performs the reverse transition when a buffer becomes active.
  """
  @spec enter_empty_state(t()) :: t()
  def enter_empty_state(%__MODULE__{} = state) do
    launchpad_opts = EditorSessionState.session_opts(state.session)

    state
    |> clear_file_tabs()
    |> update_workspace(&SessionState.enter_empty_state(&1, launchpad_opts))
  end

  @spec clear_file_tabs(t()) :: t()
  defp clear_file_tabs(
         %__MODULE__{
           shell_runtime: %ShellRuntime{
             entry: %{module: MingaEditor.Shell.Traditional},
             state: %{tab_bar: %TabBar{} = tb}
           }
         } = state
       ) do
    set_tab_bar(state, TabBar.remove_file_tabs(tb))
  end

  defp clear_file_tabs(%__MODULE__{} = state), do: state

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
    |> put_non_default_agent_ui(ws.agent_ui)
  end

  @spec put_non_default_agent_ui(Tab.context(), UIState.t()) :: Tab.context()
  defp put_non_default_agent_ui(context, %UIState{} = agent_ui) do
    if agent_ui == UIState.new() do
      context
    else
      TabContext.put_fields(context, agent_ui: agent_ui)
    end
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
    |> sync_file_tab_active_window_buffer()
    |> sync_agent_ui_from_active_workspace()
  end

  @spec sync_file_tab_active_window_buffer(t()) :: t()
  defp sync_file_tab_active_window_buffer(%__MODULE__{} = state) do
    case tab_bar(state) do
      %TabBar{} = tb ->
        sync_file_tab_active_window_buffer(state, TabBar.active(tb))

      nil ->
        state
    end
  end

  @spec sync_file_tab_active_window_buffer(t(), Tab.t() | nil) :: t()
  defp sync_file_tab_active_window_buffer(%__MODULE__{} = state, %Tab{kind: :file}) do
    workspace = SessionState.activate_buffer(state.workspace, state.workspace.buffers)
    set_workspace(state, workspace)
  end

  defp sync_file_tab_active_window_buffer(%__MODULE__{} = state, _tab), do: state

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
    rows = max(state.terminal_viewport.rows, 1)
    cols = max(state.terminal_viewport.cols, 1)
    windows = build_agent_chat_windows(rows, cols)
    build_agent_tab_defaults(state, windows)
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
  populated. Accepts a pre-built `Windows` struct for the agent chat window.
  """
  @spec build_agent_tab_defaults(t(), Windows.t()) :: Tab.context()
  def build_agent_tab_defaults(state, windows) do
    TabContext.from_workspace_map(%{
      keymap_scope: :agent,
      buffers: %Buffers{
        active: nil,
        list: [],
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

  Returns a `Tab.context()` carrying a single semantic agent-chat window sized to the current viewport, with the agent keymap scope. The caller restores it via `restore_tab_context/2` and then activates the relevant shell-owned session pid against the window content.
  """
  @spec build_agent_workspace_context(t(), pid() | nil) :: Tab.context()
  def build_agent_workspace_context(%__MODULE__{} = state, _session_pid) do
    rows = max(state.workspace.viewport.rows, 1)
    cols = max(state.workspace.viewport.cols, 1)

    windows = build_agent_chat_windows(rows, cols)
    build_agent_tab_defaults(state, windows)
  end

  @spec build_agent_chat_windows(pos_integer(), pos_integer()) :: Windows.t()
  defp build_agent_chat_windows(rows, cols) do
    win_id = 1
    agent_window = Window.new_agent_chat(win_id, rows, cols)

    %Windows{
      tree: WindowTree.new(win_id),
      map: %{win_id => agent_window},
      active: win_id,
      next_id: win_id + 1
    }
  end

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
    state = MingaEditor.Shell.Workflow.ensure_available(state)

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
        %__MODULE__{
          shell_runtime: %ShellRuntime{
            entry: %{module: MingaEditor.Shell.Traditional},
            state: %{tab_bar: %TabBar{} = tab_bar}
          }
        } = state
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
        state = MingaEditor.Remote.EventReplay.replay_active(state, events)

        tb =
          TabBar.update_workspace(
            tab_bar(state),
            workspace_id,
            &WorkspaceModel.clear_pending_catchup_events/1
          )

        set_tab_bar(state, tb)

      _ ->
        state
    end
  end

  @spec active_tab(t()) :: Tab.t() | nil
  def active_tab(%__MODULE__{} = state) do
    state = ShellWorkflow.ensure_available(state)
    ShellRuntime.active_tab(state.shell_runtime)
  end

  @spec find_tab_by_buffer(t(), pid()) :: Tab.t() | nil
  def find_tab_by_buffer(%__MODULE__{} = state, pid) do
    state = ShellWorkflow.ensure_available(state)
    ShellRuntime.find_tab_by_buffer(state.shell_runtime, pid)
  end

  @spec active_tab_kind(t()) :: Tab.kind()
  def active_tab_kind(%__MODULE__{} = state) do
    state = ShellWorkflow.ensure_available(state)
    ShellRuntime.active_tab_kind(state.shell_runtime)
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
    state = ShellWorkflow.ensure_available(state)
    runtime = ShellRuntime.set_tab_session(state.shell_runtime, tab_id, session_pid)
    apply_shell_runtime_transition(state, runtime)
  end

  @doc """
  Rebuilds the agent rendering cache from the Session process when
  switching to an agent tab. The Session is the source of truth for
  status, pending approval, and error; the cache lives on
  `state.shell_runtime.state.agent` and is repopulated from the Tab's session
  pid on every tab switch.

  The session pid itself lives on `Tab.session` (see `set_tab_session/3`),
  not on the agent cache. `AgentAccess.session/1` reads it through the
  shell behaviour.
  """
  @spec rebuild_agent_from_session(t(), Tab.t()) :: t()
  def rebuild_agent_from_session(state, %Tab{kind: :agent, session: session_pid})
      when is_pid(session_pid) do
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
  def skip_tool_prompt?(
        %__MODULE__{
          shell_runtime: %ShellRuntime{
            entry: %{module: MingaEditor.Shell.Traditional},
            state: ss
          }
        },
        tool_name
      ) do
    ShellState.skip_tool_prompt?(ss, tool_name)
  end

  def skip_tool_prompt?(%__MODULE__{}, _tool_name), do: true

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
    |> sync_active_agent_transcript()
  end

  defp apply_buffer_effect(state, {:rebuild_agent_session, tab}),
    do: rebuild_agent_from_session(state, tab)

  @spec sync_active_agent_transcript(t()) :: t()
  defp sync_active_agent_transcript(state) do
    session = AgentAccess.session(state)

    if is_pid(session) do
      MingaEditor.AgentLifecycle.sync_transcript(state)
    else
      state
    end
  end
end
