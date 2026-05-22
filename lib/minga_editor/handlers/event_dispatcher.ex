defmodule MingaEditor.Handlers.EventDispatcher do
  @moduledoc """
  Dispatches {:minga_event, event, payload} messages to the correct handler or inline logic.

  Extracted from MingaEditor to keep the GenServer module focused on process
  lifecycle. The editor's `handle_info` for `:minga_event` tuples delegates
  to `dispatch/4`.
  """

  alias Minga.Distribution.Events, as: DistributionEvents
  alias Minga.Events
  alias Minga.Mode.ExtensionConfirmState
  alias MingaEditor.Agent.BufferSync, as: AgentBufferSync
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Commands
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Handlers.EffectHandler
  alias MingaEditor.Handlers.FileEventHandler
  alias MingaEditor.Handlers.Notifications
  alias MingaEditor.Handlers.ToolHandler
  alias MingaEditor.MessageLog
  alias MingaEditor.Renderer
  alias MingaEditor.Startup
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.LSP, as: LSPState
  alias MingaEditor.State.Remote
  alias MingaEditor.State.Workspace.RemoteSession
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.TabBar
  alias MingaEditor.UI.Face
  alias MingaEditor.UI.Theme.Loader, as: ThemeLoader
  alias MingaAgent.Session, as: AgentSession
  alias MingaAgent.SessionManager
  alias MingaAgent.Subagent

  @tool_events [
    :tool_install_started,
    :tool_install_progress,
    :tool_install_complete,
    :tool_install_failed,
    :tool_uninstall_complete,
    :tool_missing
  ]

  @file_events [
    :git_status_changed,
    :buffer_saved,
    :buffer_changed,
    :file_written,
    :project_rebuilt
  ]

  @spec dispatch(EditorState.t(), atom(), term(), term()) :: EditorState.t()
  def dispatch(state, event, _payload, msg) when event in @tool_events do
    {state, effects} = ToolHandler.handle(state, msg)
    EffectHandler.apply_effects(state, effects)
  end

  def dispatch(state, event, _payload, msg) when event in @file_events do
    {state, effects} = FileEventHandler.handle(state, msg)
    EffectHandler.apply_effects(state, effects)
  end

  def dispatch(
        state,
        :lsp_status_changed,
        %Events.LspStatusEvent{name: name, status: status},
        _msg
      ) do
    old_status = state.lsp.status
    new_lsp = LSPState.update_server_status(state.lsp, name, status)
    state = %{state | lsp: new_lsp}
    if new_lsp.status != old_status, do: MingaEditor.schedule_render(state, 16), else: state
  end

  def dispatch(
        state,
        :diagnostics_updated,
        %Events.DiagnosticsUpdatedEvent{uri: uri},
        msg
      ) do
    MingaEditor.apply_diagnostic_decorations(state, uri)
    {state, effects} = FileEventHandler.handle(state, msg)

    if effects == [] do
      MingaEditor.schedule_render(state, 16)
    else
      EffectHandler.apply_effects(state, effects)
    end
  end

  def dispatch(
        state,
        :log_message,
        %Events.LogMessageEvent{text: text, level: level},
        _msg
      ) do
    MessageLog.append_to_store(state, text, level)
  end

  def dispatch(
        state,
        :command_done,
        %Events.CommandDoneEvent{name: "*test*", exit_code: exit_code},
        _msg
      ) do
    state
    |> Notifications.update_test_notification(exit_code)
    |> Renderer.render_or_async()
  end

  def dispatch(state, :command_done, _payload, _msg), do: state

  def dispatch(
        state,
        :option_changed,
        %Events.OptionChangedEvent{
          source: source,
          name: :cursor_animate,
          value: enabled
        },
        _msg
      )
      when is_boolean(enabled) do
    if option_source_matches?(source, EditorState.options_server(state)) do
      Startup.send_cursor_animation_config(state, enabled)
    end

    state
  end

  def dispatch(
        state,
        :option_changed,
        %Events.OptionChangedEvent{source: source, name: name, value: value},
        _msg
      ) do
    if option_source_matches?(source, EditorState.options_server(state)) and
         Protocol.GUI.settings_option?(name) do
      state
      |> MingaEditor.apply_runtime_config_option(name, value)
      |> MingaEditor.push_config_state_entry(name, value)
    else
      state
    end
  end

  def dispatch(
        state,
        :face_overrides_changed,
        %Events.FaceOverridesChangedEvent{buffer: buf_pid, overrides: overrides},
        _msg
      ) do
    # Pre-compute the merged face registry so the render pipeline reads from
    # editor state with zero GenServer calls back into the buffer.
    registries =
      if overrides == %{} do
        Map.delete(state.face_override_registries, buf_pid)
      else
        hl = Map.get(state.workspace.highlight.highlights, buf_pid)

        merged =
          if hl do
            Face.Registry.with_overrides(hl.face_registry, overrides)
          else
            base = Face.Registry.from_theme(state.theme)
            Face.Registry.with_overrides(base, overrides)
          end

        Map.put(state.face_override_registries, buf_pid, merged)
      end

    %{state | face_override_registries: registries}
  end

  def dispatch(
        state,
        :node_connected,
        %DistributionEvents.NodeConnectedEvent{} = event,
        _msg
      ) do
    handle_node_connected(state, event)
  end

  def dispatch(
        state,
        :node_disconnected,
        %DistributionEvents.NodeDisconnectedEvent{} = event,
        _msg
      ) do
    handle_node_disconnected(state, event)
  end

  def dispatch(
        state,
        :background_subagent_started,
        %Subagent.Handle{} = handle,
        _msg
      ) do
    AgentSession.subscribe(handle.pid, self())

    {shell_state, workspace} =
      state.shell.handle_event(
        state.shell_state,
        state.workspace,
        {:background_subagent_started, handle}
      )

    state = %{state | shell_state: shell_state, workspace: workspace}
    MingaEditor.schedule_render(state, 16)
  end

  def dispatch(
        state,
        :agent_session_stopped,
        %SessionManager.SessionStoppedEvent{pid: pid, reason: reason},
        _msg
      ) do
    if reason in [:normal, :shutdown] do
      Minga.Log.info(:agent, "[Agent] Session #{inspect(pid)} stopped")
    else
      Minga.Log.error(
        :agent,
        "[Agent] Session #{inspect(pid)} crashed: #{inspect(reason, pretty: true, limit: 500)}"
      )
    end

    Commands.BufferManagement.handle_agent_session_down(state, pid, reason)
  end

  def dispatch(state, :load_user_themes, _payload, _msg) do
    {themes, errors} = ThemeLoader.load_all()

    case MingaEditor.UI.Theme.register_user_themes(themes) do
      :ok ->
        :ok

      {:error, reason} ->
        Minga.Log.warning(:editor, "Theme registration failed: #{inspect(reason)}")
    end

    for %{path: path, error: error} <- errors do
      Minga.Log.warning(:editor, "Theme load error: #{path}: #{error}")
    end

    state
  end

  def dispatch(
        state,
        :extension_updates_available,
        %Minga.Extension.UpdatesAvailableEvent{updates: updates},
        _msg
      ) do
    ms = %ExtensionConfirmState{updates: updates}
    EditorState.transition_mode(state, :extension_confirm, ms)
  end

  def dispatch(state, _event, _payload, _msg), do: state

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec option_source_matches?(GenServer.server(), GenServer.server()) :: boolean()
  defp option_source_matches?(source, server) when source == server, do: true

  defp option_source_matches?(source, server) when is_atom(source) and is_pid(server),
    do: Process.whereis(source) == server

  defp option_source_matches?(source, server) when is_pid(source) and is_atom(server),
    do: Process.whereis(server) == source

  defp option_source_matches?(_source, _server), do: false

  # ── Remote / distribution helpers ────────────────────────────────────────────

  @spec handle_node_connected(EditorState.t(), DistributionEvents.NodeConnectedEvent.t()) ::
          EditorState.t()
  defp handle_node_connected(state, %{server_name: server_name, node: remote_node}) do
    sessions = discover_remote_sessions(remote_node, server_name)

    state =
      EditorState.update_remote(state, fn remote ->
        remote
        |> Remote.put_sessions(server_name, sessions)
        |> Remote.put_server_status(server_name, :connected)
      end)

    state = reconnect_remote_tabs(state, server_name, remote_node)
    count = length(sessions)
    status = remote_connected_status(server_name, count)
    EditorState.set_status(state, status)
  end

  @spec handle_node_disconnected(
          EditorState.t(),
          DistributionEvents.NodeDisconnectedEvent.t()
        ) :: EditorState.t()
  defp handle_node_disconnected(state, %{server_name: server_name}) do
    state =
      EditorState.update_remote(state, &Remote.put_server_status(&1, server_name, :disconnected))

    state = mark_remote_tabs(state, server_name, :disconnected)

    if active_remote_server?(state, server_name) do
      state
      |> AgentAccess.update_agent(&AgentState.stop_spinner_timer/1)
      |> AgentAccess.update_agent(
        &AgentState.set_error(&1, "[#{server_name}] disconnected, reconnecting...")
      )
      |> EditorState.set_status("[#{server_name}] disconnected, reconnecting...")
    else
      EditorState.set_status(state, "[#{server_name}] disconnected, reconnecting...")
    end
  end

  @spec discover_remote_sessions(node(), String.t()) :: [Remote.remote_session_entry()]
  defp discover_remote_sessions(remote_node, server_name) do
    :erpc.call(remote_node, MingaAgent.SessionManager, :list_sessions, [], 5_000)
  catch
    :exit, reason ->
      Minga.Log.warning(
        :distribution,
        "Failed to discover sessions on #{server_name}: #{inspect(reason)}"
      )

      []
  end

  @spec remote_connected_status(String.t(), non_neg_integer()) :: String.t()
  defp remote_connected_status(server_name, 0),
    do: "Connected to #{server_name} (no active sessions)"

  defp remote_connected_status(server_name, count),
    do: "Connected to #{server_name} (#{count} active sessions)"

  @spec reconnect_remote_tabs(EditorState.t(), String.t(), node()) :: EditorState.t()
  defp reconnect_remote_tabs(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         server_name,
         remote_node
       ) do
    workspaces = TabBar.remote_workspaces_for_server(tb, server_name)

    Enum.reduce(workspaces, state, fn workspace, acc ->
      reconnect_remote_workspace(acc, workspace, remote_node)
    end)
  end

  defp reconnect_remote_tabs(state, _server_name, _remote_node), do: state

  @spec reconnect_remote_workspace(EditorState.t(), Workspace.t(), node()) :: EditorState.t()
  defp reconnect_remote_workspace(
         state,
         %Workspace{remote_session: %RemoteSession{session_id: session_id}} = workspace,
         remote_node
       ) do
    case remote_session_pid(remote_node, session_id) do
      {:ok, pid} ->
        restore_remote_workspace(state, workspace, pid)

      {:error, :not_found} ->
        restore_remote_session_from_store(state, workspace, remote_node, session_id)

      {:error, _reason} ->
        mark_remote_workspace_status(state, workspace, :disconnected)
    end
  end

  defp reconnect_remote_workspace(state, %Workspace{}, _remote_node), do: state

  @spec remote_session_pid(node(), String.t()) :: {:ok, pid()} | {:error, term()}
  defp remote_session_pid(remote_node, session_id) do
    :erpc.call(remote_node, MingaAgent.SessionManager, :get_session, [session_id], 5_000)
  catch
    :exit, reason -> {:error, {:remote_unavailable, reason}}
  end

  @spec restore_remote_session_from_store(EditorState.t(), Workspace.t(), node(), String.t()) ::
          EditorState.t()
  defp restore_remote_session_from_store(state, workspace, remote_node, session_id) do
    case remote_session_data(remote_node, session_id) do
      {:ok, %{messages: messages}} -> restore_ended_remote_workspace(state, workspace, messages)
      {:error, _reason} -> mark_remote_workspace_status(state, workspace, :unavailable)
    end
  end

  @spec remote_session_data(node(), String.t()) ::
          {:ok, MingaAgent.SessionStore.session_data()} | {:error, term()}
  defp remote_session_data(remote_node, session_id) do
    :erpc.call(remote_node, MingaAgent.SessionStore, :load, [session_id], 5_000)
  catch
    :exit, reason -> {:error, {:remote_unavailable, reason}}
  end

  @spec restore_ended_remote_workspace(EditorState.t(), Workspace.t(), [term()]) ::
          EditorState.t()
  defp restore_ended_remote_workspace(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         %Workspace{id: workspace_id} = workspace,
         messages
       ) do
    tb = set_workspace_remote_state(tb, workspace, nil, :ended)
    state = EditorState.set_tab_bar(state, tb)

    if active_workspace?(tb, workspace_id) do
      case AgentAccess.agent(state).buffer do
        pid when is_pid(pid) -> AgentBufferSync.sync(pid, messages)
        _ -> :ok
      end

      state
      |> AgentAccess.update_agent(&AgentState.set_error(&1, "Remote session ended"))
      |> EditorState.set_status("Remote session ended")
    else
      state
    end
  end

  defp restore_ended_remote_workspace(state, %Workspace{}, _messages), do: state

  @spec restore_remote_workspace(EditorState.t(), Workspace.t(), pid()) :: EditorState.t()
  defp restore_remote_workspace(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         %Workspace{id: workspace_id} = workspace,
         pid
       ) do
    AgentSession.subscribe(pid, self())

    tb = set_workspace_remote_state(tb, workspace, pid, :connected)
    state = EditorState.set_tab_bar(state, tb)

    if active_workspace?(tb, workspace_id) do
      state
      |> maybe_rebuild_agent_from_workspace(workspace_id)
      |> AgentLifecycle.sync_buffer()
    else
      state
    end
  catch
    :exit, _reason -> mark_remote_workspace_status(state, workspace, :disconnected)
  end

  defp restore_remote_workspace(state, %Workspace{}, _pid), do: state

  @spec mark_remote_tabs(EditorState.t(), String.t(), Tab.connection_status()) :: EditorState.t()
  defp mark_remote_tabs(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, server_name, status) do
    EditorState.set_tab_bar(state, TabBar.set_remote_connection_status(tb, server_name, status))
  end

  defp mark_remote_tabs(state, _server_name, _status), do: state

  @spec mark_remote_workspace_status(
          EditorState.t(),
          Workspace.t(),
          :connected | :disconnected | :unavailable
        ) ::
          EditorState.t()
  defp mark_remote_workspace_status(state, workspace, :unavailable) do
    mark_remote_workspace_without_live_session(state, workspace, :unavailable)
  end

  defp mark_remote_workspace_status(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         %Workspace{} = workspace,
         status
       ) do
    EditorState.set_tab_bar(
      state,
      set_workspace_remote_state(tb, workspace, workspace.session, status)
    )
  end

  defp mark_remote_workspace_status(state, %Workspace{}, _status), do: state

  @spec mark_remote_workspace_without_live_session(
          EditorState.t(),
          Workspace.t(),
          :unavailable
        ) :: EditorState.t()
  defp mark_remote_workspace_without_live_session(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         %Workspace{} = workspace,
         status
       ) do
    EditorState.set_tab_bar(state, set_workspace_remote_state(tb, workspace, nil, status))
  end

  defp mark_remote_workspace_without_live_session(state, %Workspace{}, _status), do: state

  @spec set_workspace_remote_state(
          TabBar.t(),
          Workspace.t(),
          pid() | nil,
          RemoteSession.connection_status()
        ) ::
          TabBar.t()
  defp set_workspace_remote_state(%TabBar{} = tb, %Workspace{id: workspace_id}, session, status) do
    tb
    |> TabBar.update_workspace(workspace_id, fn workspace ->
      workspace
      |> set_workspace_live_session(session)
      |> Workspace.set_remote_connection_status(status)
    end)
    |> TabBar.sync_workspace_agent_tab_projection(workspace_id)
  end

  @spec set_workspace_live_session(Workspace.t(), pid() | nil) :: Workspace.t()
  defp set_workspace_live_session(%Workspace{} = workspace, nil),
    do: Workspace.clear_session(workspace)

  defp set_workspace_live_session(%Workspace{} = workspace, session) when is_pid(session) do
    Workspace.set_session(workspace, session)
  end

  @spec maybe_rebuild_agent_from_workspace(EditorState.t(), non_neg_integer()) :: EditorState.t()
  defp maybe_rebuild_agent_from_workspace(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         workspace_id
       ) do
    case workspace_agent_tab(tb, workspace_id) do
      %Tab{} = tab -> EditorState.rebuild_agent_from_session(state, tab)
      nil -> state
    end
  end

  defp maybe_rebuild_agent_from_workspace(state, _workspace_id), do: state

  @spec workspace_agent_tab(TabBar.t(), non_neg_integer()) :: Tab.t() | nil
  defp workspace_agent_tab(%TabBar{} = tb, workspace_id) do
    tb
    |> TabBar.tabs_in_workspace(workspace_id)
    |> Enum.find(&(&1.kind == :agent))
  end

  @spec active_workspace?(TabBar.t(), non_neg_integer()) :: boolean()
  defp active_workspace?(%TabBar{} = tb, workspace_id),
    do: TabBar.active_workspace_id(tb) == workspace_id

  @spec active_remote_server?(EditorState.t(), String.t()) :: boolean()
  defp active_remote_server?(%{shell_state: %{tab_bar: %TabBar{} = tb}}, server_name) do
    case TabBar.active_workspace(tb) do
      %Workspace{} = workspace -> Workspace.remote_server?(workspace, server_name)
      _workspace -> false
    end
  end

  defp active_remote_server?(state, server_name) do
    case state.shell.active_tab(state.shell_state) do
      %Tab{server_name: ^server_name} -> true
      _ -> false
    end
  end
end
