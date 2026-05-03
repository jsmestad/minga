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
  alias MingaEditor.State.AgentGroup
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar

  @type state :: EditorState.t()

  # ── Session lifecycle ──────────────────────────────────────────────────────

  @doc """
  Stops the current session and restarts if the panel is visible.

  Traditional-shell only: restart cycles the session pid on the active
  tab. The Board shell has its own per-card lifecycle (cards are
  long-lived and own their session pid through zoom in/out), so a
  generic "restart" without card context isn't meaningful there. Board
  callers go through `Shell.Board.Input.start_and_attach_session/4`
  for new sessions and rely on `:DOWN` handling for cleanup.
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
  def start_agent_session(state) do
    panel = AgentAccess.panel(state)

    opts = [
      thinking_level: panel.thinking_level,
      provider_opts: [
        provider: panel.provider_name,
        model: panel.model_name
      ]
    ]

    case start_and_subscribe(opts) do
      {:ok, pid} ->
        state =
          if AgentAccess.agent(state).buffer == nil do
            buf = AgentBufferSync.start_buffer()
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

        # Create an agent group for this session (if one doesn't exist yet)
        ensure_agent_workspace(state, pid)

      {:error, reason} ->
        msg = format_session_error(reason)
        Minga.Log.error(:agent, "[Agent] #{msg}")
        AgentAccess.update_agent(state, &AgentState.set_error(&1, msg))
    end
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

    {:ok, buf} =
      Buffer.start_link(
        content: content,
        buffer_name: name,
        filetype: filetype
      )

    state = put_in(state.workspace.buffers.active, buf)

    if AgentAccess.session(state) do
      Session.add_system_message(
        AgentAccess.session(state),
        "Opened #{if(language == "", do: "text", else: language)} code block in buffer"
      )
    end

    state
  end

  @doc "Formats a session start error into a user-facing message."
  @spec format_session_error(term()) :: String.t()
  def format_session_error({:pi_not_found, msg}) when is_binary(msg), do: msg
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
    case TabBar.find_group_by_session(tb, session_pid) do
      %AgentGroup{} ->
        # Workspace already exists for this session
        state

      nil ->
        # Create workspace and assign the agent tab to it
        {tb, ws} = TabBar.add_agent_group(tb, "Agent", session_pid)

        # Find the agent tab with this session and move it into the workspace
        tb =
          case TabBar.find_by_session(tb, session_pid) do
            %Tab{id: tab_id} -> TabBar.move_tab_to_group(tb, tab_id, ws.id)
            nil -> tb
          end

        EditorState.set_tab_bar(state, tb)
    end
  end

  defp ensure_agent_workspace(state, _session_pid), do: state
end
