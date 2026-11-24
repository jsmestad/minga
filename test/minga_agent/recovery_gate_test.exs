defmodule MingaAgent.RecoveryGateTest do
  @moduledoc """
  Deterministic recovery-gate test corpus for issue #3441.

  Exercises real Session/Continuation/Provider boundaries through BEAM APIs
  without live model calls or OS-specific process observation. Each scenario
  targets one recovery invariant.
  """

  use Minga.Test.SessionCase, async: true

  alias Minga.Test.RecoveryCorpusProvider, as: CorpusProvider

  @event_timeout 5_000

  describe "compaction after a multi-tool turn" do
    test "the next request is built from the compacted history" do
      compacted = [
        ReqLLM.Context.system("You are a helpful assistant."),
        ReqLLM.Context.user("[Compacted summary of prior conversation]"),
        ReqLLM.Context.assistant("Acknowledged summary.")
      ]

      provider_opts =
        CorpusProvider.scripts([
          # Turn 1: text + two tool calls + complete
          [
            {:event, %Event.AgentStart{}},
            {:text, "I'll read and write the file."},
            {:tool_start, "tc-read", "read_file"},
            {:tool_end, "tc-read", "read_file", "file contents"},
            {:tool_start, "tc-write", "write_file"},
            {:tool_end, "tc-write", "write_file", "wrote ok"},
            {:complete, ""}
          ],
          # Turn 2: simple text response after compaction
          [
            {:event, %Event.AgentStart{}},
            {:text, "Post-compaction answer."},
            {:complete, ""}
          ]
        ])
        |> Keyword.put(:compacted_messages, compacted)

      session = start_subscribed_session(CorpusProvider, provider_opts)
      assert is_pid(Session.get_provider(session))

      # Turn 1: multi-tool turn
      assert :ok = Session.send_prompt(session, "read and write the file")
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      messages_before = Session.messages(session)
      assert Enum.any?(messages_before, &match?({:user, "read and write the file"}, &1))
      assert Enum.any?(messages_before, &match?({:assistant, _text}, &1))

      assert_receive {:recovery_provider_request, _, %{messages: turn_one_messages}}
      assert Enum.any?(turn_one_messages, &(message_text(&1) =~ "read and write the file"))

      assert {:ok, _summary} = Session.compact(session)

      assert :ok = Session.send_prompt(session, "what happened?")

      assert_receive {:recovery_provider_request, _, %{messages: turn_two_messages}},
                     @event_timeout

      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      texts = Enum.map(turn_two_messages, &message_text/1)
      assert "[Compacted summary of prior conversation]" in texts
      refute Enum.any?(texts, &(&1 =~ "read and write the file"))
      assert List.last(texts) =~ "what happened?"

      assert Enum.any?(
               Session.messages(session),
               &match?({:assistant, "Post-compaction answer."}, &1)
             )

      assert Session.status(session) == :idle
    end
  end

  describe "cancellation during tool execution" do
    test "abort during a pending tool call returns to idle and ignores the aborted request's late events" do
      provider_opts =
        CorpusProvider.script([
          {:event, %Event.AgentStart{}},
          {:text, "Starting work..."},
          {:tool_start, "tc-long", "shell"},
          # Barrier: test controls timing here
          :barrier,
          {:text, "late output"},
          {:tool_end, "tc-long", "shell", "done"},
          {:complete, ""}
        ])

      session = start_subscribed_session(CorpusProvider, provider_opts)
      assert is_pid(Session.get_provider(session))

      assert :ok = Session.send_prompt(session, "run a long command")

      # Wait for the provider to hit the barrier (tool_start sent, tool_end pending)
      assert_receive {:recovery_provider_barrier, provider}, @event_timeout
      assert is_pid(provider)

      # Session should be in a tool-executing state
      snapshot = Session.editor_snapshot(session)
      assert snapshot.status in [:thinking, :tool_executing]

      assert :ok = Session.abort(session)
      assert_receive {:recovery_provider_abort, ^provider}, @event_timeout
      :sys.get_state(session)
      status_after_abort = Session.status(session)
      assert status_after_abort == :idle

      # The provider now emits the rest of the aborted turn, still tagged with its request.
      CorpusProvider.release(provider)
      :sys.get_state(provider)
      :sys.get_state(session)

      assert Session.status(session) == status_after_abort
      refute Enum.any?(Session.messages(session), &(inspect(&1) =~ "late output"))
    end
  end

  describe "session persists and restores with messages" do
    @tag :tmp_dir
    test "a completed turn persists and loads back through SessionStore", %{tmp_dir: dir} do
      provider_opts =
        CorpusProvider.script([
          {:event, %Event.AgentStart{}},
          {:text, "Here is my answer."},
          {:complete, ""}
        ])

      session =
        start_test_session(
          provider: CorpusProvider,
          provider_opts: provider_opts,
          session_store_dir: dir,
          persist?: true
        )

      Session.subscribe(session)
      original_id = Session.session_id(session)

      # Complete a turn so we have messages to persist
      assert :ok = Session.send_prompt(session, "save this conversation")
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      messages_before = Session.messages(session)
      assert Enum.any?(messages_before, &match?({:user, "save this conversation"}, &1))
      assert Enum.any?(messages_before, &match?({:assistant, "Here is my answer."}, &1))

      # Verify the session was persisted by loading the record directly
      assert {:ok, data} = SessionStore.load(original_id, dir)
      assert data.id == original_id

      # The loaded record should contain the conversation messages
      assert is_list(data.messages)
      assert length(data.messages) > 0

      # The continuation should have advanced past its initial revision
      assert %MingaAgent.Session.Continuation{} = data.continuation
      assert data.continuation.revision > 0
      assert data.continuation.active_request == nil
      assert data.continuation.tool_checkpoint == nil
    end

    @tag :tmp_dir
    test "a new session loads a saved conversation and restores its transcript", %{tmp_dir: dir} do
      provider_opts =
        CorpusProvider.script([
          {:event, %Event.AgentStart{}},
          {:text, "Persisted answer."},
          {:complete, ""}
        ])

      session =
        start_test_session(
          provider: CorpusProvider,
          provider_opts: provider_opts,
          session_store_dir: dir,
          persist?: true
        )

      Session.subscribe(session)
      original_id = Session.session_id(session)

      assert :ok = Session.send_prompt(session, "persist me")
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      # Start a fresh session and load the saved conversation into it.
      # Using MockProvider so the loaded session gets a working provider.
      session_2 =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [],
          session_store_dir: dir,
          persist?: false
        )

      Session.subscribe(session_2)
      assert :ok = Session.load_session(session_2, original_id)

      restored = Session.messages(session_2)
      assert Enum.any?(restored, &match?({:user, "persist me"}, &1))
      assert Enum.any?(restored, &match?({:assistant, "Persisted answer."}, &1))

      assert is_pid(Session.get_provider(session_2))

      state = :sys.get_state(session_2)
      assert state.continuation.revision > 0
      assert state.continuation.active_request == nil
    end
  end

  describe "queued follow-up drains after the active turn" do
    test "a steering prompt queued during a slow turn is sent after the turn completes" do
      provider_opts =
        CorpusProvider.scripts([
          # Turn 1: pauses at barrier before completing
          [
            {:event, %Event.AgentStart{}},
            {:text, "Working on it..."},
            :barrier,
            {:complete, ""}
          ],
          # Turn 2: sent after follow-up is queued
          [
            {:event, %Event.AgentStart{}},
            {:text, "Follow-up response."},
            {:complete, ""}
          ]
        ])

      session = start_subscribed_session(CorpusProvider, provider_opts)

      # Start the first turn
      assert :ok = Session.send_prompt(session, "initial task")
      assert_receive {:recovery_provider_barrier, provider}, @event_timeout

      # Queue a steering prompt while the turn is active
      assert {:queued, :steering} = Session.queue_steering(session, "also do this")

      # Release the first turn. It completes and the queued steering fires turn 2.
      CorpusProvider.release(provider)

      assert_receive {:recovery_provider_prompt, _, "also do this"}, @event_timeout

      # Wait for both turns to settle. The second turn's idle event is what
      # proves the queued follow-up was drained.
      await_turn_complete()

      messages = Session.messages(session)

      assert Enum.any?(messages, fn
               {:assistant, text} -> String.contains?(text, "Follow-up response")
               _ -> false
             end)

      assert Session.status(session) == :idle
    end
  end

  describe "continuation revisions" do
    test "the continuation revision advances across completed turns" do
      provider_opts =
        CorpusProvider.scripts([
          [
            {:event, %Event.AgentStart{}},
            {:text, "First answer."},
            {:complete, ""}
          ],
          [
            {:event, %Event.AgentStart{}},
            {:text, "Second answer."},
            {:complete, ""}
          ]
        ])

      session = start_subscribed_session(CorpusProvider, provider_opts)

      state_before = :sys.get_state(session)
      rev_before = state_before.continuation.revision

      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      state_mid = :sys.get_state(session)
      rev_mid = state_mid.continuation.revision
      assert rev_mid > rev_before

      assert :ok = Session.send_prompt(session, "second")
      assert_receive {:agent_event, _, {:status_changed, :idle}}, @event_timeout

      state_after = :sys.get_state(session)
      rev_after = state_after.continuation.revision
      assert rev_after > rev_mid

      # No active request should remain after both turns complete
      assert state_after.continuation.active_request == nil
      assert state_after.continuation.tool_checkpoint == nil
    end
  end

  @spec message_text(ReqLLM.Message.t()) :: String.t()
  defp message_text(%ReqLLM.Message{content: parts}) when is_list(parts),
    do: Enum.map_join(parts, "", &(Map.get(&1, :text) || ""))

  defp message_text(%ReqLLM.Message{content: text}) when is_binary(text), do: text
end
