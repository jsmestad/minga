defmodule MingaEditor.Commands.AgentSession do
  @moduledoc """
  Agent session lifecycle commands.

  Handles starting, restarting, subscribing to, and opening code blocks
  from agent sessions. Extracted from `Commands.Agent` to reduce module size.
  """

  alias MingaEditor.Agent.BufferSync, as: AgentBufferSync
  alias MingaAgent.Session
  alias Minga.Buffer
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Workspace
  alias MingaEditor.State.Tab
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
  callers go through `Shell.Board.Input.start_and_attach_session/4`
  for new sessions and rely on `:agent_session_stopped` events for cleanup.
  """
  @spec restart_session(state(), String.t()) :: state()
  def restart_session(%{shell: MingaEditor.Shell.Traditional} = state, message) do
    session = AgentAccess.session(state)

    if session do
      try do
        MingaAgent.SessionManager.stop_session_by_pid(session)
      catch
        :exit, _ -> :ok
      end
    end

    state = state |> clear_active_tab_session() |> reset_agent_cache()
    state = EditorState.set_status(state, message)
    if AgentAccess.panel(state).visible, do: start_agent_session(state), else: state
  end

  def restart_session(state, _message) do
    EditorState.set_status(state, "Session restart is not supported on this shell")
  end

  @spec clear_active_tab_session(state()) :: state()
  defp clear_active_tab_session(%{shell_state: %{tab_bar: %TabBar{active_id: id}}} = state) do
    EditorState.set_tab_session(state, id, nil)
  end

  defp clear_active_tab_session(state), do: state

  @spec reset_agent_cache(state()) :: state()
  defp reset_agent_cache(state) do
    AgentAccess.update_agent(state, &AgentState.reset_cache/1)
  end

  @doc "Starts a new agent session and subscribes to its events."
  @spec start_agent_session(state()) :: state()
  @spec start_agent_session(state(), keyword()) :: state()
  def start_agent_session(state, opts \\ []) do
    panel = AgentAccess.panel(state)

    session_opts = [
      thinking_level: panel.thinking_level,
      session_start_hook_enabled?: Keyword.get(opts, :session_start_hook_enabled?, true),
      provider_opts: [
        provider: panel.provider_name,
        model: panel.model_name
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

        # Set the session PID on the agent tab that was just created
        # (or the active agent tab). find_sessionless_agent avoids the
        # ambiguity of find_by_kind(:agent) when multiple agent tabs exist.
        # Tab.session is the source of truth; the rendering cache on
        # state.shell_state.agent (status, error, pending_approval) is
        # populated lazily on tab switch via rebuild_agent_from_session/2.
        state = assign_session_to_tab(state, pid)

        # Create an workspace for this session (if one doesn't exist yet)
        ensure_agent_workspace(state, pid)

      {:error, reason} ->
        msg = format_session_error(reason)
        Minga.Log.error(:agent, "[Agent] #{msg}")
        AgentAccess.update_agent(state, &AgentState.set_error(&1, msg))
    end
  end

  @doc "Connects the local GUI to an existing remote agent session."
  @spec connect_remote_session(state(), String.t(), String.t(), pid()) :: state()
  def connect_remote_session(state, server_name, session_id, remote_pid)
      when is_binary(server_name) and is_binary(session_id) and is_pid(remote_pid) do
    case subscribe_and_snapshot(remote_pid) do
      {:ok, messages, snapshot} ->
        {state, tab_id, buffer} = create_remote_agent_tab(state, server_name)
        AgentBufferSync.sync(buffer, messages)

        state
        |> set_remote_tab(tab_id, server_name, session_id, remote_pid)
        |> AgentAccess.update_agent(&AgentState.set_buffer(&1, buffer))
        |> rebuild_agent_from_tab(tab_id)
        |> apply_remote_snapshot(snapshot)
        |> ensure_agent_workspace(remote_pid)
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
      {:ok, session_id, remote_pid} ->
        connect_remote_session(state, server_name, session_id, remote_pid)

      {:error, reason} ->
        EditorState.set_status(state, "Failed to start remote session: #{inspect(reason)}")
    end
  end

  @spec remote_session_opts(state()) :: keyword()
  defp remote_session_opts(state) do
    panel = AgentAccess.panel(state)
    [thinking_level: panel.thinking_level]
  end

  @spec remote_start_session(node(), keyword()) :: {:ok, String.t(), pid()} | {:error, term()}
  defp remote_start_session(remote_node, opts) do
    :erpc.call(remote_node, MingaAgent.SessionManager, :start_session, [opts], 10_000)
  catch
    :exit, reason -> {:error, {:remote_unavailable, reason}}
  end

  @spec subscribe_and_snapshot(pid()) :: {:ok, [term()], map()} | {:error, term()}
  defp subscribe_and_snapshot(remote_pid) do
    Session.subscribe(remote_pid, self())
    messages = Session.messages(remote_pid)
    snapshot = Session.editor_snapshot(remote_pid)
    {:ok, messages, snapshot}
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

  @spec rebuild_agent_from_tab(state(), Tab.id()) :: state()
  defp rebuild_agent_from_tab(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, tab_id) do
    case TabBar.get(tb, tab_id) do
      %Tab{} = tab -> EditorState.rebuild_agent_from_session(state, tab)
      nil -> state
    end
  end

  defp rebuild_agent_from_tab(state, _tab_id), do: state

  @spec apply_remote_snapshot(state(), Session.editor_snapshot()) :: state()
  defp apply_remote_snapshot(state, %{
         status: status,
         pending_approval: pending_approval,
         error: error
       }) do
    AgentAccess.update_agent(state, fn agent ->
      AgentState.apply_session_snapshot(agent, status, pending_approval, error)
    end)
  end

  @spec stop_remote_session(state(), pid()) :: state()
  defp stop_remote_session(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, session) do
    case TabBar.find_by_session(tb, session) do
      %Tab{remote_session_id: session_id} when is_binary(session_id) ->
        case :erpc.call(
               node(session),
               MingaAgent.SessionManager,
               :stop_session,
               [session_id],
               5_000
             ) do
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
  @spec ensure_agent_workspace(state(), pid()) :: state()
  defp ensure_agent_workspace(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state, session_pid) do
    case TabBar.find_workspace_by_session(tb, session_pid) do
      %Workspace{} ->
        # Workspace already exists for this session
        state

      nil ->
        # Create workspace and assign the agent tab to it
        {tb, ws} = TabBar.add_workspace(tb, "Agent", session_pid)

        # Find the agent tab with this session and move it into the workspace
        tb =
          case TabBar.find_by_session(tb, session_pid) do
            %Tab{id: tab_id} -> TabBar.move_tab_to_workspace(tb, tab_id, ws.id)
            nil -> tb
          end

        EditorState.set_tab_bar(state, tb)
    end
  end

  defp ensure_agent_workspace(state, _session_pid), do: state
end
