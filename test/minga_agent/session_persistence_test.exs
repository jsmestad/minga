defmodule MingaAgent.SessionPersistenceTest do
  use Minga.Test.SessionCase, async: true
  alias MingaAgent.Branch
  alias MingaAgent.TranscriptEntry

  describe "session persistence" do
    test "session has a unique ID" do
      session = start_subscribed_session()
      id = Session.session_id(session)
      assert is_binary(id)
      assert String.length(id) > 0
    end

    test "new_session generates a new ID" do
      session = start_subscribed_session()
      id1 = Session.session_id(session)
      :ok = Session.new_session(session)
      id2 = Session.session_id(session)
      assert id1 != id2
    end

    @tag :tmp_dir
    test "load_session replaces messages", %{tmp_dir: dir} do
      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [],
          session_store_dir: dir
        )

      Session.subscribe(session)
      _id = Session.session_id(session)

      SessionStore.save(
        %{
          id: "loaded-session",
          timestamp: DateTime.to_iso8601(DateTime.utc_now()),
          model_name: "test-model",
          messages: [{:user, "loaded message"}, {:assistant, "loaded reply"}],
          usage: %MingaAgent.TurnUsage{
            input: 500,
            output: 200,
            cache_read: 0,
            cache_write: 0,
            cost: 0.01
          }
        },
        dir
      )

      :ok = Session.load_session(session, "loaded-session")

      assert Session.session_id(session) == "loaded-session"
      messages = Session.messages(session)
      user_msgs = Enum.filter(messages, &match?({:user, _}, &1))
      assert [{:user, "loaded message"}] = user_msgs
    end

    @tag :tmp_dir
    test "load_session returns error for missing session", %{tmp_dir: dir} do
      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [],
          session_store_dir: dir
        )

      assert {:error, _} = Session.load_session(session, "nonexistent")
    end

    @tag :tmp_dir
    test "load_session restores messages, model, provider metadata, and branches", %{tmp_dir: dir} do
      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [],
          session_store_dir: dir
        )

      SessionStore.save(
        %{
          id: "resumable-session",
          timestamp: "2026-01-01T00:00:00Z",
          last_message_at: "2026-01-02T00:00:00Z",
          title: "Restore me",
          model_name: "anthropic:claude-sonnet-4",
          provider_name: "native",
          messages: [{:user, "Restore me"}, {:assistant, "Restored reply"}],
          message_ids: [7, 13],
          pinned_ids: MapSet.new([13]),
          usage: %MingaAgent.TurnUsage{
            input: 20,
            output: 10,
            cache_read: 0,
            cache_write: 0,
            cost: 0.02
          },
          branches: [
            Branch.new(
              "branch-1",
              [
                TranscriptEntry.new(1, {:user, "branched prompt"}),
                TranscriptEntry.new(2, {:assistant, "branched reply"})
              ],
              ~U[2026-01-01 00:00:00Z]
            )
          ],
          memory: "- [2026-01-01 00:00 UTC] Prefer direct answers\n"
        },
        dir
      )

      assert :ok = Session.load_session(session, "resumable-session")
      assert Session.session_id(session) == "resumable-session"
      assert Session.messages(session) == [{:user, "Restore me"}, {:assistant, "Restored reply"}]

      assert Session.messages_with_ids(session) == [
               {7, {:user, "Restore me"}},
               {13, {:assistant, "Restored reply"}}
             ]

      assert Session.pinned_ids(session) == MapSet.new([13])

      meta = Session.metadata(session)
      assert meta.model_name == "anthropic:claude-sonnet-4"
      assert meta.provider_name == "native"
      assert meta.turn_count == 1
      assert DateTime.to_iso8601(meta.last_message_at) == "2026-01-02T00:00:00Z"
      assert MingaAgent.Memory.read(dir) =~ "Prefer direct answers"

      assert {:ok, branches} = Session.list_branches(session)
      assert branches =~ "branch-1"
      assert :ok = Session.switch_branch(session, 0)

      assert Session.messages(session) == [
               {:user, "branched prompt"},
               {:assistant, "branched reply"}
             ]

      assert :ok = Session.switch_branch(session, 1)

      assert Session.messages(session) == [
               {:user, "branched prompt"},
               {:assistant, "branched reply"}
             ]
    end

    @tag :tmp_dir
    test "load_session leaves existing memory untouched for legacy sessions without a memory snapshot",
         %{
           tmp_dir: dir
         } do
      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [],
          session_store_dir: dir
        )

      :ok = MingaAgent.Memory.append("keep this memory", dir)
      sessions_dir = SessionStore.sessions_dir(dir)
      File.mkdir_p!(sessions_dir)

      File.write!(
        Path.join(sessions_dir, "legacy-session.json"),
        JSON.encode!(%{
          "id" => "legacy-session",
          "timestamp" => "2026-01-01T00:00:00Z",
          "last_message_at" => "2026-01-01T00:00:00Z",
          "title" => "Legacy",
          "model_name" => "test-model",
          "provider_name" => "native",
          "messages" => [%{"type" => "user", "text" => "legacy prompt"}],
          "usage" => %{}
        })
      )

      assert :ok = Session.load_session(session, "legacy-session")
      assert MingaAgent.Memory.read(dir) =~ "keep this memory"
    end

    @tag :tmp_dir
    test "load_session saves the current dirty session before replacement", %{tmp_dir: dir} do
      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [],
          persist?: true,
          session_store_dir: dir
        )

      current_id = Session.session_id(session)
      Session.add_system_message(session, "unsaved local note")
      assert {:system, "unsaved local note", :info} in Session.messages(session)

      SessionStore.save(
        %{
          id: "target-session",
          timestamp: "2026-01-01T00:00:00Z",
          last_message_at: "2026-01-01T00:00:00Z",
          title: "Target",
          model_name: "test-model",
          provider_name: "native",
          messages: [{:user, "target prompt"}],
          usage: %MingaAgent.TurnUsage{}
        },
        dir
      )

      assert :ok = Session.load_session(session, "target-session")
      assert {:ok, saved_current} = SessionStore.load(current_id, dir)
      assert {:system, "unsaved local note", :info} in saved_current.messages
      assert Session.session_id(session) == "target-session"
    end

    @tag :tmp_dir
    test "load_session aborts active provider work before installing restored state", %{
      tmp_dir: dir
    } do
      session =
        start_test_session(
          provider: Minga.Test.SessionSlowMockProvider,
          provider_opts: [test_pid: self()],
          session_store_dir: dir
        )

      assert :ok = Session.subscribe(session)

      restored_tool = MingaAgent.ToolCall.new("restored-tool", "shell", %{"command" => "pwd"})

      SessionStore.save(
        %{
          id: "target-session",
          timestamp: "2026-01-01T00:00:00Z",
          model_name: "test-model",
          provider_name: "test",
          messages: [{:user, "restored prompt"}, {:tool_call, restored_tool}],
          usage: %MingaAgent.TurnUsage{}
        },
        dir
      )

      assert :ok = Session.send_prompt(session, "still running")
      assert_receive {:agent_event, ^session, {:status_changed, :thinking}}, @event_timeout

      assert :ok = Session.load_session(session, "target-session")
      assert_receive :provider_abort_called, @event_timeout
      assert Session.session_id(session) == "target-session"
      assert Session.status(session) == :idle

      assert [{:user, "restored prompt"}, {:tool_call, %{status: :running}}] =
               Session.messages(session)
    end
  end
end
