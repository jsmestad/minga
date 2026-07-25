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
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Remote.EventReplay
  alias MingaEditor.Remote.SessionClient
  alias MingaEditor.Shell.Entry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
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

  @doc "Starts a new agent session and subscribes to its events."
  @spec start_agent_session(state()) :: state()
  @spec start_agent_session(state(), keyword()) :: state()
  def start_agent_session(state, opts \\ []) do
    Minga.Telemetry.span([:minga, :agent, :start_agent_session], %{}, fn ->
      do_start_agent_session(state, opts)
    end)
  end

  @spec do_start_agent_session(state(), keyword()) :: state()
  defp do_start_agent_session(state, opts) do
    panel =
      state.workspace.agent_ui.panel
      |> Panel.ensure_configured_model(state.interaction.options_server)

    state =
      MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
        state,
        (fn _panel -> panel end).(state.workspace.agent_ui.panel)
      )

    {project_view, created_project_view?} = session_project_view(state)

    session_opts =
      [
        thinking_level: panel.thinking_level,
        model_name: panel.model_name,
        provider_name: panel.provider_name,
        session_start_hook_enabled?: Keyword.get(opts, :session_start_hook_enabled?, true),
        recover_interrupted_work?: Keyword.get(opts, :recover_interrupted_work?, true),
        provider_opts: provider_opts(state, panel, project_view)
      ]
      |> maybe_put_provider_module(state.agent_connection.agent_provider_module)

    case start_and_subscribe(state, session_opts) do
      {:ok, pid} ->
        # Create the workspace first so set_tab_session/3 does not project the session onto the manual workspace.
        state
        |> ensure_agent_workspace(pid, project_view)
        |> assign_session_to_tab(pid)

      {:error, reason} ->
        maybe_discard_project_view(project_view, created_project_view?)
        msg = format_session_error(reason)
        Minga.Log.error(:agent, "[Agent] #{msg}")
        MingaEditor.Shell.Traditional.Workflow.install_agent_error(state, msg)
    end
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
        {state, tab_id} = create_remote_agent_tab(state, server_name)

        state =
          state
          |> ensure_agent_workspace(remote_pid, nil)
          |> set_remote_workspace(
            server_name,
            session_id,
            remote_pid,
            :connected,
            latest_event_id
          )
          |> rebuild_agent_from_tab(tab_id)
          |> AgentLifecycle.cache_messages(messages)
          |> EventReplay.replay_active(events)
          |> apply_remote_snapshot(snapshot)
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

  @doc "Responds to a tool approval on a local or remote session, enforcing the remote broker boundary."
  @spec respond_to_approval_pid(pid(), Session.approval_decision()) :: :ok | {:error, term()}
  def respond_to_approval_pid(session, decision),
    do: respond_to_approval_pid(session, nil, decision)

  @doc "Responds to a stable tool approval id on a local or remote session."
  @spec respond_to_approval_pid(pid(), String.t() | nil, Session.approval_decision()) ::
          :ok | {:error, term()}
  def respond_to_approval_pid(session, _approval_id, decision)
      when is_pid(session) and node(session) == node() do
    # Local session: the Editor is not the session's driver. With the #2289
    # ingest coalescer, the foreground session is subscribed by the Ingest
    # process (which becomes the driver), and even without it the Editor's own
    # subscription does not make it the *caller* of this function. The gated
    # `respond_to_approval_as` would return {:error, :not_driver} here, so we use
    # the ungated single-process variant, mirroring how `send_prompt_pid` uses
    # ungated `Session.send_prompt` for the local-node case. Remote sessions keep
    # the driver-attach semantics below.
    Session.respond_to_approval(session, decision)
  end

  def respond_to_approval_pid(session, approval_id, decision) when is_pid(session) do
    SessionClient.approve(session, approval_id, decision)
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

    case Buffer.start_link(
           content: content,
           buffer_name: name,
           filetype: filetype,
           options_server: state.interaction.options_server
         ) do
      {:ok, buf} ->
        buffers = MingaEditor.State.Buffers.set_active_override(state.workspace.buffers, buf)
        workspace = MingaEditor.Session.State.set_buffers(state.workspace, buffers)

        state = %{state | workspace: workspace}
        maybe_log_code_block_opened(state, language)

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

  @spec assign_session_to_tab(state(), pid()) :: state()
  defp assign_session_to_tab(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state, pid) do
    case TabBar.find_sessionless_agent(tb) do
      %Tab{id: agent_tab_id} ->
        state = MingaEditor.Shell.Workflow.ensure_available(state)
        runtime = Runtime.set_tab_session(state.shell_runtime, agent_tab_id, pid)
        %{state | shell_runtime: runtime}

      nil ->
        state
    end
  end

  defp assign_session_to_tab(state, _pid), do: state

  @spec start_and_subscribe(state(), keyword()) :: {:ok, pid()} | {:error, term()}
  defp start_and_subscribe(state, opts) do
    start_result =
      Minga.Telemetry.span([:minga, :agent, :session_manager_start], %{}, fn ->
        MingaAgent.SessionManager.start_session(opts)
      end)

    case start_result do
      {:ok, _session_id, pid} ->
        try do
          subscribe_active_session(state, pid)
          {:ok, pid}
        catch
          :exit, reason ->
            MingaAgent.SessionManager.stop_session_by_pid(pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Routes the foreground session's events through the agent stream coalescer
  # (#2289) so token deltas are batched before reaching the Editor mailbox.
  # Falls back to a direct Editor subscription when the coalescer is absent.
  @spec subscribe_active_session(state(), pid()) :: :ok | {:error, term()}
  defp subscribe_active_session(state, pid) do
    case state.agent_connection.agent_ingest do
      ingest when is_pid(ingest) -> MingaEditor.Agent.Ingest.subscribe_session(ingest, pid)
      _ -> Session.subscribe(pid)
    end
  end

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

  @spec create_remote_agent_tab(state(), String.t()) :: {state(), Tab.id()}
  defp create_remote_agent_tab(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         _server_name
       ) do
    context =
      MingaEditor.State.Tab.Context.new_agent(
        state.frontend.terminal_viewport,
        state.workspace.file_tree.project_root
      )

    {tb, tab} = TabBar.add(tb, :agent, "Agent")
    tb = TabBar.update_context(tb, tab.id, context)

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

  defp create_remote_agent_tab(state, _server_name) do
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

  @spec rebuild_agent_from_tab(state(), Tab.id()) :: state()
  defp rebuild_agent_from_tab(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         tab_id
       ) do
    case TabBar.get(tb, tab_id) do
      %Tab{} = tab -> MingaEditor.AgentLifecycle.rebuild_agent_from_session(state, tab)
      nil -> state
    end
  end

  defp rebuild_agent_from_tab(state, _tab_id), do: state

  @spec apply_remote_snapshot(state(), Session.editor_snapshot()) :: state()
  defp apply_remote_snapshot(
         state,
         %{
           status: status,
           pending_approval: pending_approval,
           error: error
         } = snapshot
       ) do
    MingaEditor.Shell.Traditional.Workflow.install_agent_state(
      state,
      (fn agent ->
         AgentState.apply_session_snapshot(
           agent,
           status,
           pending_approval,
           error,
           Map.get(snapshot, :active_tool_name)
         )
       end).(MingaEditor.Shell.Traditional.State.agent(state.shell_runtime.state))
    )
  end

  @spec detach_remote_session(state(), pid()) :: state()
  defp detach_remote_session(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         session
       ) do
    case TabBar.find_by_session(tb, session) do
      %Tab{payload: %Agent{remote_session_id: session_id}} when is_binary(session_id) ->
        case detach_remote_session_by_id(node(session), session_id) do
          :ok ->
            state
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

  @spec detach_remote_session_by_id(node(), String.t()) :: :ok | {:error, term()}
  defp detach_remote_session_by_id(remote_node, session_id),
    do:
      Process.get(:minga_editor_remote_detach, &SessionClient.detach/2).(
        remote_node,
        session_id
      )

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

  # Creates an agent workspace when a session starts, and assigns
  # the current agent tab to it. No-op if the session already has
  # a workspace (e.g., session restart).
  @spec ensure_agent_workspace(state(), pid(), ProjectView.t() | nil) :: state()
  defp ensure_agent_workspace(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         session_pid,
         project_view
       ) do
    case TabBar.find_workspace_by_session(tb, session_pid) do
      %Workspace{} = workspace ->
        maybe_update_workspace_project_view(state, workspace, project_view)

      nil ->
        state
        |> bind_session_to_agent_workspace(tb, session_pid)
        |> maybe_update_bound_workspace_project_view(session_pid, project_view)
    end
  end

  defp ensure_agent_workspace(state, _session_pid, _project_view), do: state

  @spec provider_opts(state(), Panel.t(), ProjectView.t() | nil) :: keyword()
  defp provider_opts(state, panel, project_view) do
    Keyword.merge(state.agent_connection.agent_provider_opts,
      provider: panel.provider_name,
      model: panel.model_name,
      project_view: project_view
    )
  end

  @spec maybe_put_provider_module(keyword(), module() | nil) :: keyword()
  defp maybe_put_provider_module(opts, provider_module)
       when is_atom(provider_module) and not is_nil(provider_module),
       do: Keyword.put(opts, :provider, provider_module)

  defp maybe_put_provider_module(opts, _provider_module), do: opts

  @spec bind_session_to_agent_workspace(state(), TabBar.t(), pid()) :: state()
  defp bind_session_to_agent_workspace(state, %TabBar{} = tb, session_pid) do
    case reusable_agent_workspace(tb, session_pid) do
      %Workspace{id: workspace_id} ->
        workspace =
          tb
          |> TabBar.get_workspace(workspace_id)
          |> Workspace.set_session(session_pid)

        tb = TabBar.accept_workspace(tb, workspace)

        tb =
          case TabBar.active_workspace_id(tb) do
            id when id == workspace_id -> TabBar.set_workspace_agent_ui(tb, workspace_id, nil)
            _workspace_id -> tb
          end

        MingaEditor.WorkspaceWorkflow.install_tab_bar(state, tb)

      nil ->
        create_agent_workspace(state, tb, session_pid)
    end
  end

  @spec reusable_agent_workspace(TabBar.t(), pid()) :: Workspace.t() | nil
  defp reusable_agent_workspace(%TabBar{} = tb, session_pid) do
    workspace_for_session_tab(tb, session_pid) || reusable_active_agent_workspace(tb)
  end

  @spec workspace_for_session_tab(TabBar.t(), pid()) :: Workspace.t() | nil
  defp workspace_for_session_tab(%TabBar{} = tb, session_pid) do
    case TabBar.find_by_session(tb, session_pid) do
      %Tab{kind: :agent, group_id: workspace_id} when workspace_id > 0 ->
        case TabBar.get_workspace(tb, workspace_id) do
          %Workspace{kind: :agent} = workspace -> workspace
          _other -> nil
        end

      _other ->
        nil
    end
  end

  @spec reusable_active_agent_workspace(TabBar.t()) :: Workspace.t() | nil
  defp reusable_active_agent_workspace(%TabBar{} = tb) do
    case TabBar.active_workspace(tb) do
      %Workspace{kind: :agent} = workspace -> workspace
      _workspace -> nil
    end
  end

  @spec create_agent_workspace(state(), TabBar.t(), pid()) :: state()
  defp create_agent_workspace(state, %TabBar{} = tb, session_pid) do
    {tb, ws} = TabBar.add_workspace(tb, "Agent", session_pid)

    tb =
      case TabBar.find_by_session(tb, session_pid) || TabBar.find_sessionless_agent(tb) do
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

    MingaEditor.WorkspaceWorkflow.install_tab_bar(state, tb)
  end

  @spec maybe_update_bound_workspace_project_view(state(), pid(), ProjectView.t() | nil) ::
          state()
  defp maybe_update_bound_workspace_project_view(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         session_pid,
         project_view
       ) do
    case TabBar.find_workspace_by_session(tb, session_pid) do
      %Workspace{} = workspace ->
        maybe_update_workspace_project_view(state, workspace, project_view)

      nil ->
        state
    end
  end

  defp maybe_update_bound_workspace_project_view(state, _session_pid, _project_view), do: state

  @spec workspace_project_view(Workspace.t()) :: ProjectView.t() | nil
  defp workspace_project_view(%Workspace{
         payload: %WorkspaceAgent{project_view: %ProjectView{} = project_view}
       }),
       do: project_view

  defp workspace_project_view(%Workspace{}), do: nil

  @spec workspace_session(Workspace.t()) :: pid() | nil
  defp workspace_session(%Workspace{payload: %WorkspaceAgent{session: session}}), do: session
  defp workspace_session(%Workspace{}), do: nil

  @spec session_project_view(state()) :: {ProjectView.t() | nil, boolean()}
  defp session_project_view(%{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state) do
    case TabBar.active_workspace(tb) do
      %Workspace{kind: :agent} = workspace ->
        if MingaEditor.WorkspaceWorkflow.project_view_active?(workspace) do
          {workspace_project_view(workspace), false}
        else
          project_view_from_root(state)
        end

      _ ->
        project_view_from_root(state)
    end
  end

  defp session_project_view(state), do: project_view_from_root(state)

  @spec project_view_from_root(state()) :: {ProjectView.t() | nil, boolean()}
  defp project_view_from_root(state) do
    case state.workspace.file_tree.project_root do
      root when is_binary(root) -> measured_project_view_overlay(root)
      _ -> {nil, false}
    end
  end

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

  @spec maybe_discard_project_view(ProjectView.t() | nil, boolean()) :: :ok
  defp maybe_discard_project_view(%ProjectView{} = project_view, true) do
    ProjectView.discard(project_view)
  catch
    :exit, _ -> :ok
  end

  defp maybe_discard_project_view(_project_view, _created?), do: :ok

  @spec maybe_update_workspace_project_view(state(), Workspace.t(), ProjectView.t() | nil) ::
          state()
  defp maybe_update_workspace_project_view(state, %Workspace{} = workspace, project_view) do
    state
    |> update_workspace_project_view(workspace.id, project_view)
    |> maybe_refresh_provider_project_view(workspace_session(workspace), project_view)
  end

  @spec update_workspace_project_view(state(), non_neg_integer(), ProjectView.t() | nil) ::
          state()
  defp update_workspace_project_view(
         %{shell_runtime: %{state: %{tab_bar: %TabBar{} = tb}}} = state,
         workspace_id,
         project_view
       ) do
    tb = TabBar.set_workspace_project_view(tb, workspace_id, project_view)

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

  defp update_workspace_project_view(state, _workspace_id, _project_view), do: state

  @spec maybe_refresh_provider_project_view(state(), pid() | nil, ProjectView.t() | nil) ::
          state()
  defp maybe_refresh_provider_project_view(state, session, project_view) when is_pid(session) do
    case Session.get_provider(session) do
      nil ->
        state

      provider ->
        refresh_provider_project_view(state, provider, project_view)
    end
  catch
    :exit, _ -> state
  end

  defp maybe_refresh_provider_project_view(state, _session, _project_view), do: state

  @spec refresh_provider_project_view(state(), pid(), ProjectView.t() | nil) :: state()
  defp refresh_provider_project_view(state, provider, project_view) do
    :ok = MingaAgent.Providers.Native.refresh_project_view(provider, project_view)
    state
  catch
    :exit, _ -> state
  end
end
