defmodule MingaEditor.Remote.FileEditReplayTest do
  @moduledoc """
  Replays file edits that a Session wrote to its durable event log.

  These tests use the real path: the Session encodes the edit, the EventLog stores it as JSON, and `EventReplay` decodes the stored record. A file that did not exist before or after the edit must come back as absent, not as a file whose text is "absent".
  """

  use Minga.Test.SessionCase, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaAgent.EventLog
  alias MingaEditor.Remote.EventReplay
  alias MingaEditor.State.Remote

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    event_log =
      start_supervised!(
        {EventLog, name: nil, db_dir: dir, retention_sweep?: false, health_check: :none}
      )

    session =
      start_test_session(
        provider: Minga.Test.SessionMockProvider,
        provider_opts: [],
        event_log_server: event_log
      )

    :ok = Session.subscribe(session)
    assert :ok = Session.continue(session)
    %{session: session, event_log: event_log, dir: dir}
  end

  test "a created or deleted file replays as absent, and literal \"absent\" text stays text",
       ctx do
    records =
      logged_file_edits(ctx, [
        {"lib/deleted.ex", "original\n", :absent},
        {"lib/created.ex", :absent, "created\n"},
        {"lib/literal.ex", "before", "absent"}
      ])

    assert Enum.map(records, &EventReplay.to_agent_event/1) == [
             {:file_changed, "lib/deleted.ex", "original\n", :absent, "tc-0", "write_file"},
             {:file_changed, "lib/created.ex", :absent, "created\n", "tc-1", "write_file"},
             {:file_changed, "lib/literal.ex", "before", "absent", "tc-2", "write_file"}
           ]
  end

  test "replaying a remote file deletion leaves the open buffer's text alone", ctx do
    [deleted, literal] =
      logged_file_edits(ctx, [
        {"/remote/deleted.ex", "original\n", :absent},
        {"/remote/literal.ex", "before", "absent"}
      ])

    state = Minga.Test.ScopedInputHelpers.base_state([])
    state = %{state | frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: nil}}
    deleted_buffer = start_supervised!({BufferProcess, content: "original\n"}, id: :deleted)
    literal_buffer = start_supervised!({BufferProcess, content: "before"}, id: :literal)

    remote =
      state.remote
      |> Remote.put_buffer("remote-server", "/remote/deleted.ex", deleted_buffer)
      |> Remote.put_buffer("remote-server", "/remote/literal.ex", literal_buffer)

    state = %{state | remote: remote}
    _state = EventReplay.replay_active(state, ctx.session, [deleted, literal])

    assert BufferProcess.content(deleted_buffer) == "original\n"
    assert BufferProcess.content(literal_buffer) == "absent"
  end

  defp logged_file_edits(%{session: session, event_log: event_log, dir: dir}, edits) do
    edits
    |> Enum.with_index()
    |> Enum.each(fn {{path, before_content, after_content}, index} ->
      tool_call_id = "tc-#{index}"

      send_provider_event(session, %Event.ToolStart{
        tool_call_id: tool_call_id,
        name: "write_file",
        args: %{"path" => path}
      })

      send_provider_event(session, %Event.ToolFileChanged{
        tool_call_id: tool_call_id,
        path: path,
        before_content: before_content,
        after_content: after_content
      })

      assert_receive {:agent_event, ^session, {:file_changed, _, ^path, _, _, _, _}}, 2_000
    end)

    assert :ok = EventLog.await_idle(event_log)
    {:ok, db} = EventLog.open_read_connection(db_dir: dir)
    on_exit(fn -> EventLog.Store.close(db) end)
    {:ok, records} = EventLog.events_after(db, Session.session_id(session), 0)
    Enum.filter(records, &(&1.event_type == :file_edit_proposed))
  end
end
