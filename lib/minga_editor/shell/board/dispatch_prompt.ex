defmodule MingaEditor.Shell.Board.DispatchPrompt do
  @moduledoc """
  Prompt handler for dispatching a new agent from The Board.

  When the user presses `n` on the Board grid, this prompt opens
  asking for a task description. On submit, it creates a Board card,
  starts an agent session, attaches the session to the card, and
  sends the task as the initial prompt.
  """

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Session, as: AgentSession
  alias MingaAgent.SessionManager
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Shell.Board.Card
  alias MingaEditor.Shell.Board.State, as: BoardState

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
    state = EditorState.update_shell_state(state, fn _ -> board end)

    # Start an agent session
    case start_session(model) do
      {:ok, pid} ->
        # Attach the session to the card
        state =
          EditorState.update_shell_state(state, fn b ->
            BoardState.update_card(b, card.id, &Card.attach_session(&1, pid))
          end)

        # Card.session is the source of truth for routing; the rendering
        # cache on state.shell_state.agent is populated when the card is
        # zoomed into via AgentActivation.activate_for_card/2.

        handle_initial_prompt_result(state, pid, card.id, task, model)

      {:error, reason} ->
        state =
          EditorState.update_shell_state(state, fn b ->
            BoardState.update_card(b, card.id, &Card.set_status(&1, :errored))
          end)

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

    case SessionManager.start_session(opts) do
      {:ok, _session_id, pid} ->
        subscribe_session(pid)

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec subscribe_session(pid()) :: {:ok, pid()} | {:error, term()}
  defp subscribe_session(pid) do
    AgentSession.subscribe(pid)
    {:ok, pid}
  catch
    :exit, reason ->
      stop_session(pid)
      {:error, reason}
  end

  @spec handle_initial_prompt_result(
          EditorState.t(),
          pid(),
          Card.id(),
          String.t(),
          String.t()
        ) :: EditorState.t()
  defp handle_initial_prompt_result(state, pid, card_id, task, model) do
    case send_initial_prompt(pid, task) do
      :ok ->
        Minga.Log.info(:agent, "Board: dispatched agent for '#{task}' (#{model})")
        state

      {:queued, :steering} ->
        Minga.Log.info(:agent, "Board: queued dispatch for '#{task}' (#{model})")
        state

      {:error, reason} ->
        handle_initial_prompt_error(state, pid, card_id, reason)
    end
  end

  @spec handle_initial_prompt_error(EditorState.t(), pid(), Card.id(), term()) :: EditorState.t()
  defp handle_initial_prompt_error(state, pid, card_id, reason) do
    stop_session(pid)

    state
    |> EditorState.update_shell_state(fn b ->
      BoardState.update_card(b, card_id, &mark_card_errored/1)
    end)
    |> EditorState.set_status("Agent dispatch failed: #{inspect(reason)}")
  end

  @spec mark_card_errored(Card.t()) :: Card.t()
  defp mark_card_errored(card) do
    card
    |> Card.set_status(:errored)
    |> Card.detach_session()
  end

  @spec send_initial_prompt(pid(), String.t()) :: :ok | {:queued, :steering} | {:error, term()}
  defp send_initial_prompt(pid, task) do
    AgentSession.send_prompt(pid, task)
  catch
    :exit, reason -> {:error, reason}
  end

  @spec stop_session(pid()) :: :ok | {:error, :not_found}
  defp stop_session(pid) do
    SessionManager.stop_session_by_pid(pid)
  catch
    :exit, _ -> :ok
  end

  defp resolve_model, do: AgentConfig.resolve_model()
  defp resolve_provider, do: AgentConfig.resolve_provider()
end
