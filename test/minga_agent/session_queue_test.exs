defmodule MingaAgent.SessionQueueTest do
  use Minga.Test.SessionCase, async: true

  alias MingaAgent.DraftSnapshot
  alias MingaAgent.SessionStore
  alias Minga.Test.SessionSlowMockProvider
  alias ReqLLM.Message.ContentPart

  defmodule NotificationInbox do
    @spec notify(atom(), String.t(), pid()) :: :ok
    def notify(trigger, _message, recipient) do
      send(recipient, {:agent_notification, self(), trigger})
      :ok
    end
  end

  defmodule RejectingFollowUp do
    alias Minga.Test.ProviderRequest
    alias Minga.Test.SessionSlowMockProvider

    defdelegate start_link(opts), to: SessionSlowMockProvider
    defdelegate abort(pid, request_id), to: SessionSlowMockProvider
    defdelegate new_session(pid), to: SessionSlowMockProvider
    defdelegate get_state(pid), to: SessionSlowMockProvider
    defdelegate set_model(pid, model), to: SessionSlowMockProvider

    @spec send_prompt(pid(), MingaAgent.Session.Request.t()) ::
            :ok | {:error, :cost_limit_reached}
    def send_prompt(pid, request) do
      case ProviderRequest.text(request) do
        "second" -> {:error, :cost_limit_reached}
        _ -> SessionSlowMockProvider.send_prompt(pid, request)
      end
    end
  end

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
    test "completion notifies only when the queued work is finished" do
      provider = Minga.Test.SessionSlowMockProvider
      session = start_test_session(provider: provider, notifier: {NotificationInbox, self()})
      Session.subscribe(session)

      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:agent_event, ^session, {:text_delta, "first"}}, @event_timeout
      assert {:queued, :follow_up} = Session.queue_follow_up(session, "second")

      provider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, ^session, {:text_delta, "second"}}, @event_timeout
      refute_received {:agent_notification, ^session, :complete}

      provider.proceed(Session.get_provider(session))
      assert_receive {:agent_notification, ^session, :complete}, @event_timeout
      assert_receive {:agent_event, ^session, {:status_changed, :idle}}, @event_timeout
      refute_received {:agent_notification, ^session, :complete}
    end

    test "a queued turn that cannot start reports an error instead of completion" do
      session =
        start_test_session(provider: RejectingFollowUp, notifier: {NotificationInbox, self()})

      Session.subscribe(session)
      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:agent_event, ^session, {:text_delta, "first"}}, @event_timeout
      assert {:queued, :follow_up} = Session.queue_follow_up(session, "second")

      Minga.Test.SessionSlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_notification, ^session, :error}, @event_timeout
      assert_receive {:agent_event, ^session, {:error, message}}, @event_timeout
      assert message =~ "Could not start the queued turn"
      refute_received {:agent_notification, ^session, :complete}
    end

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

    @tag :tmp_dir
    test "a killed persistent Session restores both acknowledged inputs without running either",
         %{tmp_dir: dir} do
      opts = [provider: SessionSlowMockProvider, persist?: true, session_store_dir: dir]
      session = start_test_session(opts)
      Session.subscribe(session)
      assert :ok = Session.send_prompt(session, "Active request")
      assert_receive {:agent_event, ^session, {:status_changed, :thinking}}, @event_timeout

      assert {:queued, :steering} = Session.send_prompt(session, "Steer after the tool")
      assert {:queued, :follow_up} = Session.queue_follow_up(session, "Follow after the turn")
      id = Session.session_id(session)
      monitor = Process.monitor(session)
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^session, :killed}, @event_timeout

      recovered = start_test_session(opts)
      assert :ok = Session.load_session(recovered, id)

      assert Session.get_queued_messages(recovered) ==
               {["Steer after the tool"], ["Follow after the turn"]}

      refute Enum.any?(Session.messages(recovered), fn message ->
               message in [{:user, "Steer after the tool"}, {:user, "Follow after the turn"}]
             end)
    end

    @tag :tmp_dir
    test "retry after a Session crash returns the original saved queue receipt without touching the newer draft",
         %{tmp_dir: dir} do
      opts = [provider: SessionSlowMockProvider, persist?: true, session_store_dir: dir]
      session = start_test_session(opts)
      Session.subscribe(session)
      assert :ok = Session.send_prompt(session, "First request")
      assert_receive {:agent_event, ^session, {:status_changed, :thinking}}, @event_timeout
      id = Session.session_id(session)

      assert {:ok, {^id, request_id, 1} = target} = Session.queue_target(session, id)
      assert_receive {:agent_event, ^session, {:queue_target_changed, ^target}}, @event_timeout
      assert %{queue_target: ^target} = Session.editor_snapshot(session)

      original = %DraftSnapshot{
        text: "keep once",
        cursor: {0, 0},
        attachments: [],
        paste_blocks: []
      }

      assert {:ok, 1} = SessionStore.save_presentation(id, 0, original, dir)
      token = "same-text-submission-001"

      assert {:error, :stale_request} =
               Session.submit_queued_draft(
                 session,
                 {id, "stale-request", 1},
                 :steering,
                 {1, token, [], original.text},
                 original.text
               )

      assert {:ok, 1, ^original} = SessionStore.read_presentation(id, dir)

      assert {:ok, {1, ^token, :steering, 2} = receipt} =
               Session.submit_queued_draft(
                 session,
                 target,
                 :steering,
                 {1, token, [], original.text},
                 original.text
               )

      assert {:ok, 2, nil} = SessionStore.read_presentation(id, dir)
      assert {:ok, {^id, ^request_id, 2}} = Session.queue_target(session, id)

      assert_receive {:agent_event, ^session, {:queue_target_changed, {^id, ^request_id, 2}}},
                     @event_timeout

      monitor = Process.monitor(session)
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^session, :killed}, @event_timeout

      recovered = start_test_session(opts)
      assert :ok = Session.load_session(recovered, id)
      assert {:error, :turn_not_active} = Session.queue_target(recovered, id)
      assert %{queue_target: nil} = Session.editor_snapshot(recovered)

      newer = %DraftSnapshot{
        text: "a newer draft",
        cursor: {0, 0},
        attachments: [],
        paste_blocks: []
      }

      assert {:ok, 3} = SessionStore.save_presentation(id, 2, newer, dir)

      confirmation = make_ref()

      assert :ok =
               Session.request_composer_draft(
                 recovered,
                 id,
                 confirmation,
                 {:reconcile_queue, 1, "other-queue-submission01", 1}
               )

      assert_receive {:composer_draft_result, ^recovered, ^id, ^confirmation,
                      {:error, :queue_receipt_unconfirmed}},
                     @event_timeout

      assert {:ok, ^receipt} =
               Session.submit_queued_draft(
                 recovered,
                 target,
                 :steering,
                 {1, token, [], original.text},
                 original.text
               )

      assert {:ok, 3, ^newer} = SessionStore.read_presentation(id, dir)
      assert Session.get_queued_messages(recovered) == {["keep once"], []}
    end

    @tag :tmp_dir
    test "a new typed follow-up can queue before its first autosave", %{tmp_dir: dir} do
      opts = [provider: SessionSlowMockProvider, persist?: true, session_store_dir: dir]
      session = start_test_session(opts)
      Session.subscribe(session)
      assert :ok = Session.send_prompt(session, "Start")
      assert_receive {:agent_event, ^session, {:status_changed, :thinking}}, @event_timeout
      id = Session.session_id(session)
      assert {:ok, 0, nil} = SessionStore.read_presentation(id, dir)

      assert {:error, :queue_target_unavailable} =
               Session.send_idle_composer(session, id, "Stale Send")

      assert Session.get_queued_messages(session) == {[], []}
      assert {:ok, target} = Session.queue_target(session, id)
      token = "same-text-submission-003"

      assert {:ok, {1, ^token, :follow_up, 1}} =
               Session.submit_queued_draft(
                 session,
                 target,
                 :follow_up,
                 {0, token, [], "Newly typed"},
                 "Newly typed"
               )

      assert {:ok, 1, nil} = SessionStore.read_presentation(id, dir)

      assert {:ok,
              %{
                pending_inputs:
                  {2, [], [{1, 1, "Newly typed", [], nil}], [{1, ^token, :follow_up, 1}]}
              }} =
               SessionStore.load(id, dir)
    end

    @tag :tmp_dir
    test "saved Stop recalls only the requested turn and preserves the current draft", %{
      tmp_dir: dir
    } do
      session =
        start_test_session(
          provider: SessionSlowMockProvider,
          persist?: true,
          session_store_dir: dir
        )

      assert :ok = Session.send_prompt(session, "Original")
      id = Session.session_id(session)
      assert %{stop_target: original} = Session.editor_snapshot(session)
      assert {:ok, []} = Session.stop_turn(session, original)
      assert :ok = Session.send_prompt(session, "Replacement")
      assert %{stop_target: replacement} = Session.editor_snapshot(session)
      assert original != replacement
      assert {:queued, :follow_up} = Session.queue_follow_up(session, "Still queued")

      draft = %DraftSnapshot{
        text: "Keep draft",
        cursor: {0, 0},
        attachments: [],
        paste_blocks: []
      }

      assert {:ok, 1} = SessionStore.save_presentation(id, 0, draft, dir)

      stale = make_ref()

      assert :ok =
               Session.request_composer_draft(
                 session,
                 id,
                 stale,
                 {:recall, 1, draft, {:stop, original}}
               )

      assert_receive {:composer_draft_result, ^session, ^id, ^stale, {:error, :stale_turn}},
                     @event_timeout

      assert %{stop_target: ^replacement} = Session.editor_snapshot(session)
      assert Session.get_queued_messages(session) == {[], ["Still queued"]}
      assert {:ok, 1, ^draft} = SessionStore.read_presentation(id, dir)

      current = make_ref()

      assert :ok =
               Session.request_composer_draft(
                 session,
                 id,
                 current,
                 {:recall, 1, draft, {:stop, replacement}}
               )

      assert_receive {:composer_draft_result, ^session, ^id, ^current, {:ok, 2, recalled}},
                     @event_timeout

      assert %{stop_target: nil} = Session.editor_snapshot(session)
      assert recalled.text == "Still queued\n\nKeep draft"
      assert {:ok, 2, ^recalled} = SessionStore.read_presentation(id, dir)
      assert Session.get_queued_messages(session) == {[], []}
    end

    @tag :tmp_dir
    test "a resolved image mention and an ordinary entry both recall after restart", %{
      tmp_dir: dir
    } do
      opts = [provider: SessionSlowMockProvider, persist?: true, session_store_dir: dir]
      session = start_test_session(opts)
      assert :ok = Session.send_prompt(session, "Start")
      assert :ok = Session.subscribe(session)
      id = Session.session_id(session)
      assert {:ok, target} = Session.queue_target(session, id)
      source = "Inspect @diagram.png"

      content = [
        ContentPart.text("Inspect "),
        ContentPart.image_url("https://example.test/diagram.png")
      ]

      token = "image-mention-queue-0001"

      assert {:ok, {1, ^token, :follow_up, 1}} =
               Session.submit_queued_draft(
                 session,
                 target,
                 :follow_up,
                 {0, token, [], source},
                 content
               )

      assert {:queued, :follow_up} = Session.queue_follow_up(session, "Then check the title")

      assert_receive {:agent_event, ^session, {:prompt_queued, ^source, :follow_up}},
                     @event_timeout

      monitor = Process.monitor(session)
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^session, :killed}, @event_timeout

      recovered = start_test_session(opts)
      assert :ok = Session.load_session(recovered, id)
      assert Session.get_queued_messages(recovered) == {[], [content, "Then check the title"]}

      ref = make_ref()
      :ok = Session.request_composer_draft(recovered, id, ref, {:recall, 1, nil, :keep_running})

      assert_receive {:composer_draft_result, ^recovered, ^id, ^ref, {:ok, 2, recalled}},
                     @event_timeout

      assert recalled.text == "Inspect @diagram.png\n\nThen check the title"
      assert {:ok, 2, ^recalled} = SessionStore.read_presentation(id, dir)
      assert Session.get_queued_messages(recovered) == {[], []}
    end

    @tag :tmp_dir
    test "a late queue removal cannot change the already admitted request or withdraw a later item",
         %{tmp_dir: dir} do
      session =
        start_test_session(
          provider: SessionSlowMockProvider,
          persist?: true,
          session_store_dir: dir
        )

      Session.subscribe(session)
      assert :ok = Session.send_prompt(session, "First")
      assert_receive {:agent_event, ^session, {:status_changed, :thinking}}, @event_timeout
      id = Session.session_id(session)
      assert {:queued, :steering} = Session.send_prompt(session, "initial instruction")
      assert {:queued, :follow_up} = Session.queue_follow_up(session, "remove this")
      assert {:queued, :follow_up} = Session.queue_follow_up(session, "keep this order")

      assert {:ok,
              [
                %{identity: {1, 1}, kind: :steering, preview: "initial instruction"},
                %{identity: {2, 1}, kind: :follow_up, preview: "remove this"},
                %{identity: {3, 1}, kind: :follow_up, preview: "keep this order"}
              ]} = Session.queued_input_summaries(session, id)

      assert {:error, :stale_target} = Session.queued_input_summaries(session, "wrong-record")

      assert :ok = Session.change_queued_input(session, id, {1, 1}, {:replace_text, "revised"})

      assert {:error, :stale_queue_revision} =
               Session.change_queued_input(session, id, {1, 1}, :remove)

      assert :ok = Session.change_queued_input(session, id, {2, 1}, :remove)

      assert {:ok, [%{identity: {1, 2}, preview: "revised"}, %{identity: {3, 1}}]} =
               Session.queued_input_summaries(session, id)

      SessionSlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, ^session, {:status_changed, :thinking}}, @event_timeout
      assert {:queued, :follow_up} = Session.queue_follow_up(session, "later")

      assert {:error, :already_consumed} =
               Session.change_queued_input(session, id, {1, 2}, :remove)

      assert {:ok, %{continuation: %{active_request: %{messages: admitted}}}} =
               SessionStore.load(id, dir)

      assert [%ReqLLM.Message{role: :user, content: [part]} | _] = Enum.reverse(admitted)
      assert part == ContentPart.text("revised\n\nkeep this order")
      assert Session.get_queued_messages(session) == {[], ["later"]}
    end

    @tag :tmp_dir
    test "queued follow-up retains the exact image in the admitted provider request", %{
      tmp_dir: dir
    } do
      session =
        start_test_session(
          provider: SessionSlowMockProvider,
          persist?: true,
          session_store_dir: dir
        )

      Session.subscribe(session)
      assert :ok = Session.send_prompt(session, "First")
      assert_receive {:agent_event, ^session, {:status_changed, :thinking}}, @event_timeout

      caption = ContentPart.text("Use this image")
      image = ContentPart.image_url("https://example.test/fixture.png")
      assert {:queued, :steering} = Session.send_prompt(session, "Change direction")
      assert {:queued, :follow_up} = Session.queue_follow_up(session, [caption, image])

      SessionSlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, ^session, {:status_changed, :thinking}}, @event_timeout

      assert {:ok, %{continuation: %{active_request: %{messages: admitted}}}} =
               SessionStore.load(Session.session_id(session), dir)

      assert [%{role: :user, content: [prefix, separator, ^caption, ^image]} | _] =
               Enum.reverse(admitted)

      assert prefix == ContentPart.text("Change direction")
      assert separator == ContentPart.text("\n\n")
      finish_slow_turn(session)
    end
  end

  # ── Stable message IDs ───────────────────────────────────────────────────
end
