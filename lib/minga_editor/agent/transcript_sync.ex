defmodule MingaEditor.Agent.TranscriptSync do
  @moduledoc """
  The one transcript read the Editor has out to its active local Session.

  A stream batch, a committed message change or a refresh asks for the transcript changes since the projection's cursor, and the Editor never waits for the answer: the Session replies into the Editor's mailbox (`:gen_server.send_request/2`), so a Session busy with a turn never stalls typing (#4296).

  While a read is out, a further ask for the same Session only marks the read dirty. A burst of batches therefore costs one more read when the reply lands, never one read per batch, and the last change is never lost.

  A reply is installed only while its Session is still the active one, no arrival is pending for it, and the projection still sits at the cursor the read started from. Otherwise the reply is dropped: a newer cursor is never overwritten by an older read. A reply dropped because the cursor moved, or one that arrived dirty, reads the Session again. A reply for a Session that is no longer active, or whose arrival is pending, is only dropped: the tab switch or the arrival owns the next read. An ask for another Session abandons the outstanding read. A Session that dies with a read out clears it.
  """

  alias MingaAgent.Session
  alias MingaAgent.Session.Transcript
  alias MingaEditor.Agent.Arrival
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState

  @type cursor :: :snapshot | Transcript.Cursor.t()

  @type t :: %__MODULE__{
          session: pid(),
          request: :gen_server.request_id(),
          cursor: cursor(),
          dirty?: boolean()
        }
  @enforce_keys [:session, :request, :cursor]
  defstruct [:session, :request, :cursor, dirty?: false]

  @doc "Asks the local Session for the transcript changes since the projection's cursor, without waiting."
  @spec request(EditorState.t(), pid()) :: EditorState.t()
  def request(
        %EditorState{agent_connection: %{transcript_sync: %__MODULE__{session: session} = sync}} =
          state,
        session
      ),
      do: EditorState.install_agent_transcript_sync(state, %{sync | dirty?: true})

  def request(%EditorState{agent_connection: %{transcript_sync: outstanding}} = state, session)
      when is_pid(session) and node(session) == node() do
    abandon(outstanding)
    cursor = source_cursor(state)

    EditorState.install_agent_transcript_sync(state, %__MODULE__{
      session: session,
      request: Session.request_editor_transcript(session, cursor),
      cursor: cursor
    })
  end

  @doc "Handles the outstanding read's reply or its Session's exit; anything else is unrelated."
  @spec response(EditorState.t(), term()) :: {:handled, EditorState.t()} | :unrelated
  def response(
        %EditorState{agent_connection: %{transcript_sync: %__MODULE__{request: request} = sync}} =
          state,
        message
      ) do
    case :gen_server.check_response(message, request) do
      :no_reply ->
        :unrelated

      {:reply, transcript} ->
        {:handled,
         state |> EditorState.install_agent_transcript_sync(nil) |> answered(sync, transcript)}

      {:error, {_reason, _server}} ->
        {:handled, EditorState.install_agent_transcript_sync(state, nil)}
    end
  end

  def response(%EditorState{}, _message), do: :unrelated

  @spec answered(EditorState.t(), t(), Session.editor_arrival_transcript()) :: EditorState.t()
  defp answered(state, %__MODULE__{session: session, cursor: cursor, dirty?: dirty?}, transcript) do
    cond do
      not active?(state, session) ->
        state

      source_cursor(state) != cursor ->
        request(state, session)

      dirty? ->
        state
        |> AgentLifecycle.install_transcript_reply(transcript)
        |> request(session)

      true ->
        AgentLifecycle.install_transcript_reply(state, transcript)
    end
  end

  @spec active?(EditorState.t(), pid()) :: boolean()
  defp active?(state, session) do
    Runtime.active_session(state.shell_runtime) == session and
      not Arrival.pending?(state, session)
  end

  @spec source_cursor(EditorState.t()) :: cursor()
  defp source_cursor(state),
    do: state.workspace.agent_ui.panel.transcript.source_cursor || :snapshot

  @spec abandon(t() | nil) :: :ok
  defp abandon(nil), do: :ok

  defp abandon(%__MODULE__{request: request}) do
    _ = :gen_server.receive_response(request, 0)
    :ok
  end
end
