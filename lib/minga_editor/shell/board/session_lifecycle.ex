defmodule MingaEditor.Shell.Board.SessionLifecycle do
  @moduledoc """
  Session lifecycle helpers for Board cards.

  Board cards store agent session PIDs directly, but `MingaAgent.SessionManager` owns process lifecycle and broadcasts stop events. Keeping start/stop here prevents keyboard and GUI Board paths from drifting into different ownership patterns.
  """

  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Session, as: AgentSession
  alias MingaAgent.SessionManager
  alias MingaEditor.Shell.Board.Card
  alias MingaEditor.Shell.Board.State, as: BoardState

  @doc "Starts a managed agent session and subscribes the caller to its events."
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    case SessionManager.start_session(opts) do
      {:ok, _session_id, pid} ->
        subscribe(pid)

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Stops a managed agent session by PID. Unknown or already-dead PIDs are treated as no-ops."
  @spec stop(pid() | nil) :: :ok | {:error, :not_found}
  def stop(pid) when is_pid(pid) do
    SessionManager.stop_session_by_pid(pid)
  catch
    :exit, _ -> :ok
  end

  def stop(nil), do: :ok

  @doc """
  Ensures an agent card has a live session. If the card already has a session
  or is a `:you` card, returns the board unchanged. Otherwise starts a new
  session using the card's persisted model (falling back to the configured default).
  """
  @spec ensure_session(BoardState.t(), Card.t() | nil, MingaEditor.State.t()) ::
          {BoardState.t(), MingaEditor.State.t()}
  def ensure_session(board, nil, state), do: {board, state}

  def ensure_session(board, %Card{session: pid} = _card, state) when is_pid(pid) do
    {board, state}
  end

  def ensure_session(board, %Card{kind: :you}, state) do
    {board, state}
  end

  def ensure_session(board, %Card{id: card_id, model: card_model}, state) do
    model = card_model || AgentConfig.resolve_model()

    opts = [
      provider_opts: [
        provider: AgentConfig.resolve_provider(),
        model: model
      ]
    ]

    case start(opts) do
      {:ok, pid} ->
        board = BoardState.update_card(board, card_id, &Card.attach_session(&1, pid))

        Minga.Log.info(
          :agent,
          "Board: started agent session for persisted card #{card_id} (#{model})"
        )

        {board, state}

      {:error, reason} ->
        Minga.Log.error(
          :agent,
          "Board: failed to start agent for card #{card_id}: #{inspect(reason)}"
        )

        board = BoardState.update_card(board, card_id, &Card.set_status(&1, :errored))
        {board, state}
    end
  end

  @spec subscribe(pid()) :: {:ok, pid()} | {:error, term()}
  defp subscribe(pid) do
    AgentSession.subscribe(pid)
    {:ok, pid}
  catch
    :exit, reason ->
      stop(pid)
      {:error, reason}
  end
end
