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
  alias MingaEditor.Agent.StartFailure
  alias MingaEditor.Agent.StartRequest
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
  Shows the starting Agent workspace in the `:starting` state and starts its session without waiting.

  The workspace is resolved once (the active Agent workspace, else a background one with its own Agent tab) and its id travels with the start through the catalog wait, so the reply binds there even if the user switches away. The live UI changes only when that workspace is active; otherwise its stored UI shows the starting state until the user arrives. A second call while that workspace's start is in flight does nothing. Options: `:session_start_hook_enabled?`, `:recover_interrupted_work?`, and `:follow_up`, work that runs once the session is bound (see `MingaEditor.Agent.SessionStart`).
  """
  @spec start_agent_session(state()) :: state()
  @spec start_agent_session(state(), keyword()) :: state()
  def start_agent_session(state, opts \\ []) do
    request =
      StartRequest.new(
        Keyword.get(opts, :session_start_hook_enabled?, true),
        Keyword.get(opts, :recover_interrupted_work?, true),
        Keyword.get(opts, :follow_up)
      )

    case starting_workspace(state) do
      {state, workspace_id} when is_integer(workspace_id) ->
        begin_start(state, workspace_id, request)

      {state, nil} ->
        startup_failed(state, StartFailure.no_workspace(request))
    end
  end

  @doc """
  Runs a failed start again in the active Agent tab, keeping its draft.

  A start that never bound a session runs again with the same request, so the tab returns to Starting. A session whose provider failed retries that provider on the same session; the session's connection events move the tab back to Starting. Any other lifecycle is left unchanged. Unlike a new session, nothing is reset.
  """
  @spec retry_start(state()) :: state()
  def retry_start(state) do
    case active_start_failure(state) do
      {workspace_id, %StartFailure{remedy: {:retry, %StartRequest{} = request}}} ->
        begin_start(state, workspace_id, request)

      {_workspace_id, %StartFailure{remedy: {:retry, :provider}}} ->
        MingaEditor.Agent.ConnectionAction.schedule_current(state, :retry)

      _not_retryable ->
        state
    end
  end

  @doc """
  Runs the remedy the active tab's failed start offers: a retry runs `retry_start/1`, a setup opens the model and provider picker. Any other lifecycle is left unchanged. The draft is never touched or sent.
  """
  @spec run_start_remedy(state()) :: state()
  def run_start_remedy(state) do
    case UIState.start_remedy(state.workspace.agent_ui) do
      :retry -> retry_start(state)
      :set_up_provider -> MingaEditor.UI.Picker.AgentModelSource.open(state)
      nil -> state
    end
  end

  @spec active_start_failure(state()) :: {pos_integer(), StartFailure.t()} | nil
  defp active_start_failure(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tabs}}} = state) do
    case {TabBar.active_workspace(tabs), UIState.start_failure(state.workspace.agent_ui)} do
      {%Workspace{id: id, kind: :agent, payload: %WorkspaceAgent{remote_session: nil}},
       %StartFailure{} = failure} ->
        {id, failure}

      _other ->
        nil
    end
  end

  defp active_start_failure(_state), do: nil

  @spec begin_start(state(), pos_integer(), StartRequest.t()) :: state()
  defp begin_start(state, workspace_id, %StartRequest{} = request) do
    if SessionStart.pending?(state, workspace_id) do
      state
    else
      state
      |> update_workspace_ui(workspace_id, &UIState.transition_chat(&1, :starting))
      |> CatalogStartup.continue(
        {:start, workspace_id, request.hooks?, request.recover?, request.follow_up}
      )
    end
  end

  @doc "Sends the start request for the agent workspace `workspace_id` once the model catalog is ready."
  @spec start_catalog_ready(
          state(),
          pos_integer(),
          boolean(),
          boolean(),
          SessionStart.follow_up()
        ) :: state()
  def start_catalog_ready(state, workspace_id, hooks?, recover?, follow_up) do
    Minga.Telemetry.span([:minga, :agent, :start_agent_session], %{}, fn ->
      do_start_agent_session(state, workspace_id, StartRequest.new(hooks?, recover?, follow_up))
    end)
  end

  @type catalog_start_result ::
          {:ready, boolean(), boolean(), SessionStart.follow_up()} | {:failed, StartFailure.t()}

  @doc """
  Finishes a start that waited for the model catalog, in the workspace it was requested for.

  Stale when that workspace is gone, already has a session or a start in flight, or no longer shows the starting chat. Focus never changes.
  """
  @spec complete_deferred_start(state(), pos_integer(), catalog_start_result()) ::
          {:ok, state()} | :stale
  def complete_deferred_start(state, workspace_id, result) do
    if deferred_start_current?(state, workspace_id),
      do: {:ok, finish_deferred_start(state, workspace_id, result)},
      else: :stale
  end

  @spec finish_deferred_start(state(), pos_integer(), catalog_start_result()) :: state()
  defp finish_deferred_start(state, workspace_id, {:ready, hooks?, recover?, follow_up}),
    do: start_catalog_ready(state, workspace_id, hooks?, recover?, follow_up)

  defp finish_deferred_start(state, workspace_id, {:failed, %StartFailure{} = failure}),
    do: workspace_start_failed(state, workspace_id, failure)

  @spec deferred_start_current?(state(), pos_integer()) :: boolean()
  defp deferred_start_current?(state, workspace_id) do
    not SessionStart.pending?(state, workspace_id) and
      match?(
        {%Workspace{payload: %WorkspaceAgent{session: nil, remote_session: nil}},
         %UIState{chat_lifecycle: :starting}},
        workspace_and_ui(state, workspace_id)
      )
  end

  @doc """
  Shows a startup failure in the active Agent tab and keeps its draft.

  The tab shows the failure's cause and remedy. It does not mark the Agent errored; the chat, tab and status bar derive their "needs you" status from the failed lifecycle.
  """
  @spec startup_failed(state(), StartFailure.t()) :: state()
  def startup_failed(state, %StartFailure{} = failure) do
    Minga.Log.error(:agent, "[Agent] #{failure.message}")

    TraditionalWorkflow.install_agent_ui(
      state,
      UIState.fail_start(state.workspace.agent_ui, failure)
    )
  end

  @doc "Shows a startup failure in the starting workspace, live or stored, and keeps its draft."
  @spec workspace_start_failed(state(), pos_integer(), StartFailure.t()) :: state()
  def workspace_start_failed(state, workspace_id, %StartFailure{} = failure) do
    if active_workspace?(state, workspace_id) do
      startup_failed(state, failure)
    else
      Minga.Log.error(:agent, "[Agent] #{failure.message}")
      update_workspace_ui(state, workspace_id, &UIState.fail_start(&1, failure))
    end
  end

  # The panel takes its model from configuration only (#3641). With no
  # configured model it reads "Resolving model…" until the session's
  # connection reports the model the session resolved.
  @spec do_start_agent_session(state(), pos_integer(), StartRequest.t()) :: state()
  defp do_start_agent_session(state, workspace_id, %StartRequest{} = request) do
    case workspace_and_ui(state, workspace_id) do
      {%Workspace{payload: %WorkspaceAgent{remote_session: nil}} = workspace, %UIState{} = ui} ->
        panel =
          Minga.Telemetry.span([:minga, :agent, :ensure_configured_model], %{}, fn ->
            Panel.ensure_configured_model(ui.panel, state.interaction.options_server)
          end)

        state = update_workspace_ui(state, workspace_id, &UIState.replace_panel(&1, panel))
        {project_view, _created?} = view = start_project_view(state, workspace)
        root = start_root(state, workspace)

        opts =
          session_start_opts(
            state,
            panel,
            project_view,
            root,
            request.hooks?,
            request.recover?
          )

        SessionStart.request(state, workspace_id, opts, view, request)

      _gone_or_remote ->
        state
    end
  end

  # The active workspace starts in the project the editor shows; a background
  # workspace starts in its own project, or the editor's when it has none.
  @spec start_project_view(state(), Workspace.agent()) :: {ProjectView.t() | nil, boolean()}
  defp start_project_view(state, %Workspace{id: id} = workspace) do
    if active_workspace?(state, id),
      do: session_project_view(state),
      else: session_project_view(workspace, start_root(state, workspace))
  end

  @spec start_root(state(), Workspace.agent()) :: String.t() | nil
  defp start_root(state, %Workspace{id: id} = workspace) do
    if active_workspace?(state, id),
      do: state.workspace.file_tree.project_root,
      else: workspace.project_root || state.workspace.file_tree.project_root
  end

  # The live UI of the active workspace is on the Editor state; any other
  # workspace keeps its UI stored on the workspace.
  @spec workspace_and_ui(state(), pos_integer()) :: {Workspace.t() | nil, UIState.t() | nil}
  defp workspace_and_ui(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tabs}}} = state, id) do
    case TabBar.get_workspace(tabs, id) do
      %Workspace{kind: :agent, payload: %WorkspaceAgent{agent_ui: stored}} = workspace ->
        ui = if active_workspace?(state, id), do: state.workspace.agent_ui, else: stored
        {workspace, ui}

      _other ->
        {nil, nil}
    end
  end

  defp workspace_and_ui(_state, _id), do: {nil, nil}

  @spec update_workspace_ui(state(), pos_integer(), (UIState.t() -> UIState.t())) :: state()
  defp update_workspace_ui(state, workspace_id, transition) do
    case workspace_and_ui(state, workspace_id) do
      {%Workspace{} = workspace, %UIState{} = ui} ->
        if active_workspace?(state, workspace_id),
          do: TraditionalWorkflow.install_agent_ui(state, transition.(ui)),
          else:
            MingaEditor.WorkspaceWorkflow.install_tab_bar(
              state,
              TabBar.accept_workspace(
                state.shell_runtime.state.tab_bar,
                Workspace.set_agent_ui(workspace, transition.(ui))
              )
            )

      _no_ui ->
        state
    end
  end

  @spec active_workspace?(state(), non_neg_integer()) :: boolean()
  defp active_workspace?(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tabs}}}, id),
    do: TabBar.active_workspace_id(tabs) == id

  defp active_workspace?(_state, _id), do: false

  # The agent workspace the start binds to, resolved once per start and carried
  # through the catalog wait: the active Agent workspace, else the sessionless
  # Agent tab's workspace. With neither, a background workspace is created with
  # its own Agent tab, so a later start finds the same workspace and the user
  # can switch to the conversation.
  @spec starting_workspace(state()) :: {state(), pos_integer() | nil}
  defp starting_workspace(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tabs}}} = state) do
    active_tab = TabBar.active(tabs)

    case TabBar.active_workspace(tabs) do
      %Workspace{id: id, kind: :agent, payload: %WorkspaceAgent{remote_session: nil}} ->
        {state, id}

      _not_agent ->
        # The active unowned Agent tab gets its own workspace; otherwise a
        # background start reuses one a previous start made, or creates one.
        reusable =
          if active_tab && unowned_agent_tab?(active_tab),
            do: nil,
            else: background_agent_workspace(tabs)

        case reusable do
          id when is_integer(id) -> {state, id}
          nil -> create_agent_workspace(state, tabs)
        end
    end
  end

  defp starting_workspace(state), do: {state, nil}

  # A background start reuses only a local workspace a previous start made:
  # never a remote workspace, and never one restored from a saved session
  # (its stored chat is `:unavailable` until the user reopens that conversation).
  @spec background_agent_workspace(TabBar.t()) :: pos_integer() | nil
  defp background_agent_workspace(%TabBar{tabs: tabs} = tab_bar) do
    Enum.find_value(tabs, fn
      %Tab{kind: :agent, group_id: id, payload: %Agent{session: nil}} when id > 0 ->
        if startable_background_workspace?(TabBar.get_workspace(tab_bar, id)), do: id

      _other ->
        nil
    end)
  end

  @spec startable_background_workspace?(Workspace.t() | nil) :: boolean()
  defp startable_background_workspace?(%Workspace{
         kind: :agent,
         payload: %WorkspaceAgent{session: nil, remote_session: nil, agent_ui: ui}
       }),
       do: not match?(%UIState{chat_lifecycle: :unavailable}, ui)

  defp startable_background_workspace?(_workspace), do: false

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

  # A sessionless Agent tab not yet owned by an agent workspace; tabs of other
  # (restored or remote) workspaces are never moved.
  @spec unowned_agent_tab?(Tab.t()) :: boolean()
  defp unowned_agent_tab?(%Tab{kind: :agent, group_id: 0, payload: %Agent{session: nil}}),
    do: true

  defp unowned_agent_tab?(%Tab{}), do: false

  @spec create_agent_workspace(state(), TabBar.t()) :: {state(), pos_integer()}
  defp create_agent_workspace(state, %TabBar{} = tb) do
    {tb, ws} = TabBar.add_workspace(tb, "Agent")
    {tb, tab} = sessionless_agent_tab(state, tb)

    tb =
      tb
      |> TabBar.move_tab_to_workspace(tab.id, ws.id)
      |> TabBar.update_context(tab.id, TabContext.put_fields(tab.context, keymap_scope: :agent))

    tb =
      case TabBar.active_workspace_id(tb) do
        id when id == ws.id -> TabBar.set_workspace_agent_ui(tb, ws.id, nil)
        _workspace_id -> tb
      end

    {MingaEditor.WorkspaceWorkflow.install_tab_bar(state, tb), ws.id}
  end

  # The workspace's Agent tab: an existing unowned sessionless one, or a new inactive
  # tab, so every agent workspace a start creates can be found and shown.
  @spec sessionless_agent_tab(state(), TabBar.t()) :: {TabBar.t(), Tab.t()}
  defp sessionless_agent_tab(state, tb) do
    active = TabBar.active(tb)
    preferred = if active && unowned_agent_tab?(active), do: active

    case preferred || Enum.find(tb.tabs, &unowned_agent_tab?/1) do
      %Tab{} = tab ->
        {tb, tab}

      nil ->
        MingaEditor.TabWorkflow.insert_agent(
          tb,
          "Agent",
          state.frontend.terminal_viewport,
          state.workspace.file_tree.project_root
        )
    end
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
