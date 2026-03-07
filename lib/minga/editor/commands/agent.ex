defmodule Minga.Editor.Commands.Agent do
  @moduledoc """
  Editor commands for AI agent interaction.

  Handles toggling the agent panel, submitting prompts, scrolling
  the chat, and managing agent sessions. All functions are pure
  `state → state` transformations.
  """

  alias Minga.Agent.BufferSync, as: AgentBufferSync
  alias Minga.Agent.Session
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Windows

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc "Toggles the agent chat panel."
  @spec toggle_panel(state()) :: state()
  def toggle_panel(%{agent: %{panel: %{visible: true, input_focused: false}}} = state) do
    update_agent(state, &AgentState.focus_input(&1, true))
  end

  def toggle_panel(state) do
    state = update_agent(state, &AgentState.toggle_panel/1)

    state =
      if state.agent.panel.visible and state.agent.session == nil do
        start_agent_session(state)
      else
        state
      end

    if state.agent.panel.visible do
      update_agent(state, &AgentState.focus_input(&1, true))
    else
      update_agent(state, &AgentState.focus_input(&1, false))
    end
  end

  @doc """
  Toggles the full-screen agentic view on or off.

  On activate: saves the current window layout, sets `agentic_view: true`, and
  ensures an agent session is running (starting one if needed). On deactivate:
  restores the saved window layout and sets `agentic_view: false`.
  """
  @spec toggle_agentic_view(state()) :: state()
  def toggle_agentic_view(%{agentic: %{active: true}} = state) do
    {new_av, saved_windows, saved_file_tree} = ViewState.deactivate(state.agentic)

    state =
      if saved_windows do
        %{state | windows: saved_windows}
      else
        state
      end

    state =
      if saved_file_tree do
        %{state | file_tree: saved_file_tree}
      else
        state
      end

    %{state | agentic: new_av}
  end

  def toggle_agentic_view(%{agentic: %{active: false}} = state) do
    # Save current window layout and activate the agentic view.
    state = %{state | agentic: ViewState.activate(state.agentic, state.windows, state.file_tree)}

    # Close any open splits and file tree — the agentic view takes the full screen.
    %Windows{} = ws = state.windows
    alias Minga.Editor.State.FileTree, as: FileTreeState
    state = %{state | windows: %{ws | tree: nil}, file_tree: FileTreeState.close(state.file_tree)}

    # Ensure a session is running; start one if not.
    if state.agent.session == nil do
      start_agent_session(state)
    else
      state
    end
  end

  @doc "Submits the current input text as a prompt."
  @spec submit_prompt(state()) :: state()
  def submit_prompt(%{agent: %{panel: %{input_text: ""}}} = state), do: state

  def submit_prompt(%{agent: %{session: nil}} = state) do
    %{state | status_msg: "No agent session — try closing and reopening the panel"}
  end

  def submit_prompt(state) do
    text = state.agent.panel.input_text

    case Session.send_prompt(state.agent.session, text) do
      :ok ->
        update_agent(state, &AgentState.clear_input_and_scroll/1)

      {:error, :provider_not_ready} ->
        %{state | status_msg: "Agent provider still starting — try again in a moment"}

      {:error, reason} ->
        %{state | status_msg: "Agent error: #{inspect(reason)}"}
    end
  end

  @doc "Aborts the current agent operation."
  @spec abort_agent(state()) :: state()
  def abort_agent(%{agent: %{session: nil}} = state), do: state

  def abort_agent(state) do
    Session.abort(state.agent.session)
    state
  end

  @doc "Starts a fresh agent session."
  @spec new_agent_session(state()) :: state()
  def new_agent_session(%{agent: %{session: nil}} = state) do
    start_agent_session(state)
  end

  def new_agent_session(state) do
    Session.new_session(state.agent.session)
    update_agent(state, &AgentState.set_status(&1, :idle))
  end

  @doc "Scrolls the chat panel up by half the panel height."
  @spec scroll_chat_up(state()) :: state()
  def scroll_chat_up(%{agent: %{panel: %{visible: false}}} = state), do: state

  def scroll_chat_up(state) do
    amount = div(panel_height(state), 2)
    update_agent(state, &AgentState.scroll_up(&1, amount))
  end

  @doc "Scrolls the chat panel down by half the panel height."
  @spec scroll_chat_down(state()) :: state()
  def scroll_chat_down(%{agent: %{panel: %{visible: false}}} = state), do: state

  def scroll_chat_down(state) do
    amount = div(panel_height(state), 2)
    update_agent(state, &AgentState.scroll_down(&1, amount))
  end

  @doc "Handles a character input in the agent prompt."
  @spec input_char(state(), String.t()) :: state()
  def input_char(%{agent: %{panel: %{visible: false}}} = state, _char), do: state

  def input_char(state, char) do
    update_agent(state, &AgentState.insert_char(&1, char))
  end

  @doc "Deletes the last character from the agent prompt."
  @spec input_backspace(state()) :: state()
  def input_backspace(%{agent: %{panel: %{visible: false}}} = state), do: state

  def input_backspace(state) do
    update_agent(state, &AgentState.delete_char/1)
  end

  @doc "Cycles the thinking level (off → low → medium → high)."
  @spec cycle_thinking_level(state()) :: state()
  def cycle_thinking_level(%{agent: %{session: nil}} = state) do
    %{state | status_msg: "No agent session"}
  end

  def cycle_thinking_level(state) do
    case Session.cycle_thinking_level(state.agent.session) do
      {:ok, %{"level" => level}} when is_binary(level) ->
        state = update_agent(state, &AgentState.set_thinking_level(&1, level))
        %{state | status_msg: "Thinking: #{level}"}

      {:ok, nil} ->
        %{state | status_msg: "Model does not support thinking levels"}

      {:error, reason} ->
        %{state | status_msg: "Error: #{inspect(reason)}"}
    end
  end

  @doc "Sets the agent provider and restarts the session."
  @spec set_provider(state(), String.t()) :: state()
  def set_provider(state, provider) do
    state = update_agent(state, &AgentState.set_provider_name(&1, provider))
    restart_session(state, "Provider set to #{provider}")
  end

  @doc "Sets the agent model and restarts the session."
  @spec set_model(state(), String.t()) :: state()
  def set_model(state, model) do
    state = update_agent(state, &AgentState.set_model_name(&1, model))
    restart_session(state, "Model set to #{model}")
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec restart_session(state(), String.t()) :: state()
  defp restart_session(state, message) do
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

  @spec start_agent_session(state()) :: state()
  defp start_agent_session(state) do
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

        update_agent(state, &AgentState.set_session(&1, pid))

      {:error, reason} ->
        require Logger
        msg = format_session_error(reason)
        Logger.error("[Agent] #{msg}")
        Minga.Editor.log_to_messages("[Agent] #{msg}")
        update_agent(state, &AgentState.set_error(&1, msg))
    end
  end

  @spec start_and_subscribe(keyword()) :: {:ok, pid()} | {:error, term()}
  defp start_and_subscribe(opts) do
    case Minga.Agent.Supervisor.start_session(opts) do
      {:ok, pid} ->
        try do
          Session.subscribe(pid)
          {:ok, pid}
        catch
          :exit, reason ->
            # Session died before we could subscribe (e.g. provider binary missing).
            # Clean up the child so the supervisor doesn't hold a dead reference.
            Minga.Agent.Supervisor.stop_session(pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec update_agent(state(), (AgentState.t() -> AgentState.t())) :: state()
  defp update_agent(state, fun) do
    %{state | agent: fun.(state.agent)}
  end

  @spec format_session_error(term()) :: String.t()
  defp format_session_error({:pi_not_found, msg}) when is_binary(msg), do: msg
  defp format_session_error({:noproc, _}), do: "Agent supervisor not running"
  defp format_session_error(reason), do: "Failed to start session: #{inspect(reason)}"

  @spec panel_height(state()) :: non_neg_integer()
  defp panel_height(state) do
    div(state.viewport.rows * 35, 100)
  end
end
