defmodule Minga.Editor.Commands.AgentSession do
  @moduledoc """
  Agent session lifecycle commands.

  Handles starting, restarting, subscribing to, and opening code blocks
  from agent sessions. Extracted from `Commands.Agent` to reduce module size.
  """

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.Session
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.AgentLifecycle
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.State.Workspace

  @type state :: EditorState.t()

  # ── Session lifecycle ──────────────────────────────────────────────────────

  @doc "Stops the current session and restarts if the panel is visible."
  @spec restart_session(state(), String.t()) :: state()
  def restart_session(state, message) do
    if AgentAccess.session(state) do
      try do
        GenServer.stop(AgentAccess.session(state), :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end

    state = AgentAccess.update_agent(state, &AgentState.clear_session/1)
    state = %{state | status_msg: message}
    if AgentAccess.panel(state).visible, do: start_agent_session(state), else: state
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

        state = AgentAccess.update_agent(state, &AgentState.set_session(&1, pid))

        state =
          case state do
            %{tab_bar: %TabBar{active_id: id}} ->
              EditorState.set_tab_session(state, id, pid)

            _ ->
              state
          end

        # Create a workspace for this agent session (if one doesn't exist yet)
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
      BufferServer.start_link(
        content: content,
        buffer_name: name,
        filetype: filetype
      )

    state = put_in(state.buffers.active, buf)

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

  @spec start_and_subscribe(keyword()) :: {:ok, pid()} | {:error, term()}
  defp start_and_subscribe(opts) do
    case Minga.Agent.Supervisor.start_session(opts) do
      {:ok, pid} ->
        try do
          Session.subscribe(pid)
          {:ok, pid}
        catch
          :exit, reason ->
            Minga.Agent.Supervisor.stop_session(pid)
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
  defp ensure_agent_workspace(%{tab_bar: %TabBar{} = tb} = state, session_pid) do
    case TabBar.find_workspace_by_session(tb, session_pid) do
      %Workspace{} ->
        # Workspace already exists for this session
        state

      nil ->
        # Create workspace and assign the agent tab to it
        {tb, ws} = TabBar.add_agent_workspace(tb, "Agent", session_pid)

        # Find the agent tab with this session and move it into the workspace
        tb =
          case TabBar.find_by_session(tb, session_pid) do
            %Tab{id: tab_id} -> TabBar.move_tab_to_workspace(tb, tab_id, ws.id)
            nil -> tb
          end

        %{state | tab_bar: tb}
    end
  end

  defp ensure_agent_workspace(state, _session_pid), do: state
end
