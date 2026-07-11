defmodule MingaAgent.SessionPersistenceTest do
  use Minga.Test.SessionCase, async: true

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

    test "load_session replaces messages" do
      session = start_subscribed_session()
      _id = Session.session_id(session)

      SessionStore.save(%{
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
      })

      :ok = Session.load_session(session, "loaded-session")

      assert Session.session_id(session) == "loaded-session"
      messages = Session.messages(session)
      user_msgs = Enum.filter(messages, &match?({:user, _}, &1))
      assert [{:user, "loaded message"}] = user_msgs
    end

    test "load_session returns error for missing session" do
      session = start_subscribed_session()
      assert {:error, _} = Session.load_session(session, "nonexistent")
    end

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
          usage: %MingaAgent.TurnUsage{
            input: 20,
            output: 10,
            cache_read: 0,
            cache_write: 0,
            cost: 0.02
          },
          branches: [
            Branch.new("branch-1", [{:user, "branched prompt"}, {:assistant, "branched reply"}])
          ],
          memory: "- [2026-01-01 00:00 UTC] Prefer direct answers\n"
        },
        dir
      )

      assert :ok = Session.load_session(session, "resumable-session")
      assert Session.session_id(session) == "resumable-session"
      assert Session.messages(session) == [{:user, "Restore me"}, {:assistant, "Restored reply"}]

      meta = Session.metadata(session)
      assert meta.model_name == "anthropic:claude-sonnet-4"
      assert meta.provider_name == "native"
      assert meta.turn_count == 1
      assert DateTime.to_iso8601(meta.last_message_at) == "2026-01-02T00:00:00Z"
      assert MingaAgent.Memory.read(dir) =~ "Prefer direct answers"

      assert {:ok, branches} = Session.list_branches(session)
      assert branches =~ "branch-1"
      assert :ok = Session.switch_branch(session, 1)

      assert Session.messages(session) == [
               {:user, "branched prompt"},
               {:assistant, "branched reply"}
             ]
    end

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
  end
end
