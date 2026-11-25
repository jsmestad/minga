defmodule Minga.Test.TurnRequestDriver do
  @moduledoc """
  Delivers a Session's answer to an outstanding composer send or stop in a test that drives Editor workflows on a state value.

  The Editor sends and stops without waiting (`MingaEditor.Agent.TurnRequest`); the answer lands in the mailbox of the process that asked. A test that plays the Editor's part calls `settle/1` where the Editor would handle that message.
  """

  alias MingaEditor.Agent.TurnRequest

  @doc "Handles the answers to every outstanding send and stop until none is out."
  @spec settle(MingaEditor.State.t(), timeout()) :: MingaEditor.State.t()
  def settle(state, timeout \\ 1_000)

  def settle(%{agent_connection: %{turn_requests: requests}} = state, _timeout)
      when map_size(requests) == 0,
      do: state

  def settle(state, timeout) do
    receive do
      {[:alias | _], _reply} = message -> handle(state, message, timeout)
      {:turn_request_result, _token, _reply} = message -> handle(state, message, timeout)
      {:DOWN, _ref, :process, _pid, _reason} = message -> handle(state, message, timeout)
    after
      timeout -> raise "the Session did not answer the Editor's send or stop in #{timeout} ms"
    end
  end

  defp handle(state, message, timeout) do
    case TurnRequest.response(state, message) do
      {:handled, state} -> settle(state, timeout)
      :unrelated -> settle(state, timeout)
    end
  end
end
