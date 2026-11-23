defmodule MingaEditor.Commands.AgentSession do
  @moduledoc """
  Agent session lifecycle commands.

  Handles starting, restarting, subscribing to, and opening code blocks
  from agent sessions. Extracted from `Commands.Agent` to reduce module size.
  """

  alias MingaAgent.ProjectView
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaAgent.Session
  alias Minga.Buffer
  alias MingaEditor.Agent.CatalogStartup
  alias MingaEditor.Agent.SessionStart
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.HighlightSync
  alias MingaEditor.Remote.EventReplay
  alias MingaEditor.Remote.SessionClient
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.RemoteSession
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Agent
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent
  alias MingaEditor.State.TabBar

  @type state :: EditorState.t()

  # ── Session lifecycle ──────────────────────────────────────────────────────

  @doc """
  Stops the current session and restarts if the panel is visible.

  Traditional-shell only: restart cycles the session pid on the active tab. Extension shells may own their own per-surface lifecycle, so a generic "restart" without shell-specific context is not meaningful there. Extension callers go through their active shell's session-start callback for new sessions and rely on `:agent_session_stopped` events for cleanup.
  """
  @spec restart_session(state(), String.t()) :: state()
  def restart_session(
        %EditorState{shell_runtime: %Runtime{entry: %Entry{id: :traditional}}} = state,
        message
      ) do
    session = MingaEditor.Shell.Runtime.active_session(state.shell_runtime)

    if session do
      try do
        MingaAgent.SessionManager.stop_session_by_pid(session)
      catch
        :exit, _ -> :ok
      end
    end

    state = state |> clear_restart_session(session) |> reset_agent_cache()
    state = NoticeWorkflow.publish(state, message)
    if state.workspace.agent_ui.panel.visible, do: start_agent_session(state), else: state
  end

  def restart_session(state, _message) do
    NoticeWorkflow.publish(
      state,
      "Session restart is not supported on this shell"
    )
  end

  @spec clear_restart_session(state(), pid() | nil) :: state()
  defp clear_restart_session(state, nil), do: state

  defp clear_restart_session(
         %EditorState{shell_runtime: %Runtime{state: %{tab_bar: %TabBar{} = tb}}} = state,
         session
       ) do
    tb = clear_workspace_sessions(tb, session)

    shell_state =
      MingaEditor.Shell.Traditional.State.install_tab_bar(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        tb
      )

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  defp clear_restart_session(state, _session), do: state

  @spec clear_workspace_sessions(TabBar.t(), pid()) :: TabBar.t()
  defp clear_workspace_sessions(%TabBar{} = tb, session) do
    Enum.reduce(tb.workspaces, tb, fn
      %Workspace{id: workspace_id, payload: %WorkspaceAgent{session: ^session}}, acc ->
        TabBar.clear_workspace_session(acc, workspace_id)

      _workspace, acc ->
        acc
    end)
  end

  @spec reset_agent_cache(state()) :: state()
  defp reset_agent_cache(state) do
    MingaEditor.Shell.Traditional.Workflow.install_agent_cache_reset(state)
  end

  @doc """
  Shows the active Agent tab and composer in the `:starting` state and starts its session without waiting.

  The tab is bound to an agent workspace first, so the start request knows where its session belongs even if the user switches away. A second call while that workspace's start is in flight does nothing. Options: `:session_start_hook_enabled?`, `:recover_interrupted_work?`, and `:follow_up`, work that runs once the session is bound (see `MingaEditor.Agent.SessionStart`).
  """
  @spec start_agent_session(state()) :: state()
  @spec start_agent_session(state(), keyword()) :: state()
  def start_agent_session(state, opts \\ []) do
    {state, workspace_id} = starting_workspace(state)

    if SessionStart.pending?(state, workspace_id) do
      state
    else
      state
      |> TraditionalWorkflow.install_agent_ui(
        UIState.transition_chat(state.workspace.agent_ui, :starting)
      )
      |> CatalogStartup.continue(
        {:start, Keyword.get(opts, :session_start_hook_enabled?, true),
         Keyword.get(opts, :recover_interrupted_work?, true), Keyword.get(opts, :follow_up)}
      )
    end
  end

  @doc "Sends the start request for the active Agent tab once the model catalog is ready."
  @spec start_catalog_ready(state(), boolean(), boolean(), SessionStart.follow_up()) :: state()
  def start_catalog_ready(state, hooks?, recover?, follow_up) do
    Minga.Telemetry.span([:minga, :agent, :start_agent_session], %{}, fn ->
      do_start_agent_session(state, hooks?, recover?, follow_up)
    end)
  end

  @type catalog_start_result ::
          {:ready, boolean(), boolean(), SessionStart.follow_up()} | {:failed, String.t()}

  @doc "Starts a deferred session for the exact inactive Agent tab without changing focus."
  @spec complete_inactive_start(
          state(),
          {Tab.id() | nil, Tab.group_id() | nil, pid() | nil},
          catalog_start_result()
        ) :: {:ok, state()} | :stale
  def complete_inactive_start(
        %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tabs}}} = state,
        {tab_id, workspace_id, nil},
        result
      )
      when is_integer(tab_id) and is_integer(workspace_id) and workspace_id > 0 do
    if SessionStart.pending?(state, workspace_id),
      do: :stale,
      else: complete_idle_inactive_start(state, tabs, tab_id, workspace_id, result)
  end

  def complete_inactive_start(_state, _target, _result), do: :stale

  @spec complete_idle_inactive_start(
          state(),
          TabBar.t(),
          Tab.id(),
          pos_integer(),
          catalog_start_result()
        ) :: {:ok, state()} | :stale
  defp complete_idle_inactive_start(state, tabs, tab_id, workspace_id, result) do
    with %Tab{kind: :agent, group_id: ^workspace_id, payload: %Agent{session: nil}} <-
           TabBar.get(tabs, tab_id),
         %Workspace{payload: %WorkspaceAgent{session: nil, remote_session: nil}} = workspace <-
           TabBar.get_workspace(tabs, workspace_id),
         {location, %UIState{chat_lifecycle: :starting} = ui} <-
           startup_ui(state, tabs, workspace) do
      ui = prepare_workspace_start(state, ui, result)

      {:ok,
       state
       |> install_workspace_start_ui(tabs, workspace, location, ui)
       |> request_workspace_start(workspace, ui, result)}
    else
      _stale -> :stale
    end
  end

  @spec startup_ui(state(), TabBar.t(), Workspace.agent()) ::
          {:current | :stored, UIState.t() | nil}
  defp startup_ui(state, tabs, %Workspace{id: id, payload: %WorkspaceAgent{agent_ui: stored}}) do
    if TabBar.active_workspace_id(tabs) == id,
      do: {:current, state.workspace.agent_ui},
      else: {:stored, stored}
  end

  @spec prepare_workspace_start(state(), UIState.t(), catalog_start_result()) :: UIState.t()
  defp prepare_workspace_start(state, ui, {:ready, _hooks?, _recover?, _follow_up}) do
    UIState.replace_panel(
      ui,
      Panel.ensure_configured_model(ui.panel, state.interaction.options_server)
    )
  end

  defp prepare_workspace_start(_state, ui, {:failed, reason}) do
    Minga.Log.error(:agent, "[Agent] #{reason}")
    UIState.transition_chat(ui, {:failed, reason})
  end

  @spec install_workspace_start_ui(
          state(),
          TabBar.t(),
          Workspace.agent(),
          :current | :stored,
          UIState.t()
        ) :: state()
  defp install_workspace_start_ui(state, tabs, workspace, :current, ui) do
    state
    |> MingaEditor.WorkspaceWorkflow.install_tab_bar(
      TabBar.accept_workspace(tabs, Workspace.set_agent_ui(workspace, nil))
    )
    |> TraditionalWorkflow.install_agent_ui(ui)
  end

  defp install_workspace_start_ui(state, tabs, workspace, :stored, ui) do
    MingaEditor.WorkspaceWorkflow.install_tab_bar(
      state,
      TabBar.accept_workspace(tabs, Workspace.set_agent_ui(workspace, ui))
    )
  end

  @spec request_workspace_start(state(), Workspace.agent(), UIState.t(), catalog_start_result()) ::
          state()
  defp request_workspace_start(state, workspace, ui, {:ready, hooks?, recover?, follow_up}) do
    root = workspace.project_root
    project_view = session_project_view(workspace, root)
    opts = session_start_opts(state, ui.panel, elem(project_view, 0), root, hooks?, recover?)
    SessionStart.request(state, workspace.id, opts, project_view, follow_up)
  end

  defp request_workspace_start(state, _workspace, _ui, {:failed, _reason}), do: state

  @doc "Shows a startup failure in the active Agent tab and keeps its draft."
  @spec startup_failed(state(), String.t()) :: state()
  def startup_failed(state, message) when is_binary(message) do
    Minga.Log.error(:agent, "[Agent] #{message}")

    state
    |> TraditionalWorkflow.install_agent_ui(
      UIState.transition_chat(state.workspace.agent_ui, {:failed, message})
    )
    |> TraditionalWorkflow.install_agent_error(message)
  end

  # The panel takes its model from configuration only (#3641). With no
  # configured model it reads "Resolving model…" until the session's
  # connection reports the model the session resolved.
  @spec do_start_agent_session(state(), boolean(), boolean(), SessionStart.follow_up()) ::
          state()
  defp do_start_agent_session(state, hooks?, recover?, follow_up) do
    panel =
      Minga.Telemetry.span([:minga, :agent, :ensure_configured_model], %{}, fn ->
        Panel.ensure_configured_model(
          state.workspace.agent_ui.panel,
          state.interaction.options_server
        )
      end)

    state = TraditionalWorkflow.install_agent_panel(state, panel)

    case starting_workspace(state) do
      {state, workspace_id} when is_integer(workspace_id) and workspace_id > 0 ->
        {project_view, _created?} = view = session_project_view(state)
        root = state.workspace.file_tree.project_root
        opts = session_start_opts(state, panel, project_view, root, hooks?, recover?)
        SessionStart.request(state, workspace_id, opts, view, follow_up)

      {state, _no_agent_workspace} ->
        startup_failed(state, "No Agent workspace to start the session in.")
    end
  end

  # The agent workspace the start binds to, created when needed: the active
  # Agent workspace, else the sessionless Agent tab's workspace when the start
  # runs in the background. The request is sent with this identity, so the
  # reply binds there even if the user has moved elsewhere.
  @spec starting_workspace(state()) :: {state(), non_neg_integer() | nil}
  defp starting_workspace(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tabs}}} = state) do
    case {TabBar.active_workspace(tabs), background_agent_workspace(tabs)} do
      {%Workspace{id: id, kind: :agent, payload: %WorkspaceAgent{remote_session: nil}}, _} ->
        {state, id}

      {_active, id} when is_integer(id) ->
        {state, id}

      {_active, nil} ->
        create_agent_workspace(state, tabs)
    end
  end

  defp starting_workspace(state), do: {state, nil}

  @spec background_agent_workspace(TabBar.t()) :: pos_integer() | nil
  defp background_agent_workspace(tabs) do
    with %Tab{group_id: id} when id > 0 <- TabBar.find_sessionless_agent(tabs),
         %Workspace{kind: :agent, payload: %WorkspaceAgent{session: nil}} <-
           TabBar.get_workspace(tabs, id) do
      id
    else
      _none -> nil
    end
  end

  @spec session_start_opts(
          state(),
          Panel.t(),
          ProjectView.t() | nil,
          String.t() | nil,
          boolean(),
          boolean()
        ) ::
          keyword()
  defp session_start_opts(state, panel, project_view, root, hooks?, recover?) do
    [
      thinking_level: panel.thinking_level,
      model_name: panel.model_name,
      provider_name: panel.provider_name,
      session_start_hook_enabled?: hooks?,
      recover_interrupted_work?: recover?,
      provider_opts: provider_opts(state, panel, project_view, root)
    ]
    |> maybe_put_provider_module(state.agent_connection.agent_provider_module)
  end

  @doc "Connects the local GUI to an existing remote agent session."
  @spec connect_remote_session(
          state(),
          String.t(),
          String.t(),
          pid(),
          String.t(),
          non_neg_integer()
        ) ::
          state()
  def connect_remote_session(
        state,
        server_name,
        session_id,
        remote_pid,
        token,
        last_seen_event_id \\ 0
      )
      when is_binary(server_name) and is_binary(session_id) and is_pid(remote_pid) and
             is_binary(token) and is_integer(last_seen_event_id) and last_seen_event_id >= 0 do
    case remote_attach(remote_pid, session_id, token, last_seen_event_id) do
      {:ok, messages, snapshot, events, latest_event_id} ->
        {state, tab_id} = insert_remote_agent_tab(state, remote_pid)

        state =
          state
          |> set_remote_workspace(
            server_name,
            session_id,
            remote_pid,
            :connected,
            latest_event_id
          )
          |> MingaEditor.TabWorkflow.switch(tab_id)
          |> AgentLifecycle.cache_messages(messages)
          |> EventReplay.replay_active(remote_pid, events)
          |> apply_remote_snapshot(remote_pid, snapshot)
          |> then(&MingaEditor.WorkspaceWorkflow.persist_changes(state, &1))

        NoticeWorkflow.publish(
          state,
          "Connected to #{server_name} session #{session_id}"
        )

      {:error, reason} ->
        NoticeWorkflow.publish(
          state,
          "Remote session unavailable: #{inspect(reason)}"
        )
    end
  end

  @doc "Starts a new agent session on a connected remote server and opens it locally."
  @spec start_remote_session(state(), String.t()) :: state()
  def start_remote_session(state, server_name) when is_binary(server_name) do
    case Minga.Distribution.ConnectionManager.node_for_server(server_name) do
      {:ok, remote_node} ->
        start_remote_session_on_node(state, server_name, remote_node)

      {:error, :disconnected} ->
        NoticeWorkflow.publish(
          state,
          "Remote server #{server_name} is disconnected"
        )

      {:error, :not_found} ->
        NoticeWorkflow.publish(
          state,
          "Unknown remote server #{server_name}"
        )
    end
  end

  @doc "Sends a prompt to a local or remote session, enforcing the remote broker boundary."
  @spec send_prompt_pid(pid(), String.t() | [ReqLLM.Message.ContentPart.t()]) ::
          :ok | {:queued, :steering} | {:error, term()}
  def send_prompt_pid(session, prompt) when is_pid(session) and node(session) == node() do
    Session.send_prompt(session, prompt)
  end

  def send_prompt_pid(session, prompt) when is_pid(session) do
    SessionClient.send_prompt(session, prompt)
  end

  @doc "Resolves the exact displayed tool approval through the local or remote session boundary."
  @spec respond_to_approval_pid(pid(), Session.approval_target(), Session.approval_decision()) ::
          :ok | {:error, term()}
  def respond_to_approval_pid(session, %MingaAgent.ToolApproval.Target{} = target, decision)
      when is_pid(session) and node(session) == node() do
    # Foreground Ingest holds the driver subscription.
    # Local Editor decisions use the trusted entry point, which validates the full target atomically.
    Session.respond_to_approval(session, target, decision)
  catch
    :exit, reason -> {:error, {:session_unavailable, reason}}
  end

  def respond_to_approval_pid(session, %MingaAgent.ToolApproval.Target{} = target, decision)
      when is_pid(session) do
    SessionClient.approve(session, target, decision)
  end

  @doc "Stops a session pid, routing remote pids to their owning node."
  @spec stop_session_pid(pid()) :: :ok | {:error, term()}
  def stop_session_pid(session) when is_pid(session) and node(session) == node() do
    MingaAgent.SessionManager.stop_session_by_pid(session)
  catch
    :exit, reason -> {:error, reason}
  end

  def stop_session_pid(session) when is_pid(session) do
    SessionClient.stop_session_pid(session)
  end

  @doc "Detaches from the current remote agent session without stopping it."
  @spec detach_current_remote_session(state()) :: state()
  def detach_current_remote_session(state) do
    case MingaEditor.Shell.Runtime.active_session(state.shell_runtime) do
      session when is_pid(session) and node(session) != node() ->
        detach_remote_session(state, session)

      _other ->
        NoticeWorkflow.publish(state, "No attached remote session")
    end
  catch
    :exit, reason ->
      NoticeWorkflow.publish(
        state,
        "Failed to detach remote session: #{inspect(reason)}"
      )
  end

  @doc "Stops the current agent session, routing remote sessions to their remote manager."
  @spec stop_current_session(state()) :: state()
  def stop_current_session(state) do
    case MingaEditor.Shell.Runtime.active_session(state.shell_runtime) do
      nil ->
        state

      session when node(session) == node() ->
        MingaAgent.SessionManager.stop_session_by_pid(session)
        state

      session ->
        stop_remote_session(state, session)
    end
  catch
    :exit, reason ->
      NoticeWorkflow.publish(
        state,
        "Failed to stop session: #{inspect(reason)}"
      )
  end

  # ── Code block helpers ─────────────────────────────────────────────────────

  @doc """
  Opens a code block from an agent chat message as an unnamed buffer.

  Creates a new buffer with the code block content, sets its filetype
  based on the language tag, and displays it in the preview pane.
  """
  @spec open_code_block(state(), String.t(), String.t()) :: state()
  def open_code_block(state, language, content) do
    name = buffer_name_for_language(language)
    filetype = filetype_from_language(language)
    old_buffer = state.workspace.buffers.active

    case Buffer.start_link(
           content: content,
           buffer_name: name,
           filetype: filetype,
           options_server: state.interaction.options_server
         ) do
      {:ok, buf} ->
        buffers = MingaEditor.State.Buffers.set_active_override(state.workspace.buffers, buf)
        workspace = MingaEditor.Session.State.set_buffers(state.workspace, buffers)

        %{state | workspace: workspace}
        |> maybe_log_code_block_opened(language)
        |> HighlightSync.ensure_active_buffer_presentation(old_buffer)

      {:error, reason} ->
        NoticeWorkflow.publish(
          state,
          "Failed to open code block: #{inspect(reason)}"
        )
    end
  end

  @spec maybe_log_code_block_opened(state(), String.t()) :: state()
  defp maybe_log_code_block_opened(state, language) do
    case MingaEditor.Shell.Runtime.active_session(state.shell_runtime) do
      nil ->
        state

      session ->
        Session.add_system_message(
          session,
          "Opened #{code_block_language_label(language)} code block in buffer"
        )

        state
    end
  end

  @spec code_block_language_label(String.t()) :: String.t()
  defp code_block_language_label(""), do: "text"
  defp code_block_language_label(language), do: language

  @doc "Formats a session start error into a user-facing message."
  @spec format_session_error(term()) :: String.t()
  def format_session_error({:noproc, _}), do: "Agent supervisor not running"
  def format_session_error(reason), do: "Failed to start session: #{inspect(reason)}"

  # ── Private helpers ────────────────────────────────────────────────────────

  @spec start_remote_session_on_node(state(), String.t(), node()) :: state()
  defp start_remote_session_on_node(state, server_name, remote_node) do
    case remote_start_session(remote_node, remote_session_opts(state)) do
      {:ok, session_id, remote_pid, token} ->
        connect_remote_session(state, server_name, session_id, remote_pid, token)

      {:error, reason} ->
        NoticeWorkflow.publish(
          state,
          "Failed to start remote session: #{inspect(reason)}"
        )
    end
  end

  @spec remote_session_opts(state()) :: keyword()
  defp remote_session_opts(state) do
    panel = state.workspace.agent_ui.panel
    [thinking_level: panel.thinking_level]
  end

  @spec remote_start_session(node(), keyword()) ::
          {:ok, String.t(), pid(), String.t()} | {:error, term()}
  defp remote_start_session(remote_node, opts) do
    case SessionClient.start_session(remote_node, opts) do
      {:ok, %{session_id: session_id, pid: pid, token: token}} -> {:ok, session_id, pid, token}
      {:error, _reason} = error -> error
    end
  end

  @spec remote_attach(pid(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, [term()], map(), [term()], non_neg_integer()} | {:error, term()}
  defp remote_attach(remote_pid, session_id, token, last_seen_event_id) do
    case SessionClient.attach_driver(
           node(remote_pid),
           session_id,
           token,
           last_seen_event_id,
           self()
         ) do
      {:ok,
       %{
         role: :driver,
         messages: messages,
         snapshot: snapshot,
         events: events,
         latest_event_id: latest_event_id
       }} ->
        {:ok, messages, snapshot, events, latest_event_id}

      {:error, _reason} = error ->
        error
    end
  end

  @spec insert_remote_agent_tab(state(), pid()) :: {state(), Tab.id()}
  defp insert_remote_agent_tab(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         session
       ) do
    {tb, tab} =
      MingaEditor.TabWorkflow.insert_agent(
        tb,
        "Agent",
        state.frontend.terminal_viewport,
        state.workspace.file_tree.project_root
      )

    {tb, workspace} =
      case TabBar.find_workspace_by_session(tb, session) do
        %Workspace{} = existing -> {tb, existing}
        nil -> TabBar.add_workspace(tb, "Agent", session)
      end

    tb = TabBar.move_tab_to_workspace(tb, tab.id, workspace.id)

    shell_state =
      MingaEditor.Shell.Traditional.State.install_tab_bar(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        tb
      )

    state = %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }

    {state, tab.id}
  end

  defp insert_remote_agent_tab(state, _session) do
    {state, 0}
  end

  @spec set_remote_workspace(
          state(),
          String.t(),
          String.t(),
          pid(),
          RemoteSession.connection_status(),
          non_neg_integer()
        ) :: state()
  defp set_remote_workspace(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         server_name,
         session_id,
         remote_pid,
         status,
         latest_event_id
       ) do
    case TabBar.find_workspace_by_session(tb, remote_pid) do
      %Workspace{id: workspace_id} ->
        workspace = TabBar.get_workspace(tb, workspace_id)

        workspace =
          workspace
          |> Workspace.set_session(remote_pid)
          |> Workspace.put_remote_session(server_name, session_id, status, latest_event_id)

        tb = TabBar.accept_workspace(tb, workspace)

        shell_state =
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Runtime.state(state.shell_runtime),
            tb
          )

        %{
          state
          | shell_runtime:
              MingaEditor.Shell.Runtime.install_traditional_state(
                state.shell_runtime,
                shell_state
              )
        }

      nil ->
        state
    end
  end

  defp set_remote_workspace(
         state,
         _server_name,
         _session_id,
         _remote_pid,
         _status,
         _latest_event_id
       ),
       do: state

  @spec apply_remote_snapshot(state(), pid(), Session.editor_snapshot()) :: state()
  defp apply_remote_snapshot(
         state,
         session_pid,
         %{
           status: _status,
           pending_approval: _pending_approval,
           error: _error
         } = snapshot
       ) do
    AgentLifecycle.apply_session_snapshot(state, session_pid, snapshot)
  end

  @spec detach_remote_session(state(), pid()) :: state()
  defp detach_remote_session(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         session
       ) do
    case TabBar.find_by_session(tb, session) do
      %Tab{payload: %Agent{remote_session_id: session_id}} when is_binary(session_id) ->
        case detach_remote_session_by_id(state, session, session_id) do
          :ok ->
            state
            |> MingaEditor.Agent.QuestionResponse.retire_remote_attachment(session)
            |> clear_restart_session(session)
            |> mark_remote_session_disconnected(session_id)
            |> NoticeWorkflow.publish("Detached remote session #{session_id}")

          {:error, reason} ->
            NoticeWorkflow.publish(
              state,
              "Failed to detach remote session: #{inspect(reason)}"
            )
        end

      _ ->
        NoticeWorkflow.publish(
          state,
          "Remote session id is unavailable"
        )
    end
  end

  defp detach_remote_session(state, _session), do: state

  @spec detach_remote_session_by_id(state(), pid(), String.t()) :: :ok | {:error, term()}
  defp detach_remote_session_by_id(state, session, session_id) do
    authority = MingaEditor.Agent.QuestionResponse.remote_authority(state, session, self())
    detach = fn remote_node, id -> SessionClient.detach(remote_node, id, authority) end
    Process.get(:minga_editor_remote_detach, detach).(node(session), session_id)
  end

  @spec mark_remote_session_disconnected(state(), String.t()) :: state()
  defp mark_remote_session_disconnected(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         session_id
       ) do
    tb =
      Enum.reduce(tb.workspaces, tb, fn
        %Workspace{
          id: workspace_id,
          payload: %WorkspaceAgent{remote_session: %{session_id: ^session_id}}
        },
        acc ->
          TabBar.set_workspace_remote_connection_status(acc, workspace_id, :disconnected)

        _workspace, acc ->
          acc
      end)

    shell_state =
      MingaEditor.Shell.Traditional.State.install_tab_bar(
        MingaEditor.Shell.Runtime.state(state.shell_runtime),
        tb
      )

    %{
      state
      | shell_runtime:
          MingaEditor.Shell.Runtime.install_traditional_state(state.shell_runtime, shell_state)
    }
  end

  defp mark_remote_session_disconnected(state, _session_id), do: state

  @spec stop_remote_session(state(), pid()) :: state()
  defp stop_remote_session(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         session
       ) do
    case TabBar.find_by_session(tb, session) do
      %Tab{payload: %Agent{remote_session_id: session_id}} when is_binary(session_id) ->
        case stop_remote_session_by_id(node(session), session_id) do
          :ok ->
            state

          {:error, reason} ->
            NoticeWorkflow.publish(
              state,
              "Failed to stop remote session: #{inspect(reason)}"
            )
        end

      _ ->
        NoticeWorkflow.publish(
          state,
          "Remote session id is unavailable"
        )
    end
  catch
    :exit, reason ->
      NoticeWorkflow.publish(
        state,
        "Remote server unavailable: #{inspect(reason)}"
      )
  end

  defp stop_remote_session(state, _session), do: state

  @spec stop_remote_session_by_id(node(), String.t()) :: :ok | {:error, term()}
  defp stop_remote_session_by_id(remote_node, session_id) do
    SessionClient.stop_session(remote_node, session_id)
  end

  @spec buffer_name_for_language(String.t()) :: String.t()
  defp buffer_name_for_language(""), do: "*Agent: text*"
  defp buffer_name_for_language(lang), do: "*Agent: #{lang}*"

  @spec filetype_from_language(String.t()) :: atom() | nil
  defp filetype_from_language(""), do: nil

  defp filetype_from_language(lang) do
    mapping = %{
      "elixir" => :elixir,
      "ex" => :elixir,
      "exs" => :elixir,
      "javascript" => :javascript,
      "js" => :javascript,
      "typescript" => :typescript,
      "ts" => :typescript,
      "python" => :python,
      "py" => :python,
      "ruby" => :ruby,
      "rb" => :ruby,
      "rust" => :rust,
      "rs" => :rust,
      "go" => :go,
      "golang" => :go,
      "zig" => :zig,
      "c" => :c,
      "cpp" => :cpp,
      "c++" => :cpp,
      "java" => :java,
      "json" => :json,
      "yaml" => :yaml,
      "yml" => :yaml,
      "toml" => :toml,
      "html" => :html,
      "css" => :css,
      "lua" => :lua,
      "bash" => :bash,
      "sh" => :bash,
      "shell" => :bash,
      "zsh" => :bash,
      "sql" => :sql,
      "markdown" => :markdown,
      "md" => :markdown,
      "xml" => :xml,
      "dockerfile" => :dockerfile,
      "docker" => :dockerfile,
      "makefile" => :makefile,
      "make" => :makefile
    }

    Map.get(mapping, String.downcase(lang))
  end

  @spec provider_opts(state(), Panel.t(), ProjectView.t() | nil, String.t() | nil) :: keyword()
  defp provider_opts(state, panel, project_view, root) do
    state.agent_connection.agent_provider_opts
    |> Keyword.merge(
      provider: panel.provider_name,
      model: panel.model_name,
      project_view: project_view
    )
    |> put_session_project_root(session_project_root(project_view, root))
  end

  # The session works on the project the editor shows, never the launch
  # directory. A project view already carries that root; without one, the
  # editor's project root is passed explicitly.
  @spec session_project_root(ProjectView.t() | nil, String.t() | nil) :: String.t() | nil
  defp session_project_root(%ProjectView{project_root: root}, _fallback), do: root
  defp session_project_root(nil, root), do: root

  @spec put_session_project_root(keyword(), String.t() | nil) :: keyword()
  defp put_session_project_root(opts, root) when is_binary(root),
    do: Keyword.put(opts, :project_root, root)

  defp put_session_project_root(opts, nil), do: opts

  @spec maybe_put_provider_module(keyword(), module() | nil) :: keyword()
  defp maybe_put_provider_module(opts, provider_module)
       when is_atom(provider_module) and not is_nil(provider_module),
       do: Keyword.put(opts, :provider, provider_module)

  defp maybe_put_provider_module(opts, _provider_module), do: opts

  @spec create_agent_workspace(state(), TabBar.t()) :: {state(), pos_integer()}
  defp create_agent_workspace(state, %TabBar{} = tb) do
    {tb, ws} = TabBar.add_workspace(tb, "Agent")

    tb =
      case TabBar.find_sessionless_agent(tb) do
        %Tab{id: tab_id} = tab ->
          tb
          |> TabBar.move_tab_to_workspace(tab_id, ws.id)
          |> TabBar.update_context(
            tab_id,
            TabContext.put_fields(tab.context, keymap_scope: :agent)
          )

        nil ->
          tb
      end

    tb =
      case TabBar.active_workspace_id(tb) do
        id when id == ws.id -> TabBar.set_workspace_agent_ui(tb, ws.id, nil)
        _workspace_id -> tb
      end

    {MingaEditor.WorkspaceWorkflow.install_tab_bar(state, tb), ws.id}
  end

  @spec workspace_project_view(Workspace.t()) :: ProjectView.t() | nil
  defp workspace_project_view(%Workspace{
         payload: %WorkspaceAgent{project_view: %ProjectView{} = project_view}
       }),
       do: project_view

  defp workspace_project_view(%Workspace{}), do: nil

  @spec session_project_view(state()) :: {ProjectView.t() | nil, boolean()}
  defp session_project_view(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state) do
    session_project_view(TabBar.active_workspace(tb), state.workspace.file_tree.project_root)
  end

  @spec session_project_view(Workspace.t() | nil, String.t() | nil) ::
          {ProjectView.t() | nil, boolean()}
  defp session_project_view(%Workspace{kind: :agent} = workspace, root) do
    if MingaEditor.WorkspaceWorkflow.project_view_active?(workspace),
      do: {workspace_project_view(workspace), false},
      else: project_view_from_root(root)
  end

  defp session_project_view(_workspace, root), do: project_view_from_root(root)

  @spec project_view_from_root(String.t() | nil) :: {ProjectView.t() | nil, boolean()}
  defp project_view_from_root(root) when is_binary(root), do: measured_project_view_overlay(root)
  defp project_view_from_root(nil), do: {nil, false}

  @spec measured_project_view_overlay(String.t()) :: {ProjectView.t() | nil, boolean()}
  defp measured_project_view_overlay(root) do
    Minga.Telemetry.span([:minga, :agent, :project_view_overlay], %{root: root}, fn ->
      project_view_overlay(root)
    end)
  end

  @spec project_view_overlay(String.t()) :: {ProjectView.t() | nil, boolean()}
  defp project_view_overlay(root) do
    case ProjectView.overlay(root) do
      {:ok, project_view} -> {project_view, true}
      {:error, _reason} -> {nil, false}
    end
  end
end
