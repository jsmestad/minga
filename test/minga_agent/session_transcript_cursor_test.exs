defmodule MingaAgent.SessionTranscriptCursorTest do
  use Minga.Test.SessionCase, async: true

  alias MingaAgent.Session.Continuation
  alias MingaAgent.Session.Transcript.Changes
  alias MingaAgent.Session.Transcript.Entry
  alias MingaAgent.Session.Transcript.Snapshot
  alias MingaAgent.TurnUsage

  test "real Session atomically returns coalesced entries, IDs and pins at one cursor" do
    session = start_subscribed_session()
    assert {:snapshot, %Snapshot{} = initial} = Session.transcript_since(session, :snapshot)
    assert {:unchanged, cursor} = Session.transcript_since(session, initial.cursor)
    assert :ok = Session.continue(session)

    send_provider_event(session, %Event.ToolStart{
      tool_call_id: "atomic",
      name: "shell",
      args: %{}
    })

    send_provider_event(session, %Event.ToolUpdate{
      tool_call_id: "atomic",
      name: "shell",
      partial_result: "first"
    })

    send_provider_event(session, %Event.ToolUpdate{
      tool_call_id: "atomic",
      name: "shell",
      partial_result: "current"
    })

    assert {:changes, %Changes{entries: [%Entry{} = tool]}} =
             Session.transcript_since(session, cursor)

    assert {:tool_call, %{id: "atomic", result: "current"}} = tool.message
    assert tool.id == initial.next_id
    assert tool.ordinal == initial.count
    assert :ok = Session.toggle_pin(session, tool.id)

    assert {:changes, changes} = Session.transcript_since(session, cursor)
    assert [%Entry{id: id, message: {:tool_call, %{result: "current"}}}] = changes.entries
    assert changes.pinned_ids == MapSet.new([id])
    assert changes.pins_changed?
    assert changes.count == initial.count + 1
    assert changes.next_id == id + 1
    assert {:unchanged, _} = Session.transcript_since(session, changes.cursor)
    assert {:error, :invalid_cursor} = Session.transcript_since(session, %{})

    assert :ok = Session.toggle_pin(session, id)

    assert {:changes, %{entries: [], pinned_ids: pins, pins_changed?: true}} =
             Session.transcript_since(session, changes.cursor)

    assert pins == MapSet.new()
  end

  test "arrival forwards the current runtime and changed transcript after preceding Session events" do
    session = start_subscribed_session()
    assert {:snapshot, %Snapshot{cursor: cursor}} = Session.transcript_since(session, :snapshot)
    assert :ok = Session.continue(session)
    assert %{active_tools: []} = Session.editor_snapshot(session)

    send_provider_event(session, %Event.ToolStart{
      tool_call_id: "arriving",
      name: "probe",
      args: %{}
    })

    arrival = make_ref()
    request = Session.request_editor_arrival(session, cursor, self(), arrival)
    assert {:reply, :forwarded} = :gen_server.receive_response(request, :infinity)

    assert_receive {:agent_event, ^session, event}
                   when elem(event, 0) in [:tool_started, :editor_arrival_ready]

    assert {:tool_started, "arriving", "probe", %{}} = event

    assert_receive {:agent_event, ^session,
                    {:editor_arrival_ready, ^arrival,
                     {%{active_tools: [{"arriving", "probe"}]},
                      {:replace, :changed, %Snapshot{entries: entries}, 1, nil}}}}

    assert Enum.any?(entries, &match?(%Entry{message: {:tool_call, %{id: "arriving"}}}, &1))
  end

  @tag :tmp_dir
  test "same-PID loads and clears reset old revision-zero cursors without persisting runtime identity",
       %{tmp_dir: dir} do
    session =
      start_test_session(
        provider: Minga.Test.SessionMockProvider,
        provider_opts: [],
        session_store_dir: dir
      )

    assert {:snapshot, initial} = Session.transcript_since(session, :snapshot)

    data = %{
      id: "cursor-load",
      timestamp: "2026-11-15T12:00:00Z",
      model_name: "test-model",
      messages: [{:user, "loaded"}, {:assistant, "reply"}],
      message_ids: [40, 50],
      pinned_ids: MapSet.new([50]),
      continuation: Continuation.new(),
      usage: TurnUsage.new()
    }

    assert :ok = SessionStore.save(data, dir)
    assert :ok = Session.load_session(session, data.id)

    assert {:reset, :reset_generation, %Snapshot{} = loaded} =
             Session.transcript_since(session, initial.cursor)

    assert Enum.map(loaded.entries, &{&1.id, &1.message}) == [
             {40, {:user, "loaded"}},
             {50, {:assistant, "reply"}}
           ]

    assert {:reset, :reset_generation} =
             Session.transcript_history_before(session, initial.cursor, 50, 1)

    assert {:ok, current, [%{id: 40, message: {:user, "loaded"}}], false} =
             Session.transcript_history_before(session, loaded.cursor, 50, 1)

    assert current == loaded.cursor

    assert loaded.pinned_ids == MapSet.new([50])
    assert loaded.next_id == 51
    assert {:unchanged, _} = Session.transcript_since(session, loaded.cursor)

    assert :ok = Session.load_session(session, data.id)

    assert {:reset, :reset_generation, reloaded} =
             Session.transcript_since(session, loaded.cursor)

    assert reloaded.entries != []
    assert :ok = Session.new_session(session)

    assert {:reset, :reset_generation, cleared} =
             Session.transcript_since(session, reloaded.cursor)

    assert [%Entry{id: 1, message: {:system, _, :info}}] = cleared.entries
    assert cleared.next_id == 2
    assert cleared.pinned_ids == MapSet.new()

    assert {:ok, durable} = SessionStore.load(data.id, dir)
    assert durable.messages == data.messages
    assert durable.message_ids == data.message_ids

    record =
      dir
      |> SessionStore.sessions_dir()
      |> Path.join("#{data.id}.json")
      |> File.read!()
      |> JSON.decode!()

    for key <- ["cursor", "incarnation", "generation", "revision", "active", "changes"] do
      refute Map.has_key?(record, key)
    end
  end

  test "foreign Session cursors reset and a dead Session exit is not an empty transcript" do
    first = start_subscribed_session()
    second = start_subscribed_session()
    assert {:snapshot, snapshot} = Session.transcript_since(first, :snapshot)

    assert {:reset, :foreign_incarnation, %Snapshot{entries: [_ | _]}} =
             Session.transcript_since(second, snapshot.cursor)

    GenServer.stop(first, :normal)

    assert {:noproc, {GenServer, :call, _}} =
             catch_exit(Session.transcript_since(first, :snapshot))
  end
end
