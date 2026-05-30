defmodule MingaEditor.Commands.AgentSession do
  @moduledoc """
  Agent session lifecycle commands.

  Handles starting, restarting, subscribing to, and opening code blocks
  from agent sessions. Extracted from `Commands.Agent` to reduce module size.
  """

  alias MingaEditor.Agent.BufferSync, as: AgentBufferSync
  alias MingaAgent.ProjectView
  alias MingaAgent.Session
  alias Minga.Buffer
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Workspace.RemoteSession
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @type state :: EditorState.t()

  # ── Session lifecycle ──────────────────────────────────────────────────────

  @doc """
  Stops the current session and restarts if the panel is visible.

  Traditional-shell only: restart cycles the session pid on the active
  tab. The Board shell has its own per-card lifecycle (cards are
  long-lived and own their session pid through zoom in/out), so a
  generic "restart" without card context isn't meaningful there. Board
  callers go through the active shell's session-start callback
  for new sessions and rely on `:agent_session_stopped` events for cleanup.
  """
  @spec restart_session(state(), String.t()) :: state()
  def restart_session(%{shell_id: :traditional} = state, message) do
    session = AgentAccess.session(state)

    if session do
      try do
        MingaAgent.SessionManager.stop_session_by_pid(session)
      catch
        :exit, _ -> :ok
      end
    end

    state = state |> clear_restart_session(session) |> reset_agent_cache()
    state = EditorState.set_status(state, message)
    if AgentAccess.panel(state).visible, do: start_agent_session(state), else: state
  end

  def restart_session(state, _message) do
    EditorState.set_status(state, "Session restart is not supported on this shell")
  end

  @spec clear_restart_session(state(), pid() | nil) :: state()
  defp clear_restart_session(state, nil), do: state

  defp clear_restart_session(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, session) do
    tb = tb |> clear_tab_sessions(session) |> clear_workspace_sessions(session)
    EditorState.set_tab_bar(state, tb)
  end

  defp clear_restart_session(state, _session), do: state

  @spec clear_tab_sessions(TabBar.t(), pid()) :: TabBar.t()
  defp clear_tab_sessions(%TabBar{} = tb, session) do
    Enum.reduce(tb.tabs, tb, fn
      %Tab{id: tab_id, session: ^session}, acc ->
        TabBar.update_tab(acc, tab_id, &Tab.set_session(&1, nil))

      _tab, acc ->
        acc
    end)
  end

  @spec clear_workspace_sessions(TabBar.t(), pid()) :: TabBar.t()
  defp clear_workspace_sessions(%TabBar{} = tb, session) do
    Enum.reduce(tb.workspaces, tb, fn
      %Workspace{id: workspace_id, session: ^session}, acc ->
        TabBar.update_workspace(acc, workspace_id, &Workspace.clear_session/1)

      _workspace, acc ->
        acc
    end)
  end

  @spec reset_agent_cache(state()) :: state()
  defp reset_agent_cache(state) do
    AgentAccess.update_agent(state, &AgentState.reset_cache/1)
  end

  @doc "Starts a new agent session and subscribes to its events."
  @spec start_agent_session(state()) :: state()
  @spec start_agent_session(state(), keyword()) :: state()
  def start_agent_session(state, opts \\ []) do
    panel = AgentAccess.panel(state)
    {project_view, created_project_view?} = session_project_view(state)

    session_opts = [
      thinking_level: panel.thinking_level,
      session_start_hook_enabled?: Keyword.get(opts, :session_start_hook_enabled?, true),
      provider_opts: [
        provider: panel.provider_name,
        model: panel.model_name,
        project_view: project_view
      ]
    ]

    case start_and_subscribe(session_opts) do
      {:ok, pid} ->
        state =
          if AgentAccess.agent(state).buffer == nil do
            buf = AgentBufferSync.start_buffer(EditorState.options_server(state))
            state = AgentAccess.update_agent(state, &AgentState.set_buffer(&1, buf))
            state = EditorState.monitor_buffer(state, buf)
            AgentLifecycle.setup_agent_highlight(state)
          else
            state
          end

        # Create the workspace first so set_tab_session/3 does not project the session onto the manual workspace.
        state
        |> ensure_agent_workspace(pid, project_view)
        |> assign_session_to_tab(pid)

      {:error, reason} ->
        maybe_discard_project_view(project_view, created_project_view?)
        msg = format_session_error(reason)
        Minga.Log.error(:agent, "[Agent] #{msg}")
        AgentAccess.update_agent(state, &AgentState.set_error(&1, msg))
    end
  end

  @doc "Connects the local GUI to an existing remote agent session."
  @spec connect_remote_session(state(), String.t(), String.t(), pid(), String.t()) :: state()
  def connect_remote_session(state, server_name, session_id, remote_pid, token)
      when is_binary(server_name) and is_binary(session_id) and is_pid(remote_pid) and
             is_binary(token) do
    case remote_attach(remote_pid, session_id, token) do
      {:ok, messages, snapshot} ->
        {state, tab_id, buffer} = create_remote_agent_tab(state, server_name)
        AgentBufferSync.sync(buffer, messages)

        state
        |> set_remote_tab(tab_id, server_name, session_id, remote_pid)
        |> AgentAccess.update_agent(&AgentState.set_buffer(&1, buffer))
        |> rebuild_agent_from_tab(tab_id)
        |> apply_remote_snapshot(snapshot)
        |> ensure_agent_workspace(remote_pid, nil)
        |> set_remote_workspace(server_name, session_id, remote_pid, :connected)
        |> EditorState.set_status("Connected to #{server_name} session #{session_id}")

      {:error, reason} ->
        EditorState.set_status(state, "Remote session unavailable: #{inspect(reason)}")
    end
  end

  @doc "Starts a new agent session on a connected remote server and opens it locally."
  @spec start_remote_session(state(), String.t()) :: state()
  def start_remote_session(state, server_name) when is_binary(server_name) do
    case Minga.Distribution.ConnectionManager.node_for_server(server_name) do
      {:ok, remote_node} ->
        start_remote_session_on_node(state, server_name, remote_node)

      {:error, :disconnected} ->
        EditorState.set_status(state, "Remote server #{server_name} is disconnected")

      {:error, :not_found} ->
        EditorState.set_status(state, "Unknown remote server #{server_name}")
    end
  end

  @doc "Sends a prompt to a local or remote session, enforcing the remote broker boundary."
  @spec send_prompt_pid(pid(), String.t() | [ReqLLM.Message.ContentPart.t()]) ::
          :ok | {:queued, :steering} | {:error, term()}
  def send_prompt_pid(session, prompt) when is_pid(session) and node(session) == node() do
    Session.send_prompt(session, prompt)
  end

  def send_prompt_pid(session, prompt) when is_pid(session) do
    with {:ok, session_id} <- remote_session_id_for_pid(node(session), session),
         {:ok, token} <- remote_session_token(node(session), session_id) do
      :erpc.call(
        node(session),
        MingaAgent.RemoteAPI,
        :send_prompt,
        [session_id, token, self(), prompt],
        10_000
      )
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Responds to a tool approval on a local or remote session, enforcing the remote broker boundary."
  @spec respond_to_approval_pid(pid(), Session.approval_decision()) :: :ok | {:error, term()}
  def respond_to_approval_pid(session, decision)
      when is_pid(session) and node(session) == node() do
    Session.respond_to_approval(session, decision)
  end

  def respond_to_approval_pid(session, decision) when is_pid(session) do
    with {:ok, session_id} <- remote_session_id_for_pid(node(session), session),
         {:ok, token} <- remote_session_token(node(session), session_id) do
      :erpc.call(
        node(session),
        MingaAgent.RemoteAPI,
        :approve,
        [session_id, token, self(), decision],
        10_000
      )
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Stops a session pid, routing remote pids to their owning node."
  @spec stop_session_pid(pid()) :: :ok | {:error, term()}
  def stop_session_pid(session) when is_pid(session) and node(session) == node() do
    MingaAgent.SessionManager.stop_session_by_pid(session)
  catch
    :exit, reason -> {:error, reason}
  end

  def stop_session_pid(session) when is_pid(session) do
    with {:ok, session_id} <- remote_session_id_for_pid(node(session), session),
         {:ok, token} <- remote_session_token(node(session), session_id) do
      :erpc.call(node(session), MingaAgent.RemoteAPI, :stop_session, [session_id, token], 5_000)
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Stops the current agent session, routing remote sessions to their remote manager."
  @spec stop_current_session(state()) :: state()
  def stop_current_session(state) do
    case AgentAccess.session(state) do
      nil ->
        state

      session when node(session) == node() ->
        MingaAgent.SessionManager.stop_session_by_pid(session)
        state

      session ->
        stop_remote_session(state, session)
    end
  catch
    :exit, reason -> EditorState.set_status(state, "Failed to stop session: #{inspect(reason)}")
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
           options_server: EditorState.options_server(state)
         ) do
      {:ok, buf} ->
        state
        |> put_in([Access.key(:workspace), Access.key(:buffers), Access.key(:active)], buf)
        |> maybe_log_code_block_opened(language)

      {:error, reason} ->
        EditorState.set_status(state, "Failed to open code block: #{inspect(reason)}")
    end
  end

  @spec maybe_log_code_block_opened(state(), String.t()) :: state()
  defp maybe_log_code_block_opened(state, language) do
    case AgentAccess.session(state) do
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
  defp assign_session_to_tab(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, pid) do
    case TabBar.find_sessionless_agent(tb) do
      %Tab{id: agent_tab_id} -> EditorState.set_tab_session(state, agent_tab_id, pid)
      nil -> state
    end
  end

  defp assign_session_to_tab(state, _pid), do: state

  @spec sessionless_agent?(Tab.t()) :: boolean()
  defp sessionless_agent?(%Tab{kind: :agent, session: nil}), do: true
  defp sessionless_agent?(%Tab{}), do: false

  @spec start_and_subscribe(keyword()) :: {:ok, pid()} | {:error, term()}
  defp start_and_subscribe(opts) do
    case MingaAgent.SessionManager.start_session(opts) do
      {:ok, _session_id, pid} ->
        try do
          Session.subscribe(pid)
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

  @spec start_remote_session_on_node(state(), String.t(), node()) :: state()
  defp start_remote_session_on_node(state, server_name, remote_node) do
    case remote_start_session(remote_node, remote_session_opts(state)) do
      {:ok, session_id, remote_pid, token} ->
        connect_remote_session(state, server_name, session_id, remote_pid, token)

      {:error, reason} ->
        EditorState.set_status(state, "Failed to start remote session: #{inspect(reason)}")
    end
  end

  @spec remote_session_opts(state()) :: keyword()
  defp remote_session_opts(state) do
    panel = AgentAccess.panel(state)
    [thinking_level: panel.thinking_level]
  end

  @spec remote_start_session(node(), keyword()) ::
          {:ok, String.t(), pid(), String.t()} | {:error, term()}
  defp remote_start_session(remote_node, opts) do
    case :erpc.call(remote_node, MingaAgent.RemoteAPI, :start_session, [opts], 10_000) do
      {:ok, %{session_id: session_id, pid: pid, token: token}} -> {:ok, session_id, pid, token}
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  catch
    :exit, reason -> {:error, {:remote_unavailable, reason}}
  end

  @spec remote_attach(pid(), String.t(), String.t()) :: {:ok, [term()], map()} | {:error, term()}
  defp remote_attach(remote_pid, session_id, token) do
    case :erpc.call(
           node(remote_pid),
           MingaAgent.RemoteAPI,
           :attach,
           [session_id, token, self(), [role: :driver]],
           10_000
         ) do
      {:ok, %{role: :driver, messages: messages, snapshot: snapshot}} -> {:ok, messages, snapshot}
      {:ok, %{role: :viewer}} -> {:error, :not_driver}
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec create_remote_agent_tab(state(), String.t()) :: {state(), Tab.id(), pid()}
  defp create_remote_agent_tab(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, _server_name) do
    state = ensure_agent_buffer(state)
    buffer = AgentAccess.agent(state).buffer
    rows = max(state.terminal_viewport.rows, 1)
    cols = max(state.terminal_viewport.cols, 1)
    win_id = 1
    agent_window = Window.new_agent_chat(win_id, buffer, rows, cols)

    windows = %Windows{
      tree: WindowTree.new(win_id),
      map: %{win_id => agent_window},
      active: win_id,
      next_id: win_id + 1
    }

    context = EditorState.build_agent_tab_defaults(state, windows, buffer)
    {tb, tab} = TabBar.add(tb, :agent, "Agent")
    tb = TabBar.update_context(tb, tab.id, context)
    state = EditorState.set_tab_bar(state, tb)
    {state, tab.id, buffer}
  end

  defp create_remote_agent_tab(state, _server_name) do
    state = ensure_agent_buffer(state)
    {state, 0, AgentAccess.agent(state).buffer}
  end

  @spec ensure_agent_buffer(state()) :: state()
  defp ensure_agent_buffer(state) do
    case AgentAccess.agent(state).buffer do
      pid when is_pid(pid) -> state
      _ -> create_agent_buffer(state)
    end
  end

  @spec create_agent_buffer(state()) :: state()
  defp create_agent_buffer(state) do
    case AgentBufferSync.start_buffer(EditorState.options_server(state)) do
      pid when is_pid(pid) ->
        state = AgentAccess.update_agent(state, &AgentState.set_buffer(&1, pid))
        state = EditorState.monitor_buffer(state, pid)
        AgentLifecycle.setup_agent_highlight(state)

      _ ->
        state
    end
  end

  @spec set_remote_tab(state(), Tab.id(), String.t(), String.t(), pid()) :: state()
  defp set_remote_tab(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         tab_id,
         server_name,
         session_id,
         remote_pid
       ) do
    tb =
      TabBar.update_tab(
        tb,
        tab_id,
        &Tab.set_remote_session(&1, server_name, session_id, remote_pid)
      )

    EditorState.set_tab_bar(state, tb)
  end

  defp set_remote_tab(state, _tab_id, _server_name, _session_id, _remote_pid), do: state

  @spec set_remote_workspace(
          state(),
          String.t(),
          String.t(),
          pid(),
          RemoteSession.connection_status()
        ) :: state()
  defp set_remote_workspace(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         server_name,
         session_id,
         remote_pid,
         status
       ) do
    case TabBar.find_workspace_by_session(tb, remote_pid) do
      %Workspace{id: workspace_id} ->
        tb =
          tb
          |> TabBar.update_workspace(workspace_id, fn workspace ->
            workspace
            |> Workspace.set_session(remote_pid)
            |> Workspace.put_remote_session(server_name, session_id, status)
          end)
          |> TabBar.sync_workspace_agent_tab_projection(workspace_id)

        EditorState.set_tab_bar(state, tb)

      nil ->
        state
    end
  end

  defp set_remote_workspace(state, _server_name, _session_id, _remote_pid, _status), do: state

  @spec rebuild_agent_from_tab(state(), Tab.id()) :: state()
  defp rebuild_agent_from_tab(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, tab_id) do
    case TabBar.get(tb, tab_id) do
      %Tab{} = tab -> EditorState.rebuild_agent_from_session(state, tab)
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
    AgentAccess.update_agent(state, fn agent ->
      AgentState.apply_session_snapshot(
        agent,
        status,
        pending_approval,
        error,
        Map.get(snapshot, :active_tool_name)
      )
    end)
  end

  @spec stop_remote_session(state(), pid()) :: state()
  defp stop_remote_session(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, session) do
    case TabBar.find_by_session(tb, session) do
      %Tab{remote_session_id: session_id} when is_binary(session_id) ->
        case stop_remote_session_by_id(node(session), session_id) do
          :ok ->
            state

          {:error, reason} ->
            EditorState.set_status(state, "Failed to stop remote session: #{inspect(reason)}")
        end

      _ ->
        EditorState.set_status(state, "Remote session id is unavailable")
    end
  catch
    :exit, reason ->
      EditorState.set_status(state, "Remote server unavailable: #{inspect(reason)}")
  end

  defp stop_remote_session(state, _session), do: state

  @spec remote_session_id_for_pid(node(), pid()) :: {:ok, String.t()} | {:error, term()}
  defp remote_session_id_for_pid(remote_node, remote_pid) do
    case :erpc.call(remote_node, MingaAgent.RemoteAPI, :list_sessions, [], 5_000) do
      sessions when is_list(sessions) ->
        Enum.find_value(sessions, {:error, :not_found}, fn
          %{session_id: session_id, pid: ^remote_pid} -> {:ok, session_id}
          _session -> nil
        end)

      other ->
        {:error, other}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec stop_remote_session_by_id(node(), String.t()) :: :ok | {:error, term()}
  defp stop_remote_session_by_id(remote_node, session_id) do
    with {:ok, token} <- remote_session_token(remote_node, session_id) do
      :erpc.call(remote_node, MingaAgent.RemoteAPI, :stop_session, [session_id, token], 5_000)
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec remote_session_token(node(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp remote_session_token(remote_node, session_id) do
    case :erpc.call(remote_node, MingaAgent.RemoteAPI, :list_sessions, [], 5_000) do
      sessions when is_list(sessions) ->
        Enum.find_value(sessions, {:error, :not_found}, fn
          %{session_id: ^session_id, token: token} -> {:ok, token}
          _session -> nil
        end)

      other ->
        {:error, other}
    end
  catch
    :exit, reason -> {:error, reason}
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
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
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

  @spec bind_session_to_agent_workspace(state(), TabBar.t(), pid()) :: state()
  defp bind_session_to_agent_workspace(state, %TabBar{} = tb, session_pid) do
    case reusable_agent_workspace(tb, session_pid) do
      %Workspace{id: workspace_id} ->
        tb =
          tb
          |> bind_session_to_workspace_agent_tab(workspace_id, session_pid)
          |> TabBar.update_workspace(workspace_id, &Workspace.set_session(&1, session_pid))

        sync_state_to_workspace(state, tb, workspace_id)

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

  @spec bind_session_to_workspace_agent_tab(TabBar.t(), non_neg_integer(), pid()) :: TabBar.t()
  defp bind_session_to_workspace_agent_tab(%TabBar{} = tb, workspace_id, session_pid) do
    case sessionless_agent_in_workspace(tb, workspace_id) do
      %Tab{id: tab_id} -> TabBar.update_tab(tb, tab_id, &Tab.set_session(&1, session_pid))
      nil -> tb
    end
  end

  @spec sessionless_agent_in_workspace(TabBar.t(), non_neg_integer()) :: Tab.t() | nil
  defp sessionless_agent_in_workspace(%TabBar{} = tb, workspace_id) do
    tb
    |> TabBar.tabs_in_workspace(workspace_id)
    |> Enum.find(&sessionless_agent?/1)
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

    sync_state_to_workspace(state, tb, ws.id)
  end

  @spec sync_state_to_workspace(state(), TabBar.t(), non_neg_integer()) :: state()
  defp sync_state_to_workspace(state, %TabBar{} = tb, workspace_id) do
    agent_ui =
      case TabBar.get_workspace(tb, workspace_id) do
        %Workspace{agent_ui: %MingaEditor.Agent.UIState{} = agent_ui} -> agent_ui
        _ -> MingaEditor.Agent.UIState.new()
      end

    state
    |> EditorState.set_tab_bar(tb)
    |> EditorState.set_agent_ui(agent_ui)
  end

  @spec maybe_update_bound_workspace_project_view(state(), pid(), ProjectView.t() | nil) ::
          state()
  defp maybe_update_bound_workspace_project_view(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
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

  @spec session_project_view(state()) :: {ProjectView.t() | nil, boolean()}
  defp session_project_view(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    case TabBar.active_workspace(tb) do
      %Workspace{kind: :agent} = workspace ->
        if Workspace.project_view_active?(workspace) do
          {workspace.project_view, false}
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
    case EditorState.file_tree_state(state).project_root do
      root when is_binary(root) ->
        case ProjectView.overlay(root) do
          {:ok, project_view} -> {project_view, true}
          {:error, _reason} -> {nil, false}
        end

      _ ->
        {nil, false}
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
    |> maybe_refresh_provider_project_view(workspace.session, project_view)
  end

  @spec update_workspace_project_view(state(), non_neg_integer(), ProjectView.t() | nil) ::
          state()
  defp update_workspace_project_view(
         %{shell_state: %{tab_bar: %TabBar{} = tb}} = state,
         workspace_id,
         project_view
       ) do
    tb = TabBar.update_workspace(tb, workspace_id, &Workspace.set_project_view(&1, project_view))
    EditorState.set_tab_bar(state, tb)
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
