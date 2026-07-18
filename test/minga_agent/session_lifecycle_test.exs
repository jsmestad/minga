defmodule MingaAgent.SessionLifecycleTest do
  use Minga.Test.SessionCase, async: true

  describe "initial state" do
    test "starts idle with a system message and zero usage" do
      session = start_subscribed_session()
      assert Session.status(session) == :idle
      assert [{:system, text, :info}] = Session.messages(session)
      assert String.starts_with?(text, "Session started")

      usage = Session.usage(session)
      assert usage.input == 0
      assert usage.output == 0
      assert usage.cost == 0.0
    end

    test "stale provider starts cannot reactivate an idle session" do
      session = start_subscribed_session()

      send_provider_event(session, %Event.AgentStart{})
      assert Session.status(session) == :idle

      assert :ok = Session.continue(session)
      send_provider_event(session, %Event.AgentStart{})
      assert Session.status(session) == :thinking
    end

    test "failed continuation restores the prior terminal state" do
      session = start_test_session(provider: Minga.Test.StubProvider, provider_opts: [])

      send_provider_event(session, %Event.Error{message: "failed turn"})
      assert Session.status(session) == :error

      assert {:error, "Provider does not support continue"} = Session.continue(session)
      assert Session.status(session) == :error
    end

    test "failed prompt submission restores the exact terminal turn state" do
      session =
        start_test_session(
          provider: Minga.Test.StubProvider,
          provider_opts: [send_prompt_result: {:error, :prompt_failed}]
        )

      send_provider_event(session, %Event.Error{message: "failed turn"})
      source_execution = :sys.get_state(session).turn_execution

      assert {:error, :prompt_failed} = Session.send_prompt(session, "retry")
      assert :sys.get_state(session).turn_execution == source_execution
      assert Session.status(session) == :error
    end
  end

  describe "remote attachment roles" do
    test "first subscriber is driver and later subscribers are viewers" do
      session = start_subscribed_session()
      viewer = idle_process()
      on_exit(fn -> Process.exit(viewer, :kill) end)

      assert Session.subscriber_role(session, self()) == :driver
      assert :ok = Session.subscribe(session, viewer)
      assert Session.subscriber_role(session, viewer) == :viewer
    end

    test "viewer cannot send prompts while driver can" do
      session = start_subscribed_session()
      viewer = idle_process()
      on_exit(fn -> Process.exit(viewer, :kill) end)

      assert :ok = Session.subscribe(session, viewer, role: :viewer)
      assert {:error, :not_driver} = Session.send_prompt_as(session, viewer, "nope")
    end

    test "driver role is vacated when the driver process dies" do
      session = start_test_session(provider: Minga.Test.SessionMockProvider, provider_opts: [])
      driver = idle_process()
      viewer = idle_process()

      on_exit(fn ->
        Process.exit(driver, :kill)
        Process.exit(viewer, :kill)
      end)

      assert :ok = Session.subscribe(session, driver, role: :driver)
      assert :ok = Session.subscribe(session, viewer, role: :viewer)

      ref = Process.monitor(driver)
      Process.exit(driver, :kill)
      assert_receive {:DOWN, ^ref, :process, ^driver, :killed}, @event_timeout
      wait_until_subscriber_role(session, driver, nil)

      assert :ok = Session.claim_driver(session, viewer)
      assert Session.subscriber_role(session, viewer) == :driver
    end
  end

  describe "detached session lifecycle" do
    test "supervised sessions defer crash recovery to SessionManager" do
      spec = Session.child_spec(provider: Minga.Test.SessionMockProvider, provider_opts: [])

      assert spec.restart == :temporary
    end

    test "idle detached sessions are reclaimed after the configured timeout" do
      idle_gc_token = make_ref()

      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [],
          idle_gc_timeout_ms: 60_000,
          idle_gc_token_fn: fn -> idle_gc_token end
        )

      client = idle_process()

      on_exit(fn -> Process.exit(client, :kill) end)

      assert :ok = Session.subscribe(session, client)

      ref = Process.monitor(session)
      assert :ok = Session.unsubscribe(session, client)
      send(session, {:idle_gc_timeout, idle_gc_token})
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, @event_timeout
    end

    @tag :tmp_dir
    test "idle detached sessions with persist?: false exit normally without writing", %{
      tmp_dir: dir
    } do
      bad_store_dir = Path.join(dir, "blocked-store")
      File.write!(bad_store_dir, "not a directory")
      idle_gc_token = make_ref()

      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [],
          persist?: false,
          session_store_dir: bad_store_dir,
          idle_gc_timeout_ms: 60_000,
          idle_gc_token_fn: fn -> idle_gc_token end
        )

      client = idle_process()

      on_exit(fn -> Process.exit(client, :kill) end)

      assert :ok = Session.subscribe(session, client)

      ref = Process.monitor(session)
      assert :ok = Session.unsubscribe(session, client)
      send(session, {:idle_gc_timeout, idle_gc_token})
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, @event_timeout
      assert File.read!(bad_store_dir) == "not a directory"
    end

    @tag :tmp_dir
    test "sending a prompt while the idle timer is pending keeps the session alive", %{
      tmp_dir: dir
    } do
      session_store_dir = Path.join(dir, "idle-race")

      idle_gc_token = make_ref()

      session =
        start_test_session(
          provider: Minga.Test.SessionDeferredMockProvider,
          provider_opts: [test_pid: self()],
          session_store_dir: session_store_dir,
          idle_gc_timeout_ms: 60_000,
          idle_gc_token_fn: fn -> idle_gc_token end
        )

      client = idle_process()

      on_exit(fn -> Process.exit(client, :kill) end)

      assert :ok = Session.subscribe(session, client)
      assert :ok = Session.unsubscribe(session, client)
      ref = Process.monitor(session)

      assert :ok = Session.send_prompt(session, "keep working")
      provider = Session.get_provider(session)

      assert_receive {:deferred_provider_prompt_received, ^provider, "keep working"},
                     @event_timeout

      send(session, {:idle_gc_timeout, idle_gc_token})
      assert Session.status(session) == :idle
      refute_receive {:DOWN, ^ref, :process, ^session, :normal}, 50

      assert :ok = Minga.Test.SessionDeferredMockProvider.release_start(provider)
      assert Session.status(session) == :thinking

      assert :ok = Minga.Test.SessionDeferredMockProvider.release_end(provider)
      assert Session.status(session) == :idle
      refute_receive {:DOWN, ^ref, :process, ^session, :normal}, 50
    end

    test "active plan-mode turns reschedule idle GC after finishing" do
      initial_token = make_ref()
      finished_token = make_ref()

      session =
        start_test_session(
          provider: Minga.Test.StubProvider,
          provider_opts: [],
          persist?: false,
          idle_gc_timeout_ms: 60_000,
          idle_gc_token_fn: idle_gc_token_fn([initial_token, finished_token])
        )

      ref = Process.monitor(session)

      assert :ok = Session.enter_plan(session)
      assert :ok = Session.send_prompt(session, "start plan turn")
      send_provider_event(session, %Event.AgentStart{})

      send(session, {:idle_gc_timeout, initial_token})
      assert Session.status(session) == :plan
      refute_receive {:DOWN, ^ref, :process, ^session, :normal}, 50

      send_provider_event(session, %Event.AgentEnd{usage: nil})

      assert Session.status(session) == :plan
      send(session, {:idle_gc_timeout, finished_token})
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, @event_timeout
    end

    test "active detached sessions are not reclaimed" do
      session =
        start_test_session(
          provider: Minga.Test.SessionSlowMockProvider,
          provider_opts: [],
          idle_gc_timeout_ms: 60_000
        )

      {_timer_ref, stale_token} = :sys.get_state(session).idle_gc_timer

      assert :ok = Session.subscribe(session)
      assert :ok = Session.send_prompt(session, "keep working")
      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout
      assert :ok = Session.unsubscribe(session)

      send(session, {:idle_gc_timeout, stale_token})
      assert Session.status(session) == :thinking
    end

    test "active plan-mode turns are not reclaimed" do
      session =
        start_test_session(
          provider: Minga.Test.StubProvider,
          provider_opts: [],
          idle_gc_timeout_ms: 60_000
        )

      assert :ok = Session.enter_plan(session)
      assert :ok = Session.send_prompt(session, "start plan turn")
      send(session, {:agent_provider_event, %Event.AgentStart{}})
      :sys.get_state(session)

      {_timer_ref, token} = :sys.get_state(session).idle_gc_timer
      ref = Process.monitor(session)

      send(session, {:idle_gc_timeout, token})
      assert Session.status(session) == :plan
      refute_receive {:DOWN, ^ref, :process, ^session, :normal}, 50
    end

    test "stale idle GC messages are ignored after a client reconnects" do
      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [],
          idle_gc_timeout_ms: 60_000
        )

      assert :ok = Session.subscribe(session)
      assert :ok = Session.unsubscribe(session)
      {_timer_ref, stale_token} = :sys.get_state(session).idle_gc_timer
      assert :ok = Session.subscribe(session)

      send(session, {:idle_gc_timeout, stale_token})
      assert Session.status(session) == :idle
    end

    @tag :tmp_dir
    test "save_session failures are logged and retried with backoff", %{tmp_dir: dir} do
      bad_store_dir = Path.join(dir, "blocked-store")
      File.write!(bad_store_dir, "not a directory")

      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [],
          persist?: true,
          session_store_dir: bad_store_dir,
          idle_gc_timeout_ms: 60_000
        )

      ref = Process.monitor(session)

      send(session, :save_session)
      state = :sys.get_state(session)

      assert state.persistence.timer != nil
      assert state.persistence.retry_count == 1
      refute_receive {:DOWN, ^ref, :process, ^session, _}, 50
    end

    @tag :tmp_dir
    test "idle detached sessions stay alive when persistence fails", %{tmp_dir: dir} do
      bad_store_dir = Path.join(dir, "blocked-store")
      File.write!(bad_store_dir, "not a directory")

      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [],
          persist?: true,
          session_store_dir: bad_store_dir,
          idle_gc_timeout_ms: 60_000
        )

      {_timer_ref, token} = :sys.get_state(session).idle_gc_timer
      ref = Process.monitor(session)

      send(session, {:idle_gc_timeout, token})
      state = :sys.get_state(session)

      assert state.idle_gc_timer != nil
      assert Session.status(session) == :idle
      assert is_pid(Session.get_provider(session))
      refute_receive {:DOWN, ^ref, :process, ^session, _}, 50
    end
  end

  describe "plan mode" do
    test "enter_plan sets status, broadcasts, and writes a system message" do
      session = start_subscribed_session()
      assert :ok = Session.enter_plan(session)
      assert Session.status(session) == :plan
      assert_receive {:agent_event, _, {:status_changed, :plan}}, @event_timeout

      assert Enum.any?(Session.messages(session), fn
               {:system, text, :info} -> text =~ "Plan mode" and text =~ "/exec"
               _ -> false
             end)
    end

    test "enter_exec leaves plan mode and writes a system message" do
      session = start_subscribed_session()
      assert :ok = Session.enter_plan(session)
      assert :ok = Session.enter_exec(session)
      assert Session.status(session) == :idle
      assert_receive {:agent_event, _, {:status_changed, :plan}}, @event_timeout
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      assert Enum.any?(Session.messages(session), fn
               {:system, text, :info} -> text =~ "Execution mode" and text =~ "/plan"
               _ -> false
             end)
    end

    test "provider write tool is refused through a real plan-mode session" do
      session =
        start_test_session(
          provider: Minga.Test.SessionPlanToolProvider,
          provider_opts: [parent: self()]
        )

      Session.subscribe(session)
      assert :ok = Session.enter_plan(session)
      assert :ok = Session.send_prompt(session, "write a file")

      assert_receive {:provider_tool_result, {:error, {:plan_mode_refused, message}}},
                     @event_timeout

      assert message =~ "Plan mode"
      assert message =~ "write_file"
      assert message =~ "/exec"
      refute_receive {:write_callback_called, _args}, 20

      assert Enum.any?(Session.messages(session), fn
               {:system, text, :info} -> text == message
               _ -> false
             end)
    end

    test "plan mode survives provider events and abort" do
      session = start_subscribed_session()
      assert :ok = Session.enter_plan(session)
      assert :ok = Session.continue(session)

      events = [
        %Event.AgentStart{},
        %Event.ToolStart{tool_call_id: "tc", name: "read_file"},
        %Event.Error{message: "something broke"}
      ]

      for event <- events do
        send_provider_event(session, event)
        assert Session.status(session) == :plan
      end

      assert :ok = Session.abort(session)
      assert Session.status(session) == :plan
    end

    test "AgentEnd preserves plan mode status" do
      session = start_subscribed_session(Minga.Test.SessionSlowMockProvider)

      assert :ok = Session.enter_plan(session)
      assert :ok = Session.send_prompt(session, "hello")
      Minga.Test.SessionSlowMockProvider.proceed(Session.get_provider(session))
      assert_receive {:agent_event, _, :messages_changed}, @event_timeout
      assert Session.status(session) == :plan
    end

    test "enter_exec is a no-op when not in plan mode" do
      session = start_subscribed_session()
      msg_count_before = length(Session.messages(session))
      assert :ok = Session.enter_exec(session)
      assert Session.status(session) == :idle
      assert length(Session.messages(session)) == msg_count_before
    end
  end

  describe "inline read-only safety" do
    test "hooks can be disabled for non-persistent inline sessions" do
      session =
        start_supervised!(
          {Session,
           provider: Minga.Test.StubProvider,
           persist?: false,
           hooks_enabled?: false,
           provider_opts: [provider: :test, model: "test"]},
          id: {:inline_hooks_disabled, make_ref()}
        )

      refute Session.persist?(session)
      refute Session.hooks_enabled?(session)
    end
  end

  describe "send_prompt/2" do
    test "adds messages, broadcasts stream events, and records usage" do
      session = start_subscribed_session()
      :ok = Session.send_prompt(session, "Hello!")

      assert_receive {:agent_event, _, {:status_changed, :thinking}}, @event_timeout
      assert_receive {:agent_event, _, {:text_delta, "Hello "}}, @event_timeout
      assert_receive {:agent_event, _, {:text_delta, "world!"}}, @event_timeout
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      messages = Session.messages(session)
      assert {:system, _, :info} = Enum.at(messages, 0)
      assert {:user, "Hello!"} = Enum.at(messages, 1)
      assert {:assistant, "Hello world!"} = Enum.at(messages, 2)
      assert Enum.any?(messages, &match?({:usage, %{input: 100, output: 50, cost: 0.01}}, &1))

      usage = Session.usage(session)
      assert usage.input == 100
      assert usage.output == 50
      assert usage.cost == 0.01
    end
  end

  describe "abort/1" do
    test "preserves partial response and adds system message" do
      session = start_subscribed_session()
      :ok = Session.send_prompt(session, "Test")
      await_turn_complete()

      # Verify we have an assistant message
      messages = Session.messages(session)
      assert Enum.any?(messages, &match?({:assistant, _}, &1))

      :ok = Session.abort(session)

      messages = Session.messages(session)
      assert Enum.any?(messages, &match?({:assistant, _}, &1))
      assert Enum.any?(messages, &match?({:system, "Aborted", :info}, &1))
      assert Session.status(session) == :idle
    end

    test "marks running tool calls as aborted" do
      session = start_subscribed_session()
      assert :ok = Session.continue(session)
      # Admit a turn before injecting its provider event.
      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc1", name: "bash", args: %{}}}
      )

      # Session.messages is a call, so it's processed after the send above
      _ = Session.messages(session)

      :ok = Session.abort(session)

      send_provider_event(session, %Event.ToolStart{
        tool_call_id: "tc-stale",
        name: "bash",
        args: %{}
      })

      assert Session.status(session) == :idle

      messages = Session.messages(session)

      tool =
        Enum.find(messages, fn
          {:tool_call, _} -> true
          _ -> false
        end)

      assert {:tool_call, tc} = tool
      assert tc.id == "tc1"
      assert tc.status == :error
      assert tc.result == "aborted"
      assert tc.is_error
    end
  end

  describe "new_session/1" do
    test "clears messages, resets status, and resets usage" do
      session = start_subscribed_session()
      :ok = Session.send_prompt(session, "First")
      await_turn_complete()
      assert Enum.count(Session.messages(session)) > 1

      :ok = Session.new_session(session)

      assert [{:system, text, :info}] = Session.messages(session)
      assert String.starts_with?(text, "Session cleared")
      assert Session.status(session) == :idle

      usage = Session.usage(session)
      assert usage.input == 0
      assert usage.cost == 0.0
    end
  end

  describe "set_model/2" do
    test "preserves conversation messages when switching models" do
      session = start_subscribed_session()
      :ok = Session.send_prompt(session, "Hello before model switch")
      await_turn_complete()

      messages_before = Session.messages(session)
      assert Enum.count(messages_before) >= 3

      assert :ok = Session.set_model(session, "openai:gpt-4o")

      messages_after = Session.messages(session)
      # All prior messages should still be there
      assert messages_before == messages_after
    end
  end

  describe "subscribe/unsubscribe" do
    test "stops receiving events after unsubscribe" do
      session = start_subscribed_session()
      assert_receive {:agent_event, ^session, {:credentials_status, true}}

      :ok = Session.unsubscribe(session)

      :ok = Session.send_prompt(session, "Test")

      refute_receive {:agent_event, _, _}, 100
    end
  end

  describe "editor_snapshot/1" do
    test "includes active tool name while a tool is running" do
      session = start_subscribed_session()
      assert :ok = Session.continue(session)

      send(
        session,
        {:agent_provider_event,
         %Event.ToolStart{tool_call_id: "tc1", name: "read_file", args: %{}}}
      )

      snapshot = Session.editor_snapshot(session)

      assert snapshot.status == :tool_executing
      assert snapshot.active_tool_name == "read_file"

      send(
        session,
        {:agent_provider_event,
         %Event.ToolEnd{tool_call_id: "tc1", name: "read_file", result: "contents"}}
      )

      snapshot = Session.editor_snapshot(session)

      assert snapshot.active_tool_name == nil
    end

    test "keeps the next tool name active until every tool ends" do
      session = start_subscribed_session()
      assert :ok = Session.continue(session)

      send(
        session,
        {:agent_provider_event,
         %Event.ToolStart{tool_call_id: "tc1", name: "read_file", args: %{}}}
      )

      send(
        session,
        {:agent_provider_event, %Event.ToolStart{tool_call_id: "tc2", name: "shell", args: %{}}}
      )

      snapshot = Session.editor_snapshot(session)
      assert snapshot.active_tool_name == "shell"

      send(
        session,
        {:agent_provider_event,
         %Event.ToolEnd{tool_call_id: "tc1", name: "read_file", result: "contents"}}
      )

      snapshot = Session.editor_snapshot(session)
      assert snapshot.active_tool_name == "shell"

      send(
        session,
        {:agent_provider_event,
         %Event.ToolEnd{tool_call_id: "tc2", name: "shell", result: "output"}}
      )

      snapshot = Session.editor_snapshot(session)
      assert snapshot.active_tool_name == nil
    end
  end

  describe "metadata/1" do
    test "returns idle session metadata before any user prompt" do
      session = start_subscribed_session()
      meta = Session.metadata(session)

      assert is_binary(meta.id)
      assert %DateTime{} = meta.created_at
      assert meta.message_count >= 1
      assert meta.cost == 0.0
      assert meta.status == :idle
      assert meta.first_prompt == nil
    end

    test "first_prompt returns first user message text" do
      session = start_subscribed_session()
      Session.send_prompt(session, "Hello there")
      assert_receive {:agent_event, _, :messages_changed}, @event_timeout

      assert Session.metadata(session).first_prompt == "Hello there"
    end
  end

  # ── Queue API ──────────────────────────────────────────────────────────────
end
