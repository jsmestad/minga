defmodule MingaEditor.State do
  @moduledoc """
  Immutable root value for the single Editor GenServer.

  The root stores exactly 16 owner values. Leaf transitions belong to those
  owners. This module retains only pure transitions whose invariant atomically
  spans at least two top-level owners; process, registry, persistence, logging,
  rendering, and service work belongs to focused workflows around these
  transitions.
  """

  alias MingaEditor.FeatureState
  alias MingaEditor.Renderer.ReceiptProjection
  alias MingaEditor.Renderer.RenderReceipt
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Identity, as: ShellIdentity
  alias MingaEditor.Shell.Runtime, as: ShellRuntime
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State.AgentConnection
  alias MingaEditor.State.Appearance
  alias MingaEditor.State.BufferLifecycle
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.ExtensionSurfaces
  alias MingaEditor.State.Feedback
  alias MingaEditor.State.Frontend, as: FrontendState
  alias MingaEditor.State.Git, as: GitState
  alias MingaEditor.State.Interaction
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.OperationFeedback
  alias MingaEditor.State.Parser, as: ParserState
  alias MingaEditor.State.Remote
  alias MingaEditor.State.Render, as: RenderState
  alias MingaEditor.State.RenderCorrelation
  alias MingaEditor.State.Session, as: EditorSessionState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Panel.MessageStore
  alias MingaEditor.UI.Theme
  alias MingaEditor.Viewport

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

  @type backend :: FrontendState.backend()
  @type rendering_policy :: FrontendState.rendering_policy()
  @type shell_state :: MingaEditor.Shell.shell_state()

  @typedoc "Focused result from a pure buffer-registration transition."
  @type buffer_registration_result :: :already_registered | {:monitor, pid()}

  @typedoc "Focused result from a pure tab-switch transition."
  @type tab_switch_result :: :unchanged | {:switched, Tab.t()}

  @type render_receipt_result ::
          :applied | {:stale, RenderCorrelation.freshness_reason() | :shell_identity}

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

  @doc "Drops one feature source across the live workspace, tab snapshots, and shell stash."
  @spec drop_feature_state_source(t(), [Entry.t()], FeatureState.source()) :: t()
  def drop_feature_state_source(%__MODULE__{} = state, entries, source) when is_list(entries) do
    workspace = SessionState.drop_feature_state_source(state.workspace, source)
    runtime = ShellRuntime.drop_feature_state_source(state.shell_runtime, entries, source)
    %{state | workspace: workspace, shell_runtime: runtime}
  end

  @doc "Drops extension feature state across the live workspace, tab snapshots, and shell stash."
  @spec drop_extension_feature_state_sources(t(), [Entry.t()]) :: t()
  def drop_extension_feature_state_sources(%__MODULE__{} = state, entries)
      when is_list(entries) do
    workspace = SessionState.drop_extension_feature_state_sources(state.workspace)
    runtime = ShellRuntime.drop_extension_feature_state_sources(state.shell_runtime, entries)
    %{state | workspace: workspace, shell_runtime: runtime}
  end

  @doc "Atomically selects a theme and recolors parser-owned highlights."
  @spec apply_theme(t(), Theme.t()) :: t()
  def apply_theme(%__MODULE__{} = state, %Theme{} = theme) do
    appearance = Appearance.select_theme(state.appearance, theme)
    highlighting = MingaEditor.State.Highlighting.retheme_all(state.parser.highlighting, theme)
    parser = ParserState.accept_highlighting(state.parser, highlighting)
    %{state | appearance: appearance, parser: parser}
  end

  @doc "Commits an extension snapshot transition unless semantic Editor state superseded it."
  @spec accept_extension_event_result(t(), t(), t()) :: {:ok, t()} | :stale
  def accept_extension_event_result(
        %__MODULE__{} = current,
        %__MODULE__{} = base,
        %__MODULE__{} = candidate
      ) do
    if current == %{base | render: current.render} do
      {:ok, %{candidate | render: current.render}}
    else
      :stale
    end
  end

  @doc "Atomically integrates a synchronous focused renderer receipt."
  @spec integrate_synchronous_renderer_receipt(t(), RenderReceipt.t()) :: t()
  def integrate_synchronous_renderer_receipt(%__MODULE__{} = state, %RenderReceipt{} = receipt) do
    correlation =
      RenderCorrelation.accept_synchronous_receipt(
        state.render.render_correlation,
        receipt.intent_revision,
        receipt.frame_seq
      )

    commit_renderer_receipt(state, receipt, correlation)
  end

  @doc "Atomically integrates a fresh asynchronous receipt or returns its stale reason."
  @spec integrate_renderer_receipt(t(), RenderReceipt.t()) :: {t(), render_receipt_result()}
  def integrate_renderer_receipt(%__MODULE__{} = state, %RenderReceipt{} = receipt) do
    case RenderCorrelation.classify_receipt(
           state.render.render_correlation,
           receipt.intent_revision,
           receipt.frame_seq
         ) do
      {:stale, reason} ->
        {state, {:stale, reason}}

      {:fresh, revision} ->
        integrate_fresh_renderer_receipt(state, RenderReceipt.correlate(receipt, revision))
    end
  end

  @doc "Commits frontend capabilities and viewport dimensions as one connection observation."
  @spec accept_frontend_ready(t(), Viewport.t(), MingaEditor.Frontend.Capabilities.t()) :: t()
  def accept_frontend_ready(%__MODULE__{} = state, %Viewport{} = viewport, capabilities) do
    workspace = SessionState.set_viewport(state.workspace, viewport)

    frontend =
      state.frontend
      |> FrontendState.resize_terminal(viewport)
      |> FrontendState.accept_capabilities(capabilities)

    %{state | workspace: workspace, frontend: frontend}
  end

  @doc "Commits a frontend resize to workspace and frontend owners atomically."
  @spec resize_frontend(t(), Viewport.t()) :: t()
  def resize_frontend(%__MODULE__{} = state, %Viewport{} = viewport) do
    workspace = SessionState.set_viewport(state.workspace, viewport)
    frontend = FrontendState.resize_terminal(state.frontend, viewport)
    %{state | workspace: workspace, frontend: frontend}
  end

  @doc "Advances the semantic render revision and installs it through the Render owner."
  @spec submit_render_intent(t()) :: {t(), pos_integer()}
  def submit_render_intent(%__MODULE__{} = state) do
    {correlation, revision} = RenderCorrelation.submit(state.render.render_correlation)
    render = RenderState.accept_correlation(state.render, correlation)
    {%{state | render: render}, revision}
  end

  @doc "Transfers one queued keyframe request to the renderer boundary."
  @spec take_keyframe_request(t()) :: {boolean(), t()}
  def take_keyframe_request(%__MODULE__{} = state) do
    {keyframe?, correlation} =
      RenderCorrelation.take_keyframe_request(state.render.render_correlation)

    render = RenderState.accept_correlation(state.render, correlation)
    {keyframe?, %{state | render: render}}
  end

  @doc "Clears render observations after frontend state loss."
  @spec reset_frontend_render_state(t()) :: t()
  def reset_frontend_render_state(%__MODULE__{} = state) do
    message_store = MessageStore.reset_sent_cursor(state.render.message_store)
    render = RenderState.accept_message_store(state.render, message_store)
    correlation = RenderCorrelation.frontend_ready(render.render_correlation)
    render = RenderState.accept_correlation(render, correlation)
    %{state | render: render}
  end

  @doc "Purely adds or activates a buffer across workspace and lifecycle owners."
  @spec register_buffer(t(), pid(), MingaEditor.Shell.buffer_add_context()) ::
          {t(), buffer_registration_result()}
  def register_buffer(%__MODULE__{workspace: %{buffers: buffers}} = state, pid, context)
      when is_pid(pid) and context in [:open, :preview] do
    already_registered? = pid in buffers.list

    buffers =
      if already_registered? do
        Buffers.switch_to(buffers, Enum.find_index(buffers.list, &(&1 == pid)))
      else
        Buffers.add(buffers, pid)
      end

    workspace =
      state.workspace
      |> SessionState.set_buffers(buffers)
      |> SessionState.activate_buffer(buffers)

    {_consumed_context, lifecycle} =
      BufferLifecycle.consume_buffer_context(state.buffer_lifecycle)

    state = %{state | workspace: workspace, buffer_lifecycle: lifecycle}
    result = if already_registered?, do: :already_registered, else: {:monitor, pid}
    {state, result}
  end

  @doc "Purely installs a workflow-calculated buffer shell transition into the root."
  @spec install_buffer_shell_transition(t(), ShellRuntime.t(), SessionState.t()) :: t()
  def install_buffer_shell_transition(
        %__MODULE__{} = state,
        %ShellRuntime{} = runtime,
        %SessionState{} = workspace
      ) do
    %{state | workspace: workspace, shell_runtime: runtime}
  end

  @doc "Removes a retired buffer across every root owner that retains its identity."
  @spec remove_buffer(t(), pid()) :: t()
  def remove_buffer(%__MODULE__{} = state, pid) when is_pid(pid) do
    parser = ParserState.retire_buffer(state.parser, pid)
    lifecycle = BufferLifecycle.retire_monitor(state.buffer_lifecycle, pid)
    buffers = Buffers.remove(state.workspace.buffers, pid)

    workspace =
      state.workspace
      |> SessionState.set_buffers(buffers)
      |> SessionState.retire_agent_prompt_buffer(pid)
      |> SessionState.activate_buffer(buffers)

    runtime = ShellRuntime.retire_buffer(state.shell_runtime, pid)
    git = GitState.retire_buffer(state.git, pid)
    remote = Remote.retire_buffer(state.remote, pid)

    %{
      state
      | parser: parser,
        buffer_lifecycle: lifecycle,
        workspace: workspace,
        shell_runtime: runtime,
        git: git,
        remote: remote
    }
  end

  @doc "Enters the zero-buffer launchpad and retires every departing file tab operation."
  @spec enter_empty_state(t()) :: t()
  def enter_empty_state(%__MODULE__{} = state) do
    state = retire_file_tab_operations(state)
    runtime = remove_file_tabs(state.shell_runtime)
    launchpad_opts = EditorSessionState.session_opts(state.session)
    workspace = SessionState.enter_empty_state(state.workspace, launchpad_opts)
    %{state | shell_runtime: runtime, workspace: workspace}
  end

  @doc "Restores a tab context and installs synthesized defaults for a brand-new tab."
  @spec restore_tab_context(t(), Tab.context() | Tab.legacy_context()) :: t()
  def restore_tab_context(%__MODULE__{} = state, context) when is_map(context) do
    {context, runtime} = resolve_tab_context(state, context)
    workspace = SessionState.restore_tab_context(state.workspace, context)
    workspace = activate_file_tab_buffer(workspace, runtime)
    %{state | workspace: workspace, shell_runtime: runtime}
  end

  @doc "Purely switches tab-owned root values and returns the selected tab."
  @spec switch_tab(t(), Tab.id()) :: {t(), tab_switch_result()}
  def switch_tab(%__MODULE__{} = state, target_id) do
    case traditional_tab_bar(state.shell_runtime) do
      nil ->
        {state, :unchanged}

      %TabBar{active_id: ^target_id} ->
        {state, :unchanged}

      %TabBar{active_id: current_id} = tab_bar ->
        switch_existing_tab(state, tab_bar, current_id, TabBar.get(tab_bar, target_id))
    end
  end

  @doc "Retires tab-scoped LSP correlations and their operation feedback atomically."
  @spec retire_lsp_operations_for_tab(t(), Tab.id()) :: t()
  def retire_lsp_operations_for_tab(%__MODULE__{} = state, tab_id) do
    {requests, lsp} = LSPState.take_operation_requests_for_tab(state.lsp, tab_id)

    feedback =
      Enum.reduce(requests, state.feedback, fn {kind, operation_id, ^tab_id}, feedback ->
        operation_feedback =
          OperationFeedback.finish(
            feedback.operation_feedback,
            operation_id,
            :stale,
            lsp_operation_tab_departure_message(kind)
          )

        Feedback.accept_operation_feedback(feedback, operation_feedback)
      end)

    %{state | lsp: lsp, feedback: feedback}
  end

  @spec integrate_fresh_renderer_receipt(t(), RenderReceipt.t()) ::
          {t(), render_receipt_result()}
  defp integrate_fresh_renderer_receipt(state, receipt) do
    if renderer_receipt_shell_current?(state, receipt) do
      correlation =
        RenderCorrelation.accept_receipt(
          state.render.render_correlation,
          receipt.intent_revision,
          receipt.frame_seq
        )

      {commit_renderer_receipt(state, receipt, correlation), :applied}
    else
      {state, {:stale, :shell_identity}}
    end
  end

  @spec commit_renderer_receipt(t(), RenderReceipt.t(), RenderCorrelation.t()) :: t()
  defp commit_renderer_receipt(state, receipt, correlation) do
    {workspace, runtime, render} =
      ReceiptProjection.project(
        state.workspace,
        state.shell_runtime,
        state.render,
        receipt,
        correlation
      )

    %{state | workspace: workspace, shell_runtime: runtime, render: render}
  end

  @spec renderer_receipt_shell_current?(t(), RenderReceipt.t()) :: boolean()
  defp renderer_receipt_shell_current?(%__MODULE__{} = state, %RenderReceipt{} = receipt) do
    case receipt.shell_identity do
      %ShellIdentity{} = identity ->
        receipt.shell_id == ShellRuntime.id(state.shell_runtime) and
          ShellRuntime.matches_identity?(state.shell_runtime, identity)

      _missing_or_invalid ->
        false
    end
  end

  @spec switch_existing_tab(t(), TabBar.t(), Tab.id(), Tab.t() | nil) ::
          {t(), tab_switch_result()}
  defp switch_existing_tab(%__MODULE__{} = state, _tab_bar, _current_id, nil),
    do: {state, :unchanged}

  defp switch_existing_tab(%__MODULE__{} = state, tab_bar, current_id, %Tab{} = target) do
    state = retire_lsp_operations_for_tab(state, current_id)
    context = TabContext.snapshot(state.workspace)

    tab_bar =
      tab_bar
      |> TabBar.snapshot_and_switch(current_id, context, target.id)
      |> TabBar.clear_attention(target.id)

    runtime = install_tab_bar(state.shell_runtime, tab_bar)
    state = %{state | shell_runtime: runtime}
    state = restore_tab_context(state, target.context)
    render = RenderState.invalidate_layout(state.render)
    {%{state | render: render}, {:switched, target}}
  end

  @spec resolve_tab_context(t(), Tab.context() | Tab.legacy_context()) ::
          {Tab.context(), ShellRuntime.t()}
  defp resolve_tab_context(%__MODULE__{} = state, context) do
    if TabContext.empty?(context) do
      synthesized = new_tab_context(state)
      {synthesized, install_active_tab_context(state.shell_runtime, synthesized)}
    else
      {TabContext.from_map(context), state.shell_runtime}
    end
  end

  @spec new_tab_context(t()) :: Tab.context()
  defp new_tab_context(%__MODULE__{} = state) do
    case traditional_tab_bar(state.shell_runtime) do
      %TabBar{} = tab_bar ->
        case TabBar.active(tab_bar) do
          %Tab{kind: :agent} ->
            TabContext.new_agent(
              state.frontend.terminal_viewport,
              state.workspace.file_tree.project_root
            )

          _file_or_missing ->
            TabContext.new_file(state.workspace, state.frontend.terminal_viewport)
        end

      nil ->
        TabContext.new_file(state.workspace, state.frontend.terminal_viewport)
    end
  end

  @spec install_active_tab_context(ShellRuntime.t(), Tab.context()) :: ShellRuntime.t()
  defp install_active_tab_context(runtime, context) do
    case traditional_tab_bar(runtime) do
      %TabBar{active_id: active_id} = tab_bar ->
        install_tab_bar(runtime, TabBar.update_context(tab_bar, active_id, context))

      nil ->
        runtime
    end
  end

  @spec activate_file_tab_buffer(SessionState.t(), ShellRuntime.t()) :: SessionState.t()
  defp activate_file_tab_buffer(workspace, runtime) do
    case traditional_tab_bar(runtime) do
      %TabBar{} = tab_bar ->
        case TabBar.active(tab_bar) do
          %Tab{kind: :file} -> SessionState.activate_buffer(workspace, workspace.buffers)
          _agent_or_missing -> workspace
        end

      nil ->
        workspace
    end
  end

  @spec retire_file_tab_operations(t()) :: t()
  defp retire_file_tab_operations(%__MODULE__{} = state) do
    case traditional_tab_bar(state.shell_runtime) do
      %TabBar{tabs: tabs} ->
        tabs
        |> Enum.filter(&(&1.kind == :file))
        |> Enum.reduce(state, fn tab, acc -> retire_lsp_operations_for_tab(acc, tab.id) end)

      nil ->
        state
    end
  end

  @spec remove_file_tabs(ShellRuntime.t()) :: ShellRuntime.t()
  defp remove_file_tabs(runtime) do
    case traditional_tab_bar(runtime) do
      %TabBar{} = tab_bar -> install_tab_bar(runtime, TabBar.remove_file_tabs(tab_bar))
      nil -> runtime
    end
  end

  @spec traditional_tab_bar(ShellRuntime.t()) :: TabBar.t() | nil
  defp traditional_tab_bar(%ShellRuntime{state: %ShellState{} = shell_state}) do
    ShellState.tab_bar(shell_state)
  end

  defp traditional_tab_bar(%ShellRuntime{}), do: nil

  @spec install_tab_bar(ShellRuntime.t(), TabBar.t()) :: ShellRuntime.t()
  defp install_tab_bar(%ShellRuntime{} = runtime, %TabBar{} = tab_bar) do
    shell_state = ShellState.install_tab_bar(ShellRuntime.state(runtime), tab_bar)
    ShellRuntime.install_traditional_state(runtime, shell_state)
  end

  @spec lsp_operation_tab_departure_message(:references | :rename) :: String.t()
  defp lsp_operation_tab_departure_message(:references),
    do: "References response ignored after tab switch"

  defp lsp_operation_tab_departure_message(:rename),
    do: "Rename response ignored after tab switch"
end
