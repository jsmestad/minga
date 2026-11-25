defmodule Minga.Test.AgentSessionStart do
  @moduledoc """
  Completes local Agent session starts in tests that drive Editor state directly.

  A session start no longer blocks: it sends a request and returns. A test that holds the Editor state in its own process receives the start's ordered attach event and the manager's reply in its mailbox, exactly as the Editor would. `settle/2` feeds those two messages, and only those, through `MingaEditor.Agent.SessionStart`.

  Restore, Sessions picker reopen and Inline Ask seed work is sent to the session the same way. `settle_follow_ups/2` feeds the session's replies through `MingaEditor.Agent.SessionFollowUp` until none is outstanding.
  """

  import ExUnit.Assertions

  alias MingaEditor.Agent.SessionFollowUp
  alias MingaEditor.Agent.SessionStart
  alias MingaEditor.State, as: EditorState

  @doc """
  Processes start replies until no start request is outstanding.

  A real session start has no latency contract in a test, so the wait has no deadline of its own by default. Each request monitors the session manager: the manager's reply or its exit ends the wait, and the test deadline bounds it.
  """
  @spec settle(EditorState.t(), timeout()) :: EditorState.t()
  def settle(%EditorState{} = state, timeout \\ :infinity) do
    if map_size(state.agent_connection.session_starts) == 0 do
      state
    else
      state |> next(timeout) |> settle(timeout)
    end
  end

  @doc "Processes follow-up replies until no follow-up request is outstanding."
  @spec settle_follow_ups(EditorState.t(), timeout()) :: EditorState.t()
  def settle_follow_ups(%EditorState{} = state, timeout \\ 5_000) do
    if map_size(state.agent_connection.session_follow_ups) == 0 do
      state
    else
      receive do
        {[:alias | _ref], _reply} = message -> follow_up(state, message)
        {:DOWN, _ref, :process, _pid, _reason} = message -> follow_up(state, message)
      after
        timeout -> flunk("expected an Agent session follow-up reply within #{timeout} ms")
      end
      |> settle_follow_ups(timeout)
    end
  end

  @spec follow_up(EditorState.t(), term()) :: EditorState.t()
  defp follow_up(state, message) do
    case SessionFollowUp.response(state, message) do
      {:handled, updated} -> updated
      :unrelated -> state
    end
  end

  @spec next(EditorState.t(), timeout()) :: EditorState.t()
  defp next(state, timeout) do
    # A request id is the monitor reference of its request.
    requests =
      Map.new(state.agent_connection.session_starts, fn {_token, start} ->
        {start.request, true}
      end)

    receive do
      {:agent_event, session, {:session_start_attached, token}} ->
        SessionStart.attached(state, session, token)

      {[:alias | _ref], _reply} = message ->
        handled(state, message)

      # The manager's exit settles its start as failed; any other monitor's message stays in the mailbox.
      {:DOWN, ref, :process, _pid, _reason} = message when is_map_key(requests, ref) ->
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
