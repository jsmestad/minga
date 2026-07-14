defmodule MingaEditor.Handlers.EventDispatcher do
  @moduledoc """
  Routes `{:minga_event, event, payload}` messages to the owning workflow.

  The editor's `handle_info` delegates here only to choose an origin family.
  Tool and file workflows interpret their own focused actions; this module
  neither defines an action union nor forwards actions between families.
  Inline event branches already return final editor state.
  """

  alias Minga.Distribution.Events.NodeConnectedEvent
  alias Minga.Distribution.Events.NodeDisconnectedEvent
  alias Minga.Events
  alias Minga.Mode.ExtensionConfirmState
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Commands
  alias MingaEditor.Frontend.Protocol
  alias MingaEditor.Handlers.FileEventHandler
  alias MingaEditor.Handlers.Notifications
  alias MingaEditor.Handlers.ToolHandler
  alias MingaEditor.MessageLog
  alias MingaEditor.Remote.EventReplay
  alias MingaEditor.Remote.SessionClient
  alias MingaEditor.Renderer
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Workflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
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
  def dispatch(state, event, _payload, msg) when event in @tool_events,
    do: ToolHandler.dispatch(state, msg)

  def dispatch(state, event, _payload, msg) when event in @file_events,
    do: FileEventHandler.dispatch(state, msg)

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
    :ok = MingaEditor.apply_diagnostic_decorations(state, uri)

    state
    |> FileEventHandler.dispatch(msg)
    |> MingaEditor.schedule_render(16)
  end

  def dispatch(
        state,
        :log_message,
        %Events.LogMessageEvent{text: text, level: level},
        _msg
      ) do
    state
    |> MessageLog.append_to_store(text, level)
    |> MingaEditor.schedule_render(16)
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
    # cursor_animate rides in-frame as the CursorAnimation semantic model (#2119),
    # so a re-render delivers the new value (no out-of-band push).
    if option_source_matches?(source, state.interaction.options_server) do
      Renderer.render_or_async(state)
    else
      state
    end
  end

  def dispatch(
        state,
        :option_changed,
        %Events.OptionChangedEvent{source: source, name: name, value: value},
        _msg
      ) do
    if option_source_matches?(source, state.interaction.options_server) and
         Protocol.GUI.settings_option?(name) do
      # The config_state semantic model is emitted in-frame (#2119): rebuild the
      # cached settings snapshot, apply the runtime change, then re-render so the
      # next frame transaction carries the updated config_state (and theme/font).
      state
      |> MingaEditor.apply_runtime_config_option(name, value)
      |> MingaEditor.refresh_gui_config_state()
      |> Renderer.render_or_async()
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
    registry =
      if overrides == %{} do
        nil
      else
        highlight = Map.get(state.parser.highlighting.highlights, buf_pid)

        if highlight do
          Face.Registry.with_overrides(highlight.face_registry, overrides)
        else
          state.appearance.theme
          |> Face.Registry.from_theme()
          |> Face.Registry.with_overrides(overrides)
        end
      end

    %{
      state
      | parser: MingaEditor.State.Parser.reconcile_face_overrides(state.parser, buf_pid, registry)
    }
  end

  def dispatch(
        state,
        :node_connected,
        %NodeConnectedEvent{} = event,
        _msg
      ) do
    handle_node_connected(state, event)
  end

  def dispatch(
        state,
        :node_disconnected,
        %NodeDisconnectedEvent{} = event,
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
    case subscribe_to_session(state, handle.pid) do
      :ok ->
        state = Workflow.ensure_available(state)

        {runtime, workspace} =
          Runtime.route_event(
            state.shell_runtime,
            state.workspace,
            {:background_subagent_started, handle}
          )

        state =
          state
          |> then(fn state -> %{state | shell_runtime: runtime} end)
          |> then(fn state -> %{state | workspace: workspace} end)

        MingaEditor.schedule_render(state, 16)

      {:error, reason} ->
        Minga.Log.warning(
          :agent,
          "[Agent] Ignored background sub-agent #{handle.session_id} (#{inspect(handle.pid)}): #{inspect(reason)}"
        )

        state
    end
  end

  def dispatch(
        state,
        :agent_session_restarted,
        %SessionManager.SessionRestartedEvent{} = event,
        _msg
      ) do
    case handle_agent_session_restarted(state, event) do
      {:ok, state} -> MingaEditor.schedule_render(state, 16)
      {:stale, state} -> state
    end
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

    %{
      state
      | workspace:
          MingaEditor.Session.State.transition_mode(state.workspace, :extension_confirm, ms)
    }
  end

  def dispatch(state, _event, _payload, _msg), do: state

  @spec handle_agent_session_restarted(
          EditorState.t(),
          SessionManager.SessionRestartedEvent.t()
        ) :: {:ok, EditorState.t()} | {:stale, EditorState.t()}
  defp handle_agent_session_restarted(state, %SessionManager.SessionRestartedEvent{} = event) do
    new_pid = event.new_pid

    with {:ok, ^new_pid} <- safe_session_lookup(event.session_id),
         {:owned, state} <-
           Commands.BufferManagement.prepare_agent_session_restart(state, event.old_pid) do
      finish_agent_session_restart(state, event)
    else
      {:ok, current_pid} ->
        log_stale_agent_session_restart(event, {:current_pid, current_pid})
        {:stale, state}

      {:stale, normalized_state} ->
        log_stale_agent_session_restart(event, :unowned_old_pid)
        {:stale, normalized_state}

      {:error, reason} ->
        log_stale_agent_session_restart(event, reason)
        {:stale, state}
    end
  end

  @spec finish_agent_session_restart(EditorState.t(), SessionManager.SessionRestartedEvent.t()) ::
          {:ok, EditorState.t()} | {:stale, EditorState.t()}
  defp finish_agent_session_restart(state, %SessionManager.SessionRestartedEvent{} = event) do
    case subscribe_to_restarted_session(state, event) do
      :ok ->
        {:ok,
         Commands.BufferManagement.handle_agent_session_restarted(
           state,
           event.session_id,
           event.old_pid,
           event.new_pid,
           event.reason
         )}

      :stale ->
        {:stale, state}
    end
  end

  @spec safe_session_lookup(String.t()) :: {:ok, pid()} | {:error, term()}
  defp safe_session_lookup(session_id) do
    SessionManager.get_session(session_id)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec subscribe_to_restarted_session(EditorState.t(), SessionManager.SessionRestartedEvent.t()) ::
          :ok | :stale
  defp subscribe_to_restarted_session(state, %SessionManager.SessionRestartedEvent{} = event) do
    case subscribe_to_session(state, event.new_pid) do
      :ok ->
        :ok

      {:error, reason} ->
        log_stale_agent_session_restart(event, {:subscribe_failed, reason})
        :stale
    end
  end

  # Subscribes to a local session through the agent stream coalescer (#2289) so
  # token deltas are batched before reaching the Editor mailbox. Falls back to a
  # direct Editor subscription if the coalescer is not running (e.g. headless
  # boot races); correctness is unaffected, only mailbox pressure.
  @spec subscribe_to_session(EditorState.t(), pid()) :: :ok | {:error, term()}
  defp subscribe_to_session(state, pid) do
    subscribe_through_ingest(state.agent_connection.agent_ingest, pid)
  catch
    :exit, reason -> {:error, reason}
  end

  @spec subscribe_through_ingest(pid() | nil, pid()) :: :ok | {:error, term()}
  defp subscribe_through_ingest(ingest, pid) when is_pid(ingest) do
    MingaEditor.Agent.Ingest.subscribe_session(ingest, pid)
  end

  defp subscribe_through_ingest(_ingest, pid) do
    AgentSession.subscribe(pid, self())
  end

  @spec log_stale_agent_session_restart(SessionManager.SessionRestartedEvent.t(), term()) :: :ok
  defp log_stale_agent_session_restart(%SessionManager.SessionRestartedEvent{} = event, reason) do
    Minga.Log.warning(
      :agent,
      "[Agent] Ignored restart for session #{event.session_id} (#{inspect(event.old_pid)} -> #{inspect(event.new_pid)}) after #{inspect(event.reason)}: #{inspect(reason)}"
    )

    :ok
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec option_source_matches?(GenServer.server(), GenServer.server()) :: boolean()
  defp option_source_matches?(source, server) when source == server, do: true

  defp option_source_matches?(source, server) when is_atom(source) and is_pid(server),
    do: Process.whereis(source) == server

  defp option_source_matches?(source, server) when is_pid(source) and is_atom(server),
    do: Process.whereis(server) == source

  defp option_source_matches?(_source, _server), do: false

  # ── Remote / distribution helpers ────────────────────────────────────────────

  @spec handle_node_connected(EditorState.t(), NodeConnectedEvent.t()) :: EditorState.t()
  defp handle_node_connected(state, %{server_name: server_name, node: remote_node}) do
    sessions = discover_remote_sessions(remote_node, server_name)

    state =
      %{
        state
        | remote:
            (fn remote ->
               remote
               |> Remote.put_sessions(server_name, sessions)
               |> Remote.put_server_status(server_name, :connected)
             end).(state.remote)
      }

    state = reconnect_remote_tabs(state, server_name, remote_node)
    count = Enum.count(sessions)
    status = remote_connected_status(server_name, count)
    MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, status)
  end

  @spec handle_node_disconnected(EditorState.t(), NodeDisconnectedEvent.t()) :: EditorState.t()
  defp handle_node_disconnected(state, %{server_name: server_name}) do
    state =
      %{
        state
        | remote: (&Remote.put_server_status(&1, server_name, :disconnected)).(state.remote)
      }

    state = mark_remote_tabs(state, server_name, :disconnected)

    if active_remote_server?(state, server_name) do
      state
      |> MingaEditor.Shell.Traditional.Workflow.install_agent_spinner_stop()
      |> then(fn state ->
        MingaEditor.Shell.Traditional.Workflow.install_agent_state(
          state,
          (&AgentState.set_error(&1, "[#{server_name}] disconnected, reconnecting...")).(
            MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)
          )
        )
      end)
      |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
        "[#{server_name}] disconnected, reconnecting..."
      )
    else
      MingaEditor.Shell.Traditional.NoticeWorkflow.publish(
        state,
        "[#{server_name}] disconnected, reconnecting..."
      )
    end
  end

  @spec discover_remote_sessions(node(), String.t()) :: [Remote.remote_session_entry()]
  defp discover_remote_sessions(remote_node, server_name) do
    case SessionClient.list_sessions(remote_node) do
      {:ok, sessions} ->
        Enum.map(sessions, fn %{session_id: session_id, pid: pid, metadata: metadata} ->
          {session_id, pid, metadata}
        end)

      {:error, reason} ->
        Minga.Log.warning(
          :distribution,
          "Failed to discover sessions on #{server_name}: #{inspect(reason)}"
        )

        []
    end
  end

  @spec remote_connected_status(String.t(), non_neg_integer()) :: String.t()
  defp remote_connected_status(server_name, 0),
    do: "Connected to #{server_name} (no active sessions)"

  defp remote_connected_status(server_name, count),
    do: "Connected to #{server_name} (#{count} active sessions)"

  @spec reconnect_remote_tabs(EditorState.t(), String.t(), node()) :: EditorState.t()
  defp reconnect_remote_tabs(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
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
        restore_remote_workspace(state, workspace, remote_node, pid)

      {:error, :not_found} ->
        restore_remote_session_from_store(state, workspace, remote_node, session_id)

      {:error, _reason} ->
        mark_remote_workspace_status(state, workspace, :disconnected)
    end
  end

  defp reconnect_remote_workspace(state, %Workspace{}, _remote_node), do: state

  @spec remote_session_pid(node(), String.t()) :: {:ok, pid()} | {:error, term()}
  defp remote_session_pid(remote_node, session_id) do
    SessionClient.session_pid(remote_node, session_id)
  end

  @spec remote_api_attach(node(), String.t(), non_neg_integer()) ::
          {:ok, MingaAgent.RemoteAPI.attach_result()} | {:error, term()}
  defp remote_api_attach(remote_node, session_id, last_seen_event_id) do
    SessionClient.attach_driver(remote_node, session_id, last_seen_event_id)
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
    SessionClient.session_data(remote_node, session_id)
  end

  @spec restore_ended_remote_workspace(EditorState.t(), Workspace.t(), [term()]) ::
          EditorState.t()
  defp restore_ended_remote_workspace(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         %Workspace{id: workspace_id} = workspace,
         messages
       ) do
    tb = set_workspace_remote_state(tb, workspace, nil, :ended)

    state =
      then(state, fn root ->
        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(root.shell_runtime),
            tb
          )

        %{
          root
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
        }
      end)

    if active_workspace?(tb, workspace_id) do
      state
      |> AgentLifecycle.cache_messages(messages)
      |> MingaEditor.Shell.Traditional.Workflow.install_agent_error("Remote session ended")
      |> MingaEditor.Shell.Traditional.NoticeWorkflow.publish("Remote session ended")
    else
      state
    end
  end

  defp restore_ended_remote_workspace(state, %Workspace{}, _messages), do: state

  @spec restore_remote_workspace(EditorState.t(), Workspace.t(), node(), pid()) :: EditorState.t()
  defp restore_remote_workspace(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         %Workspace{
           id: workspace_id,
           remote_session: %RemoteSession{session_id: session_id, last_seen_event_id: last_seen}
         } = workspace,
         remote_node,
         pid
       ) do
    case remote_api_attach(remote_node, session_id, last_seen) do
      {:ok,
       %{
         role: :driver,
         messages: messages,
         snapshot: snapshot,
         events: events,
         latest_event_id: latest_event_id
       }} ->
        if active_workspace?(tb, workspace_id) do
          tb = set_workspace_remote_state(tb, workspace, pid, :connected, latest_event_id)

          state = install_tab_bar(state, tb)

          state
          |> maybe_rebuild_agent_from_workspace(workspace_id)
          |> sync_reconnected_buffer(messages)
          |> EventReplay.replay_active(events)
          |> apply_reconnected_snapshot(snapshot)
        else
          tb =
            tb
            |> set_workspace_remote_state(workspace, pid, :connected, latest_event_id)
            |> TabBar.update_workspace(
              workspace_id,
              &Workspace.set_pending_catchup_events(&1, events)
            )

          install_tab_bar(state, tb)
        end

      {:error, _reason} ->
        mark_remote_workspace_status(state, workspace, :disconnected)
    end
  catch
    :exit, _reason -> mark_remote_workspace_status(state, workspace, :disconnected)
  end

  defp restore_remote_workspace(state, %Workspace{}, _remote_node, _pid), do: state

  @spec install_tab_bar(EditorState.t(), TabBar.t()) :: EditorState.t()
  defp install_tab_bar(%EditorState{} = state, %TabBar{} = tab_bar) do
    shell_state =
      MingaEditor.Shell.Traditional.State.install_tab_bar(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        tab_bar
      )

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  @spec mark_remote_tabs(EditorState.t(), String.t(), Tab.connection_status()) :: EditorState.t()
  defp mark_remote_tabs(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         server_name,
         status
       ) do
    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.install_tab_bar(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          MingaEditor.State.TabBar.set_remote_connection_status(tb, server_name, status)
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
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
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         %Workspace{} = workspace,
         status
       ) do
    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.install_tab_bar(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          set_workspace_remote_state(tb, workspace, workspace.session, status)
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
  end

  defp mark_remote_workspace_status(state, %Workspace{}, _status), do: state

  @spec mark_remote_workspace_without_live_session(
          EditorState.t(),
          Workspace.t(),
          :unavailable
        ) :: EditorState.t()
  defp mark_remote_workspace_without_live_session(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         %Workspace{} = workspace,
         status
       ) do
    then(state, fn root ->
      shell_state =
        MingaEditor.Shell.Traditional.State.install_tab_bar(
          MingaEditor.Shell.Runtime.state(root.shell_runtime),
          set_workspace_remote_state(tb, workspace, nil, status)
        )

      %{
        root
        | shell_runtime:
            MingaEditor.Shell.Runtime.install_traditional_state(root.shell_runtime, shell_state)
      }
    end)
  end

  defp mark_remote_workspace_without_live_session(state, %Workspace{}, _status), do: state

  @spec set_workspace_remote_state(
          TabBar.t(),
          Workspace.t(),
          pid() | nil,
          RemoteSession.connection_status(),
          non_neg_integer() | nil
        ) ::
          TabBar.t()
  defp set_workspace_remote_state(
         %TabBar{} = tb,
         %Workspace{id: workspace_id},
         session,
         status,
         latest_event_id \\ nil
       ) do
    tb
    |> TabBar.update_workspace(workspace_id, fn workspace ->
      workspace
      |> set_workspace_live_session(session)
      |> Workspace.set_remote_connection_status(status)
      |> maybe_set_remote_last_seen_event_id(latest_event_id)
    end)
    |> TabBar.sync_workspace_agent_tab_projection(workspace_id)
  end

  @spec maybe_set_remote_last_seen_event_id(Workspace.t(), non_neg_integer() | nil) ::
          Workspace.t()
  defp maybe_set_remote_last_seen_event_id(
         %Workspace{remote_session: %RemoteSession{} = remote_session} = workspace,
         event_id
       )
       when is_integer(event_id) and event_id >= 0 do
    Workspace.set_remote_session(
      workspace,
      RemoteSession.set_last_seen_event_id(remote_session, event_id)
    )
  end

  defp maybe_set_remote_last_seen_event_id(%Workspace{} = workspace, _event_id), do: workspace

  @spec set_workspace_live_session(Workspace.t(), pid() | nil) :: Workspace.t()
  defp set_workspace_live_session(%Workspace{} = workspace, nil),
    do: Workspace.clear_session(workspace)

  defp set_workspace_live_session(%Workspace{} = workspace, session) when is_pid(session) do
    Workspace.set_session(workspace, session)
  end

  @spec sync_reconnected_buffer(EditorState.t(), [term()]) :: EditorState.t()
  defp sync_reconnected_buffer(state, messages) do
    AgentLifecycle.cache_messages(state, messages)
  end

  @spec apply_reconnected_snapshot(EditorState.t(), MingaAgent.Session.editor_snapshot()) ::
          EditorState.t()
  defp apply_reconnected_snapshot(state, snapshot) do
    agent = MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state)

    updated_agent =
      AgentState.apply_session_snapshot(
        agent,
        Map.get(snapshot, :status, :idle),
        Map.get(snapshot, :pending_approval),
        Map.get(snapshot, :error),
        Map.get(snapshot, :active_tool_name)
      )

    MingaEditor.Shell.Traditional.Workflow.install_agent_state(state, updated_agent)
  end

  @spec maybe_rebuild_agent_from_workspace(EditorState.t(), non_neg_integer()) :: EditorState.t()
  defp maybe_rebuild_agent_from_workspace(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         workspace_id
       ) do
    case workspace_agent_tab(tb, workspace_id) do
      %Tab{} = tab -> MingaEditor.AgentLifecycle.rebuild_agent_from_session(state, tab)
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
  defp active_remote_server?(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}}, server_name) do
    case TabBar.active_workspace(tb) do
      %Workspace{} = workspace -> Workspace.remote_server?(workspace, server_name)
      _workspace -> false
    end
  end

  defp active_remote_server?(%EditorState{} = state, server_name) do
    case Runtime.active_tab(state.shell_runtime) do
      %Tab{server_name: ^server_name} -> true
      _ -> false
    end
  end
end
