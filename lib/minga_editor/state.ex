defmodule MingaEditor.State do
  @moduledoc """
  Narrow root state for the single Editor GenServer.

  The root stores 16 cohesive owner values. Per-tab editing context lives in `workspace`; active shell identity and stashed implementation state live in `shell_runtime`; focused global values own frontend, render, parser, agent connection, interaction, extension surfaces, buffer lifecycle, Git, session, feedback, LSP, remote, and appearance state. `effect_scheduler` is the process handle for bounded resource work.

  Leaf and aggregate transitions belong to those owner modules. This module retains only atomic operations that coordinate multiple top-level owners, including renderer receipt integration, theme and parser synchronization, frontend render reset, buffer lifecycle changes, tab snapshot and restore, and extension feature cleanup. It is not a forwarding facade for leaf setters or generic mappers.

  State decomposition does not add processes. Ordered input and every root transition still pass through the one `MingaEditor` mailbox. See `docs/adr/0002-editor-state-transitions-have-explicit-owners.md` for the complete ownership ledger.
  """

  alias MingaEditor.Agent.UIState
  alias MingaEditor.FeatureState

  alias MingaEditor.BottomPanel
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentConnection
  alias MingaEditor.State.Appearance
  alias MingaEditor.State.BufferLifecycle
  alias MingaEditor.State.ExtensionSurfaces
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.Frontend, as: FrontendState
  alias MingaEditor.State.Git, as: GitState
  alias MingaEditor.State.Interaction
  alias MingaEditor.State.Parser, as: ParserState
  alias MingaEditor.State.Render, as: RenderState
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
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.Remote
  alias MingaEditor.State.RenderCorrelation
  alias MingaEditor.State.Search
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Renderer.WindowObservation
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.WindowTree
  alias Minga.Project.FileRef
  alias Minga.Project.FileTree

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

  alias MingaEditor.Shell.Traditional.ClickRegions
  alias MingaEditor.Shell.Traditional.State, as: ShellState

  @enforce_keys [:workspace]
  defstruct workspace: nil,
            shell_runtime: ShellRuntime.new(ShellRuntime.default_entry(), %ShellState{}),
            frontend: %FrontendState{},
            render: %RenderState{},
            parser: %ParserState{},
            agent_connection: %AgentConnection{},
            interaction: %Interaction{},
            extension_surfaces: %ExtensionSurfaces{},
            buffer_lifecycle: %BufferLifecycle{},
            git: %GitState{},
            session: %EditorSessionState{},
            effect_scheduler: nil,
            feedback: %Feedback{},
            lsp: %LSPState{},
            remote: %Remote{},
            appearance: %Appearance{}

  @type backend :: FrontendState.backend()
  @type rendering_policy :: FrontendState.rendering_policy()

  @type shell_state :: MingaEditor.Shell.shell_state()

  @typedoc "Focused result from a pure buffer-registration transition."
  @type buffer_registration_result :: :already_registered | {:monitor, pid()}

  @typedoc "Focused result from a pure tab switch transition."
  @type tab_switch_result :: :unchanged | {:switched, Tab.t()}

  @type t :: %__MODULE__{
          workspace: SessionState.t(),
          shell_runtime: ShellRuntime.t(),
          frontend: FrontendState.t(),
          render: RenderState.t(),
          parser: ParserState.t(),
          agent_connection: AgentConnection.t(),
          interaction: Interaction.t(),
          extension_surfaces: ExtensionSurfaces.t(),
          buffer_lifecycle: BufferLifecycle.t(),
          git: GitState.t(),
          session: EditorSessionState.t(),
          effect_scheduler: GenServer.server() | nil,
          feedback: Feedback.t(),
          lsp: LSPState.t(),
          remote: Remote.t(),
          appearance: Appearance.t()
        }

  # ── Workspace helpers ──────────────────────────────────────────────────────

  @doc "Drops all feature state owned by a source from live and snapshotted workspaces."
  @spec drop_feature_state_source(t(), FeatureState.source()) :: t()
  def drop_feature_state_source(%__MODULE__{} = state, source) do
    state = %{state | workspace: SessionState.drop_feature_state_source(state.workspace, source)}

    state
    |> drop_tab_context_feature_state_source(source)
    |> drop_shell_feature_state_source(source)
  end

  @doc "Drops extension-owned feature state from live and snapshotted workspaces."
  @spec drop_extension_feature_state_sources(t()) :: t()
  def drop_extension_feature_state_sources(%__MODULE__{} = state) do
    state = %{
      state
      | workspace: SessionState.drop_extension_feature_state_sources(state.workspace)
    }

    state
    |> drop_tab_context_extension_feature_state_sources()
    |> drop_shell_extension_feature_state_sources()
  end

  @doc """
  Switches the active editor theme and re-colors existing syntax highlights.

  The root owns this transition because appearance selection and parser-derived
  face registries must change atomically for the next rendered frame.
  """
  @spec apply_theme(t(), Theme.t()) :: t()
  def apply_theme(%__MODULE__{} = state, %Theme{} = theme) do
    appearance = Appearance.select_theme(state.appearance, theme)
    highlighting = Highlighting.retheme_all(state.parser.highlighting, theme)
    parser = ParserState.accept_highlighting(state.parser, highlighting)
    %{state | appearance: appearance, parser: parser}
  end

  # ── Render pipeline write-back ─────────────────────────────────────────────

  @type render_receipt_result ::
          :applied | {:stale, RenderCorrelation.freshness_reason() | :shell_identity}

  @doc "Atomically integrates a synchronous focused renderer receipt."
  @spec integrate_synchronous_renderer_receipt(t(), MingaEditor.Renderer.RenderReceipt.t()) :: t()
  def integrate_synchronous_renderer_receipt(
        %__MODULE__{} = state,
        %MingaEditor.Renderer.RenderReceipt{} = receipt
      ) do
    correlation =
      RenderCorrelation.accept_synchronous_receipt(
        state.render.render_correlation,
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
           state.render.render_correlation,
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
          state.render.render_correlation,
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

    render =
      state.render
      |> RenderState.accept_correlation(correlation)
      |> RenderState.cache_layout(receipt.layout, receipt.focus_tree)

    %{state | render: render, shell_runtime: shell_runtime, workspace: workspace}
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
        SessionState.observe_window(acc, id, buffer, viewport, version)
    end)
  end

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
    case {receipt.shell_identity, receipt.click_regions} do
      {%ShellIdentity{} = identity, %ClickRegions{} = regions} ->
        if receipt.shell_id == ShellRuntime.id(runtime) and
             ShellRuntime.matches_identity?(runtime, identity) do
          shell_state =
            runtime |> ShellRuntime.state() |> ShellState.install_click_regions(regions)

          ShellRuntime.install_traditional_state(runtime, shell_state)
        else
          runtime
        end

      _missing_or_invalid ->
        runtime
    end
  end

  @spec drop_tab_context_feature_state_source(t(), FeatureState.source()) :: t()
  defp drop_tab_context_feature_state_source(
         %__MODULE__{shell_runtime: %ShellRuntime{state: %ShellState{}}} = state,
         source
       ) do
    case tab_bar(state) do
      %TabBar{} = tb ->
        %{
          state
          | shell_runtime:
              ShellRuntime.install_traditional_state(
                state.shell_runtime,
                ShellState.set_tab_bar(
                  ShellRuntime.state(state.shell_runtime),
                  TabBar.drop_feature_state_source(tb, source)
                )
              )
        }

      _other ->
        state
    end
  end

  defp drop_tab_context_feature_state_source(%__MODULE__{} = state, _source), do: state

  @spec drop_tab_context_extension_feature_state_sources(t()) :: t()
  defp drop_tab_context_extension_feature_state_sources(
         %__MODULE__{shell_runtime: %ShellRuntime{state: %ShellState{}}} = state
       ) do
    case tab_bar(state) do
      %TabBar{} = tb ->
        %{
          state
          | shell_runtime:
              ShellRuntime.install_traditional_state(
                state.shell_runtime,
                ShellState.set_tab_bar(
                  ShellRuntime.state(state.shell_runtime),
                  TabBar.drop_extension_feature_state_sources(tb)
                )
              )
        }

      _other ->
        state
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

    %{state | shell_runtime: runtime}
  end

  @spec drop_shell_extension_feature_state_sources(t()) :: t()
  defp drop_shell_extension_feature_state_sources(%__MODULE__{} = state) do
    runtime =
      ShellRuntime.drop_extension_feature_state_sources(
        state.shell_runtime,
        MingaEditor.Shell.Workflow.resolved_entries()
      )

    %{state | shell_runtime: runtime}
  end

  @doc "Returns the active workspace FileTree feature state."
  @spec file_tree_state(t()) :: FileTreeState.t()
  def file_tree_state(%__MODULE__{workspace: workspace}),
    do: SessionState.file_tree_state(workspace)

  @doc "Returns the active shell tab bar, when the active shell exposes one."
  @spec tab_bar(t()) :: TabBar.t() | nil
  def tab_bar(%__MODULE__{shell_runtime: runtime}),
    do: ShellState.tab_bar(ShellRuntime.state(runtime))

  @doc "Returns the active shell bottom panel."
  @spec bottom_panel(t()) :: BottomPanel.t()
  def bottom_panel(%__MODULE__{shell_runtime: runtime}),
    do: ShellState.bottom_panel(ShellRuntime.state(runtime))

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

  @spec diff_view_info(t(), pid() | nil) :: diff_view_info() | nil
  def diff_view_info(%__MODULE__{}, nil), do: nil

  def diff_view_info(%__MODULE__{} = state, diff_buf) when is_pid(diff_buf),
    do: Map.get(state.git.diff_views, diff_buf)

  @spec diff_view_for_source(t(), pid()) :: {pid(), diff_view_info()} | nil
  def diff_view_for_source(%__MODULE__{} = state, source_buf) when is_pid(source_buf) do
    Enum.find(state.git.diff_views, fn {_diff_buf, info} -> info.source_buf == source_buf end)
  end

  @spec diff_views_for_source(t(), pid()) :: [{pid(), diff_view_info()}]
  def diff_views_for_source(%__MODULE__{} = state, source_buf) when is_pid(source_buf) do
    Enum.filter(state.git.diff_views, fn {_diff_buf, info} -> info.source_buf == source_buf end)
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
  Purely removes a dead buffer from editor and shell lifecycle state.

  The process monitor has already delivered its terminal `:DOWN` message, so
  this transition performs no external work and returns state directly.
  """
  @spec close_buffer_pure(t(), pid()) :: t()
  def close_buffer_pure(%__MODULE__{} = state, pid) do
    state = state |> do_remove_dead_buffer(pid) |> MingaEditor.Shell.Workflow.ensure_available()

    {runtime, workspace} =
      ShellRuntime.route_buffer_died(state.shell_runtime, state.workspace, pid)

    %{state | shell_runtime: runtime, workspace: workspace}
  end

  @spec do_remove_dead_buffer(t(), pid()) :: t()
  defp do_remove_dead_buffer(
         %__MODULE__{workspace: %{buffers: %Buffers{} = buffers}} = state,
         pid
       ) do
    state = %{state | parser: ParserState.retire_buffer(state.parser, pid)}
    lifecycle = BufferLifecycle.retire_monitor(state.buffer_lifecycle, pid)
    new_buffers = Buffers.remove(buffers, pid)

    state =
      %{state | workspace: SessionState.set_buffers(state.workspace, new_buffers)}
      |> then(&%{&1 | buffer_lifecycle: lifecycle})

    ws = state.workspace

    state =
      if ws.agent_ui.panel.prompt_buffer == pid do
        MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
          state,
          (fn p -> %{p | prompt_buffer: nil} end).(state.workspace.agent_ui.panel)
        )
      else
        state
      end

    state = %{state | git: GitState.retire_diff_view(state.git, pid)}

    case tab_bar(state) do
      nil ->
        state

      tb ->
        %{
          state
          | shell_runtime:
              ShellRuntime.install_traditional_state(
                state.shell_runtime,
                ShellState.set_tab_bar(
                  ShellRuntime.state(state.shell_runtime),
                  TabBar.scrub_dead_buffer(tb, pid)
                )
              )
        }
    end
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

  @doc "Commits a frontend-ready viewport and capability negotiation atomically."
  @spec accept_frontend_ready(t(), Viewport.t(), MingaEditor.Frontend.Capabilities.t()) :: t()
  def accept_frontend_ready(%__MODULE__{} = state, %Viewport{} = viewport, capabilities) do
    state = %{state | workspace: SessionState.set_viewport(state.workspace, viewport)}

    frontend =
      state.frontend
      |> FrontendState.resize_terminal(viewport)
      |> FrontendState.accept_capabilities(capabilities)

    %{state | frontend: frontend}
  end

  @doc "Commits a frontend resize to both the workspace and frontend owners."
  @spec resize_frontend(t(), Viewport.t()) :: t()
  def resize_frontend(%__MODULE__{} = state, %Viewport{} = viewport) do
    state = %{state | workspace: SessionState.set_viewport(state.workspace, viewport)}
    %{state | frontend: FrontendState.resize_terminal(state.frontend, viewport)}
  end

  @doc "Clears frontend-retained render state after a frontend ready/recovery event."
  @spec reset_frontend_render_state(t()) :: t()
  def reset_frontend_render_state(%__MODULE__{} = state) do
    state = %{state | workspace: SessionState.mark_frontend_reset_pending(state.workspace)}

    state
    |> then(fn state ->
      message_store = MessageStore.reset_sent_cursor(state.render.message_store)
      render = RenderState.accept_message_store(state.render, message_store)
      correlation = RenderCorrelation.frontend_ready(render.render_correlation)
      %{state | render: RenderState.accept_correlation(render, correlation)}
    end)
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
  def terminal_viewport(%__MODULE__{frontend: frontend}), do: frontend.terminal_viewport

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

  # ── Other accessors ───────────────────────────────────────────────────────

  @doc """
  Returns the screen rect for layout computation, excluding the global
  minibuffer row and reserving space for the file tree panel when open.
  """
  @spec screen_rect(t()) :: WindowTree.rect()
  def screen_rect(%__MODULE__{frontend: %{terminal_viewport: viewport}} = state) do
    case file_tree_state(state).tree do
      %FileTree{width: tw} ->
        # Tree occupies columns 0..tw-1, separator at column tw,
        # editor content starts at column tw+1.
        editor_col = tw + 1
        editor_width = max(viewport.cols - editor_col, 1)
        {0, editor_col, editor_width, viewport.rows - 1}

      nil ->
        {0, 0, viewport.cols, viewport.rows - 1}
    end
  end

  @doc "Returns the screen rect for the file tree panel, or nil if closed."
  @spec tree_rect(t()) :: WindowTree.rect() | nil
  def tree_rect(%__MODULE__{frontend: %{terminal_viewport: viewport}} = state) do
    case file_tree_state(state).tree do
      %FileTree{width: tw} ->
        # Row 0 is the tab bar; file tree starts at row 1.
        {1, 0, tw, viewport.rows - 2}

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
  @spec rebind_buffer_file_identity(t(), pid(), String.t() | nil) :: t()
  def rebind_buffer_file_identity(%__MODULE__{} = state, buffer_pid, path)
      when is_pid(buffer_pid) and (is_binary(path) or is_nil(path)) do
    tab_bar = tab_bar(state)

    case {matching_file_tabs(tab_bar, buffer_pid),
          buffer_file_ref(buffer_pid, path, state.workspace)} do
      {[], _} ->
        state

      {tabs, %FileRef{} = file_ref} ->
        %{
          state
          | shell_runtime:
              ShellRuntime.install_traditional_state(
                state.shell_runtime,
                ShellState.set_tab_bar(
                  ShellRuntime.state(state.shell_runtime),
                  rebind_tabs_to_file_ref(tab_bar, tabs, file_ref)
                )
              )
        }
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

  @spec buffer_file_ref(pid(), String.t() | nil, SessionState.t()) :: FileRef.t()
  defp buffer_file_ref(buffer_pid, path, %SessionState{} = workspace) do
    case {path, SessionState.file_tree_state(workspace).project_root} do
      {path, root} when is_binary(path) and is_binary(root) ->
        case FileRef.from_path(root, path) do
          {:ok, file_ref} -> file_ref
          {:error, :outside_project} -> FileRef.from_buffer(buffer_pid)
        end

      _ ->
        FileRef.from_buffer(buffer_pid)
    end
  end

  @doc """
  Purely adds or activates a buffer and returns its focused monitor result.

  Generic concerns (buffer pool) are handled here. Shell-specific presentation
  logic is dispatched through `shell.on_buffer_added/5`. The Editor-facing
  wrapper creates a monitor only for a newly registered process.
  """
  @spec add_buffer_pure(t(), pid(), keyword()) :: {t(), buffer_registration_result()}
  def add_buffer_pure(%__MODULE__{workspace: %{buffers: bs}} = state, pid, opts \\ []) do
    context =
      Keyword.get_lazy(opts, :context, fn -> state.buffer_lifecycle.buffer_add_context end)

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
      %{state | workspace: SessionState.set_buffers(state.workspace, new_bs)}
      |> MingaEditor.Shell.Workflow.ensure_available()

    {runtime, workspace} =
      ShellRuntime.route_buffer_added(
        state.shell_runtime,
        prev_workspace,
        state.workspace,
        pid,
        context
      )

    {_context, lifecycle} = BufferLifecycle.consume_buffer_context(state.buffer_lifecycle)

    state =
      %{state | shell_runtime: runtime, workspace: workspace}
      |> then(&%{&1 | buffer_lifecycle: lifecycle})

    result = if already_pooled, do: :already_registered, else: {:monitor, pid}
    {state, result}
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

    state = clear_file_tabs(state)
    %{state | workspace: SessionState.enter_empty_state(state.workspace, launchpad_opts)}
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
    state =
      tb.tabs
      |> Enum.filter(&(&1.kind == :file))
      |> Enum.reduce(state, fn tab, acc -> retire_lsp_operations_for_tab(acc, tab.id) end)

    %{
      state
      | shell_runtime:
          ShellRuntime.install_traditional_state(
            state.shell_runtime,
            ShellState.set_tab_bar(
              ShellRuntime.state(state.shell_runtime),
              TabBar.remove_file_tabs(tb)
            )
          )
    }
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
              %{
                state
                | shell_runtime:
                    ShellRuntime.install_traditional_state(
                      state.shell_runtime,
                      ShellState.set_tab_bar(
                        ShellRuntime.state(state.shell_runtime),
                        TabBar.update_context(tb, id, synthesized)
                      )
                    )
              }

            _ ->
              state
          end

        {synthesized, state}
      else
        {TabContext.from_map(context), state}
      end

    state
    |> then(fn state ->
      %{state | workspace: SessionState.restore_tab_context(state.workspace, context)}
    end)
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
    %{state | workspace: workspace}
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
    rows = max(state.frontend.terminal_viewport.rows, 1)
    cols = max(state.frontend.terminal_viewport.cols, 1)
    windows = build_agent_chat_windows(rows, cols)
    build_agent_tab_defaults(state, windows)
  end

  @spec build_file_tab_defaults(t()) :: Tab.context()
  defp build_file_tab_defaults(state) do
    win_id = state.workspace.windows.next_id
    rows = state.frontend.terminal_viewport.rows
    cols = state.frontend.terminal_viewport.cols
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
      viewport: state.frontend.terminal_viewport,
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
      viewport: state.frontend.terminal_viewport,
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

  @doc """
  Purely switches tab-owned editor state and returns the selected tab as a
  focused result. The aggregate `switch_tab/2` transition uses that result to
  refresh the session-backed agent presentation through owner APIs.
  """
  @spec switch_tab_pure(t(), Tab.id()) :: {t(), tab_switch_result()}
  def switch_tab_pure(%__MODULE__{} = state, target_id) do
    state = MingaEditor.Shell.Workflow.ensure_available(state)

    case tab_bar(state) do
      nil ->
        {state, :unchanged}

      %TabBar{active_id: ^target_id} ->
        {state, :unchanged}

      %TabBar{active_id: current_id} = tb ->
        switch_to_existing_tab(state, tb, current_id, target_id, TabBar.get(tb, target_id))
    end
  end

  @spec switch_to_existing_tab(t(), TabBar.t(), Tab.id(), Tab.id(), Tab.t() | nil) ::
          {t(), tab_switch_result()}
  defp switch_to_existing_tab(%__MODULE__{} = state, _tb, _current_id, _target_id, nil),
    do: {state, :unchanged}

  defp switch_to_existing_tab(
         %__MODULE__{} = state,
         %TabBar{} = tb,
         current_id,
         target_id,
         %Tab{} = target
       ) do
    state = retire_lsp_operations_for_tab(state, current_id)

    context = snapshot_tab_context_no_sync(state)

    tb =
      tb
      |> TabBar.update_context(current_id, context)
      |> TabBar.switch_to(target_id)

    state = install_tab_bar(state, tb)
    state = restore_tab_context(state, target.context)
    state = sync_agent_ui_from_active_workspace(state)
    state = MingaEditor.Shell.Traditional.ModalWorkflow.dismiss_if_stale(state)

    state =
      install_tab_bar(
        state,
        TabBar.update_tab(tab_bar(state), target_id, &Tab.set_attention(&1, false))
      )

    workspace = SessionState.invalidate_all_windows(state.workspace)
    render = RenderState.invalidate_layout(state.render)
    state = %{state | workspace: workspace, render: render}

    {state, {:switched, target}}
  end

  @spec install_tab_bar(t(), TabBar.t()) :: t()
  defp install_tab_bar(%__MODULE__{} = state, %TabBar{} = tab_bar) do
    shell_state = ShellState.set_tab_bar(ShellRuntime.state(state.shell_runtime), tab_bar)

    %{
      state
      | shell_runtime: ShellRuntime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  @doc """
  Switches to the tab with `target_id`.

  Snapshots the current tab's context, stores it, updates the tab bar's
  active pointer, and restores the target tab's saved context into the
  live editor state. Invalidates layout and window caches since the
  entire visual context changes.

  The aggregate transition applies spinner and session-cache changes through
  their focused owners after the pure tab value changes.
  """
  @spec switch_tab(t(), Tab.id()) :: t()
  def switch_tab(%__MODULE__{} = state, target_id) do
    state
    |> switch_tab_pure(target_id)
    |> finish_tab_switch()
  end

  @spec finish_tab_switch({t(), tab_switch_result()}) :: t()
  defp finish_tab_switch({state, :unchanged}), do: state

  defp finish_tab_switch({state, {:switched, %Tab{} = target}}) do
    state
    |> MingaEditor.Shell.Traditional.Workflow.install_agent_spinner_stop()
    |> rebuild_switched_agent(target)
    |> maybe_restart_incoming_spinner()
  end

  @spec rebuild_switched_agent(t(), Tab.t()) :: t()
  defp rebuild_switched_agent(state, %Tab{kind: :agent} = tab) do
    state
    |> MingaEditor.AgentLifecycle.rebuild_agent_from_session(tab)
    |> sync_active_agent_transcript()
  end

  defp rebuild_switched_agent(state, %Tab{} = tab),
    do: MingaEditor.AgentLifecycle.rebuild_agent_from_session(state, tab)

  @doc "Retires correlated references and rename requests owned by a departing tab."
  @spec retire_lsp_operations_for_tab(t(), Tab.id()) :: t()
  def retire_lsp_operations_for_tab(%__MODULE__{} = state, tab_id) do
    {requests, lsp} = LSPState.take_operation_requests_for_tab(state.lsp, tab_id)
    state = %{state | lsp: lsp}

    Enum.reduce(requests, state, fn {kind, operation_id, ^tab_id}, state ->
      %{
        state
        | feedback:
            Feedback.accept_operation_feedback(
              state.feedback,
              OperationFeedback.finish(
                state.feedback.operation_feedback,
                operation_id,
                :stale,
                lsp_operation_tab_departure_message(kind)
              )
            )
      }
    end)
  end

  @spec lsp_operation_tab_departure_message(:references | :rename) :: String.t()
  defp lsp_operation_tab_departure_message(:references),
    do: "References response ignored after tab switch"

  defp lsp_operation_tab_departure_message(:rename),
    do: "Rename response ignored after tab switch"

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

    state = %{state | workspace: SessionState.set_agent_ui(state.workspace, agent_ui)}
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

        %{
          state
          | shell_runtime:
              ShellRuntime.install_traditional_state(
                state.shell_runtime,
                ShellState.set_tab_bar(ShellRuntime.state(state.shell_runtime), tb)
              )
        }

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

  @spec maybe_restart_incoming_spinner(t()) :: t()
  defp maybe_restart_incoming_spinner(state) do
    agent = MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)

    if AgentState.busy?(agent) and agent.spinner_timer == nil do
      MingaEditor.Shell.Traditional.Workflow.install_agent_spinner_start(state)
    else
      state
    end
  end

  # Agent events queued during the blocking editor snapshot call cannot
  # misroute. GenServer serialization prevents message handling until the
  # aggregate tab transition returns; stale outgoing events then route by their
  # unchanged session pid. See #1401 for the full analysis.
  @spec sync_active_agent_transcript(t()) :: t()
  defp sync_active_agent_transcript(state) do
    session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)

    if is_pid(session) do
      MingaEditor.AgentLifecycle.sync_transcript(state)
    else
      state
    end
  end
end
