defmodule Minga.Test.AgentSessionStart do
  @moduledoc """
  Completes local Agent session starts in tests that drive Editor state directly.

  A session start no longer blocks: it sends a request and returns. A test that holds the Editor state in its own process receives the start's ordered attach event and the manager's reply in its mailbox, exactly as the Editor would. `settle/2` feeds those two messages, and only those, through `MingaEditor.Agent.SessionStart`.
  """

  import ExUnit.Assertions

  alias MingaEditor.Agent.SessionStart
  alias MingaEditor.State, as: EditorState

  @doc "Processes start replies until no start request is outstanding."
  @spec settle(EditorState.t(), timeout()) :: EditorState.t()
  def settle(%EditorState{} = state, timeout \\ 5_000) do
    if map_size(state.agent_connection.session_starts) == 0 do
      state
    else
      state |> next(timeout) |> settle(timeout)
    end
  end

  @spec next(EditorState.t(), timeout()) :: EditorState.t()
  defp next(state, timeout) do
    receive do
      {:agent_event, session, {:session_start_attached, token}} ->
        SessionStart.attached(state, session, token)

      {[:alias | _ref], _reply} = message ->
        handled(state, message)
    after
      timeout -> flunk("expected an Agent session start reply within #{timeout} ms")
    end
  end

  @spec handled(EditorState.t(), term()) :: EditorState.t()
  defp handled(state, message) do
    case SessionStart.response(state, message) do
      {:handled, updated} -> updated
      :unrelated -> state
    end
  end
end
