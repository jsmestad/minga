defmodule Minga.Test.TranscriptSyncDriver do
  @moduledoc """
  Delivers the Session's answer to an outstanding transcript read in a test that drives Editor workflows on a state value.

  The Editor reads the transcript without waiting (`MingaEditor.Agent.TranscriptSync`); its reply lands in the mailbox of the process that sent the read. A test that plays the Editor's part calls `settle/1` where the Editor would handle that message.
  """

  alias MingaEditor.Agent.TranscriptSync

  @doc "Handles the outstanding read's replies (and any read a dirty reply sends) until none is out."
  @spec settle(MingaEditor.State.t(), timeout()) :: MingaEditor.State.t()
  def settle(state, timeout \\ 1_000)
  def settle(%{agent_connection: %{transcript_sync: nil}} = state, _timeout), do: state

  def settle(state, timeout) do
    receive do
      {[:alias | _], _reply} = message -> handle(state, message, timeout)
      {:DOWN, _ref, :process, _pid, _reason} = message -> handle(state, message, timeout)
    after
      timeout -> raise "the Session did not answer the Editor's transcript read in #{timeout} ms"
    end
  end

  defp handle(state, message, timeout) do
    case TranscriptSync.response(state, message) do
      {:handled, state} -> settle(state, timeout)
      :unrelated -> settle(state, timeout)
    end
  end
end
