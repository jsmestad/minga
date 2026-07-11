defmodule MingaAgent.SessionQueueTest do
  use Minga.Test.SessionCase, async: true

  describe "combine_queue_entries_to_text/1" do
    test "formats string and content-part queues" do
      text_parts = [
        %ReqLLM.Message.ContentPart{type: :text, text: "hello "},
        %ReqLLM.Message.ContentPart{type: :image, text: nil},
        %ReqLLM.Message.ContentPart{type: :text, text: "world"}
      ]

      cases = [
        {[], ""},
        {["hello"], "hello"},
        {["first", "second", "third"], "first\n\nsecond\n\nthird"},
        {[text_parts], "hello world"},
        {["string entry", [%ReqLLM.Message.ContentPart{type: :text, text: "part text"}]],
         "string entry\n\npart text"}
      ]

      for {entries, expected} <- cases do
        assert Session.combine_queue_entries_to_text(entries) == expected
      end
    end
  end

  describe "message queuing during streaming" do
    test "queues steering and follow-up messages during streaming and broadcasts each enqueue" do
      session = start_slow_turn()

      assert {:queued, :steering} = Session.send_prompt(session, "steer 1")
      assert_receive {:agent_event, _, {:prompt_queued, "steer 1", :steering}}, @event_timeout

      assert {:queued, :steering} = Session.send_prompt(session, "steer 2")
      assert_receive {:agent_event, _, {:prompt_queued, "steer 2", :steering}}, @event_timeout

      assert {:queued, :follow_up} = Session.queue_follow_up(session, "follow")
      assert_receive {:agent_event, _, {:prompt_queued, "follow", :follow_up}}, @event_timeout

      assert Session.get_queued_messages(session) == {["steer 1", "steer 2"], ["follow"]}

      Session.clear_queues(session)
      finish_slow_turn(session)
    end

    test "dequeue_steering returns steering, keeps follow-up, and records user messages" do
      session = start_slow_turn()

      Session.send_prompt(session, "steer me")
      Session.queue_follow_up(session, "follow up later")

      assert Session.dequeue_steering(session) == ["steer me"]
      assert Session.get_queued_messages(session) == {[], ["follow up later"]}
      assert Enum.any?(Session.messages(session), &match?({:user, "steer me"}, &1))

      Session.clear_queues(session)
      finish_slow_turn(session)
    end

    test "recall, clear, and new_session empty queued messages" do
      recalled = start_slow_turn()
      Session.send_prompt(recalled, "steer")
      Session.queue_follow_up(recalled, "follow")
      assert Session.recall_queues(recalled) == {["steer"], ["follow"]}
      assert Session.get_queued_messages(recalled) == {[], []}
      finish_slow_turn(recalled)

      cleared = start_slow_turn()
      Session.send_prompt(cleared, "steer")
      Session.queue_follow_up(cleared, "follow")
      assert :ok = Session.clear_queues(cleared)
      assert Session.get_queued_messages(cleared) == {[], []}
      finish_slow_turn(cleared)

      reset = start_slow_turn()
      Session.send_prompt(reset, "steer")
      Session.queue_follow_up(reset, "follow")
      assert :ok = Session.new_session(reset)
      assert Session.get_queued_messages(reset) == {[], []}
    end

    test "queue_follow_up when idle sends immediately like send_prompt" do
      session = start_subscribed_session(Minga.Test.SessionSlowMockProvider)

      assert :ok = Session.queue_follow_up(session, "immediate follow-up")
      assert_receive {:agent_event, _, :messages_changed}, @event_timeout
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout
      assert Enum.any?(Session.messages(session), &match?({:user, "immediate follow-up"}, &1))

      finish_slow_turn(session)
    end
  end

  describe "follow-up auto-send at AgentEnd" do
    test "queued single-message follow-ups are auto-sent when the agent finishes" do
      cases = [
        {:follow_up, "now follow up",
         fn session, text -> Session.queue_follow_up(session, text) end},
        {:steering, "steering msg", fn session, text -> Session.send_prompt(session, text) end}
      ]

      for {kind, text, enqueue} <- cases do
        session = start_slow_turn()
        assert {:queued, ^kind} = enqueue.(session, text)

        Minga.Test.SessionSlowMockProvider.proceed(Session.get_provider(session))
        assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout
        assert Enum.any?(Session.messages(session), &match?({:user, ^text}, &1))
        assert Session.get_queued_messages(session) == {[], []}

        finish_slow_turn(session)
      end
    end

    test "no queued messages means normal idle transition" do
      session = start_slow_turn("simple")
      finish_slow_turn(session)
    end

    test "mixed steering and follow-up messages are combined at AgentEnd" do
      session = start_slow_turn()

      assert {:queued, :steering} = Session.send_prompt(session, "steer this")
      assert {:queued, :follow_up} = Session.queue_follow_up(session, "and follow up")

      Minga.Test.SessionSlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout
      assert Session.get_queued_messages(session) == {[], []}

      messages = Session.messages(session)

      assert Enum.any?(messages, fn
               {:user, text} ->
                 String.contains?(text, "steer this") and String.contains?(text, "and follow up")

               _ ->
                 false
             end)

      finish_slow_turn(session)
    end
  end

  # ── Stable message IDs ───────────────────────────────────────────────────
end
