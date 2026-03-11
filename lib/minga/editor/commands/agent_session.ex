defmodule Minga.Editor.Commands.AgentSession do
  @moduledoc """
  Agent session lifecycle commands.

  Handles starting, restarting, subscribing to, and opening code blocks
  from agent sessions. Extracted from `Commands.Agent` to reduce module size.
  """

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.Session
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.TabBar

  @type state :: EditorState.t()

  # ── Session lifecycle ──────────────────────────────────────────────────────

  @doc "Stops the current session and restarts if the panel is visible."
  @spec restart_session(state(), String.t()) :: state()
  def restart_session(state, message) do
    if state.agent.session do
      try do
        GenServer.stop(state.agent.session, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end

    state = update_agent(state, &AgentState.clear_session/1)
    state = %{state | status_msg: message}
    if AgentState.visible?(state.agent), do: start_agent_session(state), else: state
  end

  @doc "Starts a new agent session and subscribes to its events."
  @spec start_agent_session(state()) :: state()
  def start_agent_session(state) do
    opts = [
      thinking_level: state.agent.panel.thinking_level,
      provider_opts: [
        provider: state.agent.panel.provider_name,
        model: state.agent.panel.model_name
      ]
    ]

    case start_and_subscribe(opts) do
      {:ok, pid} ->
        state =
          if state.agent.buffer == nil do
            buf = AgentBufferSync.start_buffer()
            update_agent(state, &AgentState.set_buffer(&1, buf))
          else
            state
          end

        state = update_agent(state, &AgentState.set_session(&1, pid))

        case state do
          %{tab_bar: %TabBar{active_id: id}} ->
            EditorState.set_tab_session(state, id, pid)

          _ ->
            state
        end

      {:error, reason} ->
        require Logger
        msg = format_session_error(reason)
        Logger.error("[Agent] #{msg}")
        Minga.Editor.log_to_messages("[Agent] #{msg}")
        update_agent(state, &AgentState.set_error(&1, msg))
    end
  end

  # ── Code block helpers ─────────────────────────────────────────────────────

  @doc """
  Opens a code block from an agent chat message as a scratch buffer.

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

    if state.agent.session do
      Session.add_system_message(
        state.agent.session,
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

  @spec update_agent(state(), (AgentState.t() -> AgentState.t())) :: state()
  defp update_agent(state, fun) do
    %{state | agent: fun.(state.agent)}
  end

  @doc "Updates the agentic view state with the given function."
  @spec update_agentic(state(), (ViewState.t() -> ViewState.t())) :: state()
  def update_agentic(state, fun) do
    %{state | agentic: fun.(state.agentic)}
  end
end
