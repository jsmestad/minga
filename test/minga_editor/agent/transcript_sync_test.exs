defmodule MingaEditor.Agent.TranscriptSyncTest do
  @moduledoc """
  The Editor reads its active Session's transcript without waiting on it (#4296).

  These tests play the Editor's part on a state value: a read's reply lands in the test process, which hands it to `TranscriptSync.response/2` where the Editor would.
  """

  use Minga.Test.SessionCase, async: true

  alias Minga.Test.TranscriptFixture
  alias Minga.Test.TranscriptSyncDriver
  alias MingaAgent.Session
  alias MingaAgent.Session.Transcript.Cursor
  alias MingaEditor.Agent.Arrival
  alias MingaEditor.Agent.StreamEventWorkflow
  alias MingaEditor.Agent.TranscriptSync
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar

  # Twenty batches together; one that waited on the suspended Session would take its 5 s call timeout.
  @batch_budget_us 1_000_000

  test "stream batches never wait on a busy Session, and a burst costs one more read" do
    session = start_session([{:assistant, "First answer"}])
    state = event_state(session) |> stream() |> TranscriptSyncDriver.settle()
    assert TranscriptFixture.messages(projection(state)) == Session.messages(session)
    assert {:assistant, "First answer"} in Session.messages(session)

    Session.add_system_message(session, "Arrived while busy")
    :sys.get_state(session)
    :ok = :sys.suspend(session)
    :erlang.trace(session, true, [:receive, {:tracer, self()}])

    {elapsed, state} =
      :timer.tc(fn -> Enum.reduce(1..20, state, fn _, acc -> stream(acc) end) end)

    assert elapsed < @batch_budget_us

    assert %TranscriptSync{session: ^session, dirty?: true} =
             state.agent_connection.transcript_sync

    :ok = :sys.resume(session)
    state = TranscriptSyncDriver.settle(state)
    :erlang.trace(session, false, [:receive])
    barrier = :erlang.trace_delivered(session)
    assert_receive {:trace_delivered, ^session, ^barrier}

    assert TranscriptFixture.messages(projection(state)) == Session.messages(session)
    assert transcript_reads(session) == 2
  end

  test "a reply read from an older cursor never replaces a newer projection" do
    session = start_session([{:assistant, "Answer"}])
    :ok = :sys.suspend(session)
    state = event_state(session) |> stream()
    requested = state.agent_connection.transcript_sync

    newer = %Cursor{incarnation: make_ref(), generation: 0, revision: 99}

    state =
      TraditionalWorkflow.install_agent_panel(
        state,
        Panel.install_transcript(
          state.workspace.agent_ui.panel,
          TranscriptProjection.advance_source_cursor(projection(state), newer),
          :keep
        )
      )

    :ok = :sys.resume(session)
    assert {:handled, state} = TranscriptSync.response(state, reply!(requested))

    assert projection(state).source_cursor == newer
    assert TranscriptFixture.messages(projection(state)) == []

    assert %TranscriptSync{session: ^session, cursor: ^newer} =
             state.agent_connection.transcript_sync
  end

  test "a reply for a Session the Editor has left is dropped" do
    left = start_session([{:assistant, "From the Session the user left"}])
    current = start_session([{:assistant, "From the Session on screen"}])
    :ok = :sys.suspend(left)
    state = event_state(left) |> stream()
    requested = state.agent_connection.transcript_sync

    switched = %{event_state(current) | agent_connection: state.agent_connection}
    :ok = :sys.resume(left)
    assert {:handled, switched} = TranscriptSync.response(switched, reply!(requested))

    assert TranscriptFixture.messages(projection(switched)) == []
    assert switched.agent_connection.transcript_sync == nil
  end

  test "a reply that lands while the Session is still arriving is dropped; the arrival owns the read" do
    session = start_session([{:assistant, "Answer"}])
    :ok = :sys.suspend(session)
    state = event_state(session) |> stream()
    requested = state.agent_connection.transcript_sync

    arriving =
      EditorState.install_agent_arrival(state, %Arrival{
        token: make_ref(),
        tab: 1,
        session: session,
        phase: :forwarded
      })

    assert Arrival.pending?(arriving, session)
    :ok = :sys.resume(session)
    assert {:handled, arriving} = TranscriptSync.response(arriving, reply!(requested))

    assert TranscriptFixture.messages(projection(arriving)) == []
    assert arriving.agent_connection.transcript_sync == nil
  end

  test "asking for another Session abandons the read out to the one left behind" do
    left = start_session([{:assistant, "Left"}])
    current = start_session([{:assistant, "Current"}])
    :ok = :sys.suspend(left)
    state = event_state(left) |> stream()

    switched = %{event_state(current) | agent_connection: state.agent_connection} |> stream()
    assert %TranscriptSync{session: ^current} = switched.agent_connection.transcript_sync

    :ok = :sys.resume(left)
    switched = TranscriptSyncDriver.settle(switched)
    assert TranscriptFixture.messages(projection(switched)) == Session.messages(current)
    assert {:assistant, "Current"} in TranscriptFixture.messages(projection(switched))
  end

  test "a Session that dies with a read out clears it without a crash" do
    session = start_session([{:assistant, "Answer"}])
    :ok = :sys.suspend(session)
    state = event_state(session) |> stream()
    %TranscriptSync{request: request} = state.agent_connection.transcript_sync

    Process.unlink(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, _ref, :process, ^session, :killed} = down
    assert {:error, _} = :gen_server.check_response(down, request)
    assert {:handled, state} = TranscriptSync.response(state, down)
    assert state.agent_connection.transcript_sync == nil
  end

  test "a new conversation started while a read is out ends with the new transcript" do
    session = start_session([{:user, "Old question"}, {:assistant, "Old answer"}])
    state = event_state(session) |> stream() |> TranscriptSyncDriver.settle()
    :ok = :sys.suspend(session)
    state = stream(state)

    :ok = :sys.resume(session)
    :ok = Session.new_session(session)
    :ok = Session.seed_messages(session, [{:user, "New question"}])

    state = state |> TranscriptSyncDriver.settle() |> StreamEventWorkflow.messages_changed()
    state = TranscriptSyncDriver.settle(state)

    assert TranscriptFixture.messages(projection(state)) == Session.messages(session)
    refute {:user, "Old question"} in TranscriptFixture.messages(projection(state))
  end

  @spec stream(EditorState.t()) :: EditorState.t()
  defp stream(state), do: StreamEventWorkflow.batch(state, [{:text_delta, "more"}])

  @spec projection(EditorState.t()) :: TranscriptProjection.t()
  defp projection(state), do: state.workspace.agent_ui.panel.transcript

  @spec start_session([MingaAgent.Message.t()]) :: pid()
  defp start_session(messages) do
    session = start_supervised!({Session, provider_opts: []}, id: make_ref())
    :ok = Session.seed_messages(session, messages)
    session
  end

  @spec reply!(TranscriptSync.t()) :: term()
  defp reply!(%TranscriptSync{request: request}) do
    receive do
      {[:alias | _], _reply} = message ->
        assert {:reply, _} = :gen_server.check_response(message, request)
        message
    after
      1_000 -> flunk("the Session did not answer the transcript read")
    end
  end

  @spec transcript_reads(pid()) :: non_neg_integer()
  defp transcript_reads(session) do
    receive do
      {:trace, ^session, :receive, {:"$gen_call", _from, {:editor_transcript, _cursor}}} ->
        1 + transcript_reads(session)

      {:trace, ^session, :receive, _message} ->
        transcript_reads(session)
    after
      0 -> 0
    end
  end

  @spec event_state(pid()) :: EditorState.t()
  defp event_state(session) do
    {tab_bar, workspace} =
      TabBar.add_workspace(TabBar.new(Tab.new_agent(1, "Agent")), "Agent", session)

    tab_bar = TabBar.move_tab_to_workspace(tab_bar, 1, workspace.id)

    %EditorState{
      frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: nil},
      workspace: %SessionState{agent_ui: UIState.new()},
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          TraditionalState.install_tab_bar(
            TraditionalState.replace_agent(%TraditionalState{}, %AgentState{}),
            tab_bar
          )
        )
    }
  end
end
