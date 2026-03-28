defmodule Minga.Shell.Board.DispatchPrompt do
  @moduledoc """
  Prompt handler for dispatching a new agent from The Board.

  When the user presses `n` on the Board grid, this prompt opens
  asking for a task description. On submit, it creates a Board card,
  starts an agent session, attaches the session to the card, and
  sends the task as the initial prompt.
  """

  alias Minga.Agent.Config, as: AgentConfig
  alias Minga.Agent.Session, as: AgentSession
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Shell.Board.Card
  alias Minga.Shell.Board.State, as: BoardState

  @doc "Prompt label shown in the minibuffer."
  @spec label() :: String.t()
  def label, do: "Task"

  @doc "Called when the user submits the prompt text."
  @spec on_submit(String.t(), EditorState.t()) :: EditorState.t()
  def on_submit(text, state) do
    task = String.trim(text)

    if task == "" do
      EditorState.set_status(state, "Task description required")
    else
      dispatch_agent(state, task)
    end
  end

  @doc "Called when the user cancels the prompt."
  @spec on_cancel(EditorState.t()) :: EditorState.t()
  def on_cancel(state), do: state

  # ── Private ────────────────────────────────────────────────────────────

  @spec dispatch_agent(EditorState.t(), String.t()) :: EditorState.t()
  defp dispatch_agent(state, task) do
    board = state.shell_state
    model = resolve_model()

    # Create the card
    {board, card} = BoardState.create_card(board, task: task, model: model, status: :working)
    board = BoardState.focus_card(board, card.id)
    state = %{state | shell_state: board}

    # Start an agent session
    case start_session(model) do
      {:ok, pid} ->
        # Attach the session to the card
        board = BoardState.update_card(state.shell_state, card.id, &Card.attach_session(&1, pid))
        state = %{state | shell_state: board}

        # Monitor the session for :DOWN
        ref = Process.monitor(pid)
        monitors = Map.put(state.buffer_monitors, pid, ref)
        state = %{state | buffer_monitors: monitors}

        # Subscribe the editor to agent events
        AgentSession.subscribe(pid)

        # Store session reference on the agent state so events route correctly
        state = AgentAccess.update_agent(state, &AgentState.set_session(&1, pid))

        # Send the task as the initial prompt
        AgentSession.send_prompt(pid, task)

        Minga.Log.info(:agent, "Board: dispatched agent for '#{task}' (#{model})")
        state

      {:error, reason} ->
        board =
          BoardState.update_card(state.shell_state, card.id, &Card.set_status(&1, :errored))

        state = %{state | shell_state: board}
        EditorState.set_status(state, "Agent dispatch failed: #{inspect(reason)}")
    end
  end

  @spec start_session(String.t()) :: {:ok, pid()} | {:error, term()}
  defp start_session(model) do
    opts = [
      provider_opts: [
        provider: resolve_provider(),
        model: model
      ]
    ]

    case DynamicSupervisor.start_child(
           Minga.Agent.Supervisor,
           {AgentSession, opts}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_model, do: AgentConfig.resolve_model()
  defp resolve_provider, do: AgentConfig.resolve_provider()
end
