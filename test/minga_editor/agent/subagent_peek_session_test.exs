defmodule MingaEditor.Agent.SubagentPeekSessionTest do
  use ExUnit.Case, async: true

  import MingaEditor.RenderPipeline.TestHelpers

  alias MingaAgent.Session.Transcript.{Cursor, Entry, Snapshot}
  alias MingaAgent.TranscriptEntry
  alias MingaAgent.TurnUsage
  alias MingaEditor.Agent.SubagentPeekSession, as: PeekSession
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.State

  test "the first child snapshot cannot rewind a writable event or change the parent transcript" do
    cursor = Cursor.new(make_ref(), 0, 1)
    entry = Entry.new(TranscriptEntry.new(1, {:user, "child-only brief"}), 0, 1)

    snapshot =
      Snapshot.new(cursor, [entry], MapSet.new(), TurnUsage.new(), DateTime.utc_now(), 2, 1)

    responder =
      start_supervised!(
        {Task,
         fn ->
           receive do
             {:"$gen_call", from, {:editor_transcript, :snapshot}} ->
               GenServer.reply(from, {:replace, :changed, snapshot, nil})
           end
         end}
      )

    {state, token, child} = connecting(responder)
    parent_transcript = state.workspace.agent_ui.panel.transcript
    state = PeekSession.child_changed(state, %{child | writable?: true})
    state = PeekSession.ready(state, token, {:ok, child})

    assert {:live, %{writable?: true}} = state.agent_connection.peek_session.link
    assert_receive {_, {:replace, :changed, ^snapshot, nil}} = response
    assert {:handled, state} = PeekSession.response(state, response)
    projection = state.agent_connection.peek_session.transcript

    assert Enum.any?(TranscriptProjection.presentation_entries(projection), fn {_key, item} ->
             elem(item, 1) == {:user, "child-only brief"}
           end)

    assert state.workspace.agent_ui.panel.transcript == parent_transcript
  end

  test "disposal during attachment makes its success receipt stale" do
    {state, token, child} = connecting()

    disposed = %{
      manager: child.manager,
      identity: child.identity,
      session_id: child.session_id,
      outcome: :no_worktree
    }

    state = PeekSession.child_disposed(state, disposed)
    state = PeekSession.ready(state, token, {:ok, child})
    assert {:unavailable, :subagent_stopped} = state.agent_connection.peek_session.link
    refute_received {:"$gen_call", _, _}
  end

  defp connecting(pid \\ self()) do
    identity = {"parent", {"request", "checkpoint", "call"}}
    token = make_ref()

    child = %{
      identity: identity,
      session_id: "child",
      pid: pid,
      manager: self(),
      brief: "child-only brief",
      project_root: "/project",
      writable?: false
    }

    peek = %PeekSession{
      identity: identity,
      link: {:connecting, token, nil},
      transcript: TranscriptProjection.new()
    }

    {State.install_subagent_peek_session(base_state(), peek), token, child}
  end
end
