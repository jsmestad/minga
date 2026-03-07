defmodule Minga.Editor.Commands.Agent do
  @moduledoc """
  Editor commands for AI agent interaction.

  Handles toggling the agent panel, submitting prompts, scrolling
  the chat, and managing agent sessions. All functions are pure
  `state → state` transformations.
  """

  alias Minga.Agent.PanelState
  alias Minga.Agent.Session
  alias Minga.Editor.State, as: EditorState

  @typedoc "Internal editor state."
  @type state :: EditorState.t()

  @doc "Toggles the agent chat panel."
  @spec toggle_panel(state()) :: state()
  def toggle_panel(%{agent_panel: %{visible: true, input_focused: false}} = state) do
    # Panel is open but unfocused: re-focus instead of closing
    %{state | agent_panel: PanelState.set_input_focused(state.agent_panel, true)}
  end

  def toggle_panel(%{agent_panel: panel} = state) do
    panel = PanelState.toggle(panel)

    state = %{state | agent_panel: panel}

    # Start agent session if needed
    state =
      if panel.visible and state.agent_session == nil do
        start_agent_session(state)
      else
        state
      end

    # Focus the input when opening, unfocus when closing
    if panel.visible do
      %{state | agent_panel: PanelState.set_input_focused(state.agent_panel, true)}
    else
      %{state | agent_panel: PanelState.set_input_focused(state.agent_panel, false)}
    end
  end

  @doc "Submits the current input text as a prompt."
  @spec submit_prompt(state()) :: state()
  def submit_prompt(%{agent_panel: %{input_text: ""}} = state), do: state

  def submit_prompt(%{agent_session: nil} = state) do
    %{state | status_msg: "No agent session — try closing and reopening the panel"}
  end

  def submit_prompt(state) do
    text = state.agent_panel.input_text

    case Session.send_prompt(state.agent_session, text) do
      :ok ->
        %{
          state
          | agent_panel:
              state.agent_panel |> PanelState.clear_input() |> PanelState.scroll_to_bottom()
        }

      {:error, :provider_not_ready} ->
        %{state | status_msg: "Agent provider still starting — try again in a moment"}

      {:error, reason} ->
        %{state | status_msg: "Agent error: #{inspect(reason)}"}
    end
  end

  @doc "Aborts the current agent operation."
  @spec abort_agent(state()) :: state()
  def abort_agent(%{agent_session: nil} = state), do: state

  def abort_agent(state) do
    Session.abort(state.agent_session)
    state
  end

  @doc "Starts a fresh agent session."
  @spec new_agent_session(state()) :: state()
  def new_agent_session(%{agent_session: nil} = state) do
    start_agent_session(state)
  end

  def new_agent_session(state) do
    Session.new_session(state.agent_session)
    %{state | agent_status: :idle}
  end

  @doc "Scrolls the chat panel up by half the panel height."
  @spec scroll_chat_up(state()) :: state()
  def scroll_chat_up(%{agent_panel: %{visible: false}} = state), do: state

  def scroll_chat_up(state) do
    amount = div(panel_height(state), 2)
    %{state | agent_panel: PanelState.scroll_up(state.agent_panel, amount)}
  end

  @doc "Scrolls the chat panel down by half the panel height."
  @spec scroll_chat_down(state()) :: state()
  def scroll_chat_down(%{agent_panel: %{visible: false}} = state), do: state

  def scroll_chat_down(state) do
    amount = div(panel_height(state), 2)
    %{state | agent_panel: PanelState.scroll_down(state.agent_panel, amount)}
  end

  @doc "Handles a character input in the agent prompt."
  @spec input_char(state(), String.t()) :: state()
  def input_char(%{agent_panel: %{visible: false}} = state, _char), do: state

  def input_char(state, char) do
    %{state | agent_panel: PanelState.insert_char(state.agent_panel, char)}
  end

  @doc "Deletes the last character from the agent prompt."
  @spec input_backspace(state()) :: state()
  def input_backspace(%{agent_panel: %{visible: false}} = state), do: state

  def input_backspace(state) do
    %{state | agent_panel: PanelState.delete_char(state.agent_panel)}
  end

  @doc "Cycles the thinking level (off → low → medium → high)."
  @spec cycle_thinking_level(state()) :: state()
  def cycle_thinking_level(%{agent_session: nil} = state) do
    %{state | status_msg: "No agent session"}
  end

  def cycle_thinking_level(state) do
    case Session.cycle_thinking_level(state.agent_session) do
      {:ok, %{"level" => level}} when is_binary(level) ->
        %{
          state
          | agent_panel: %{state.agent_panel | thinking_level: level},
            status_msg: "Thinking: #{level}"
        }

      {:ok, nil} ->
        %{state | status_msg: "Model does not support thinking levels"}

      {:error, reason} ->
        %{state | status_msg: "Error: #{inspect(reason)}"}
    end
  end

  @doc "Sets the agent provider and restarts the session."
  @spec set_provider(state(), String.t()) :: state()
  def set_provider(state, provider) do
    state = %{state | agent_panel: %{state.agent_panel | provider_name: provider}}
    restart_session(state, "Provider set to #{provider}")
  end

  @doc "Sets the agent model and restarts the session."
  @spec set_model(state(), String.t()) :: state()
  def set_model(state, model) do
    state = %{state | agent_panel: %{state.agent_panel | model_name: model}}
    restart_session(state, "Model set to #{model}")
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec restart_session(state(), String.t()) :: state()
  defp restart_session(state, message) do
    if state.agent_session do
      try do
        GenServer.stop(state.agent_session, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end

    state = %{state | agent_session: nil, agent_status: :idle, status_msg: message}
    if state.agent_panel.visible, do: start_agent_session(state), else: state
  end

  @spec start_agent_session(state()) :: state()
  defp start_agent_session(state) do
    opts = [
      thinking_level: state.agent_panel.thinking_level,
      provider_opts: [
        provider: state.agent_panel.provider_name,
        model: state.agent_panel.model_name
      ]
    ]

    case Minga.Agent.Supervisor.start_session(opts) do
      {:ok, pid} ->
        Session.subscribe(pid)
        %{state | agent_session: pid, agent_status: :idle}

      {:error, reason} ->
        require Logger
        Logger.error("[Agent] Failed to start session: #{inspect(reason)}")
        %{state | agent_status: :error, agent_error: inspect(reason)}
    end
  end

  @spec panel_height(state()) :: non_neg_integer()
  defp panel_height(state) do
    div(state.viewport.rows * 35, 100)
  end
end
