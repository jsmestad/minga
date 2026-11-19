defmodule MingaAgent.SessionPersistenceTest do
  use Minga.Test.SessionCase, async: true
  alias MingaAgent.Branch
  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias MingaAgent.ArtifactStores
  alias MingaAgent.Checklist
  alias MingaAgent.DraftSnapshot
  alias MingaAgent.TranscriptEntry
  alias MingaAgent.Session.Continuation
  alias MingaAgent.ToolCall
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target

  defp request_draft(session, record_id, operation) do
    ref = make_ref()
    :ok = Session.request_composer_draft(session, record_id, ref, operation)
    assert_receive {:composer_draft_result, ^session, ^record_id, ^ref, result}
    result
  end

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
    test "a delayed composer write cannot follow the live session into a different record", %{
      tmp_dir: dir
    } do
      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          persist?: true,
          session_store_dir: dir
        )

      original = Session.session_id(session)

      draft = %DraftSnapshot{
        text: "unfinished",
        cursor: {0, 10},
        paste_blocks: [],
        attachments: []
      }

      assert {:ok, 0, nil} = request_draft(session, original, :read)
      assert {:ok, 1} = request_draft(session, original, {:save, 0, draft})
      assert :ok = Session.new_session(session)
      replacement = Session.session_id(session)

      assert {:error, :stale_target} = request_draft(session, original, {:save, 1, nil})
      assert {:error, :stale_target} = request_draft(session, original, :read)
      assert {:ok, 1, ^draft} = SessionStore.read_presentation(original, dir)
      assert {:ok, 0, nil} = request_draft(session, replacement, :read)
    end

    @tag :tmp_dir
    test "a saved draft can reopen before it has a conversation", %{tmp_dir: dir} do
      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          persist?: true,
          session_store_dir: dir
        )

      {:ok, checklist} =
        Checklist.replace(Checklist.new(), 0, [
          %{"id" => "prior-task", "description" => "Only in the original conversation"}
        ])

      assert :ok =
               SessionStore.save(
                 %{
                   id: "original-record",
                   timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
                   model_name: "test-model",
                   messages: [{:user, "Original task"}],
                   usage: MingaAgent.TurnUsage.new(),
                   continuation: Continuation.new(),
                   checklist: checklist
                 },
                 dir
               )

      assert :ok = Session.load_session(session, "original-record")
      assert Session.editor_snapshot(session).checklist == checklist

      record_id = "unsent-record"
      draft = %DraftSnapshot{text: "not sent", cursor: {0, 8}, paste_blocks: [], attachments: []}
      assert {:ok, 1} = SessionStore.save_presentation(record_id, 0, draft, dir)
      assert :ok = Session.load_session(session, record_id)
      assert Session.session_id(session) == record_id
      assert [] = Session.messages(session)
      assert Session.editor_snapshot(session).checklist == Checklist.new()
      assert {:ok, %{checklist: ^checklist}} = SessionStore.load("original-record", dir)
      assert {:ok, 1, ^draft} = request_draft(session, record_id, :read)
      assert {:error, :enoent} = SessionStore.load(record_id, dir)
    end

    @tag :tmp_dir
    test "targeted restore rejects the old conversation after an in-process reset", %{
      tmp_dir: dir
    } do
      session =
        start_test_session(
          provider: Minga.Test.SessionMockProvider,
          persist?: true,
          session_store_dir: dir
        )

      old = Session.session_id(session)
      assert :ok = Session.new_session(session)
      current = Session.session_id(session)
      refute current == old

      assert {:error, :stale_session} = Session.load_session(session, "saved-record", old)

      assert {:error, :stale_session} =
               Session.import_legacy_session(session, "saved-record", old)

      assert Session.session_id(session) == current
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
          continuation: Continuation.new(),
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
          persist?: true,
          session_store_dir: dir
        )

      {:ok, continuation} =
        Continuation.restore(
          [
            ReqLLM.Context.system("Original system"),
            ReqLLM.Context.user("Restore me"),
            ReqLLM.Context.assistant("Restored reply")
          ],
          1,
          1,
          [%{transcript_id: 13, message_count: 3, revision: 1}],
          %{
            "branch-1" => %{
              messages: [
                ReqLLM.Context.system("Original system"),
                ReqLLM.Context.user("branched prompt"),
                ReqLLM.Context.assistant("branched reply")
              ],
              boundaries: [%{transcript_id: 12, message_count: 3, revision: 1}]
            }
          },
          :lossless
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
          continuation: continuation,
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

      assert {:ok, saved_branch} = SessionStore.load("resumable-session", dir)

      assert Enum.map(saved_branch.continuation.messages, & &1.role) == [
               :system,
               :user,
               :assistant
             ]

      assert saved_branch.pinned_ids == MapSet.new()

      assert :ok = Session.switch_branch(session, 1)

      assert Session.messages(session) == [
               {:user, "branched prompt"},
               {:assistant, "branched reply"}
             ]
    end

    @tag :tmp_dir
    test "provider model restore failure leaves the current session installed", %{tmp_dir: dir} do
      session =
        start_test_session(
          provider: Minga.Test.SessionContinuationProvider,
          provider_opts: [test_pid: self(), model_result: {:error, :model_rejected}],
          session_store_dir: dir
        )

      assert :ok = Session.subscribe(session)

      assert :ok =
               SessionStore.save(
                 %{
                   id: "model-restore-failure",
                   timestamp: DateTime.to_iso8601(DateTime.utc_now()),
                   model_name: "rejected-model",
                   messages: [{:user, "saved request"}],
                   usage: %MingaAgent.TurnUsage{
                     input: 0,
                     output: 0,
                     cache_read: 0,
                     cache_write: 0,
                     cost: 0.0
                   },
                   continuation: Continuation.new()
                 },
                 dir
               )

      assert :ok = Session.send_prompt(session, "keep this wait")
      assert_receive {:continuation_request, request}, @event_timeout

      send_provider_event(session, %Event.ToolApproval{
        tool_call_id: "restore-wait",
        name: "shell",
        args: %{"command" => "pwd"},
        reply_to: self()
      })

      target = Target.new(Session.session_id(session), request.request_id, "restore-wait")

      assert_receive {:agent_event, ^session,
                      {:approval_pending, %Public{target: ^target} = public}},
                     @event_timeout

      original_messages = Session.messages(session)
      original_session_id = Session.session_id(session)

      assert {:error, {:provider_model_restore_failed, :model_rejected}} =
               Session.load_session(session, "model-restore-failure")

      assert Session.session_id(session) == original_session_id
      assert Session.messages(session) == original_messages
      assert Session.editor_snapshot(session).pending_approval === public
      assert Session.editor_snapshot(session).display_status == :approval_waiting
      assert Session.list_tool_trust(session) == %{}
      refute_received {:tool_approval_response, "restore-wait", _decision}
      refute_received {:agent_event, ^session, {:approval_resolved, ^target, _resolution}}
      assert :ok = Session.respond_to_approval(session, target, :approve)
      assert_receive {:tool_approval_response, "restore-wait", :approve}, @event_timeout

      assert_receive {:agent_event, ^session, {:approval_resolved, ^target, :approve}},
                     @event_timeout

      assert Session.list_tool_trust(session) == %{}
    end

    @tag :tmp_dir
    test "explicit legacy import leaves existing memory and the source record unchanged",
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

      source = File.read!(Path.join(sessions_dir, "legacy-session.json"))
      assert {:error, :legacy_import_required} = Session.load_session(session, "legacy-session")
      assert :ok = Session.import_legacy_session(session, "legacy-session")

      assert Enum.any?(Session.messages(session), fn
               {:system, message, :info} ->
                 String.contains?(message, "Imported legacy display history")

               _message ->
                 false
             end)

      assert Session.session_id(session) != "legacy-session"
      assert {:ok, imported} = SessionStore.load(Session.session_id(session), dir)

      assert Enum.any?(imported.messages, fn
               {:system, message, :info} ->
                 String.contains?(message, "Imported legacy display history")

               _message ->
                 false
             end)

      assert File.read!(Path.join(sessions_dir, "legacy-session.json")) == source
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
          continuation: Continuation.new(),
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
          continuation: Continuation.new(),
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

  @tag :tmp_dir
  test "checkpoint recovery failure leaves the current provider request untouched", %{
    tmp_dir: dir
  } do
    {:ok, target_request, target_continuation} =
      Continuation.begin_request(Continuation.new(), "target-interrupted-request", 1, [
        ReqLLM.Context.user("target prompt")
      ])

    assistant = %ReqLLM.Message{
      role: :assistant,
      tool_calls: [
        ReqLLM.ToolCall.new("target-call", "write_file", ~s({"path":"a","content":"b"}))
      ]
    }

    {:ok, checkpoint_id, target_continuation} =
      Continuation.checkpoint_tool_group(
        target_continuation,
        target_request.request_id,
        Enum.concat(target_request.messages, [assistant]),
        [
          %{
            tool_call_id: "target-call",
            name: "write_file",
            arguments: %{"path" => "a", "content" => "b"}
          }
        ]
      )

    {:ok, target_continuation} =
      Continuation.admit_tool_effect(
        target_continuation,
        target_request.request_id,
        checkpoint_id,
        "target-call",
        "write_file",
        %{"path" => "a", "content" => "b"}
      )

    SessionStore.save(
      %{
        id: "target-with-checkpoint",
        timestamp: "2026-01-01T00:00:00Z",
        title: "Interrupted target",
        model_name: "test-model",
        provider_name: "test",
        messages: [{:user, "target prompt"}],
        continuation: target_continuation,
        usage: %MingaAgent.TurnUsage{}
      },
      dir
    )

    session =
      start_test_session(
        provider: Minga.Test.SessionSlowMockProvider,
        provider_opts: [test_pid: self()],
        persist?: false,
        session_store_dir: dir
      )

    assert :ok = Session.subscribe(session)

    current_id = Session.session_id(session)
    assert :ok = Session.send_prompt(session, "keep active work")
    assert_receive {:agent_event, ^session, {:status_changed, :thinking}}, @event_timeout
    request_id = :sys.get_state(session).continuation.active_request.request_id

    assert {:error, {:checkpoint_reconciliation_failed, :session_persistence_disabled}} =
             Session.load_session(session, "target-with-checkpoint")

    state = :sys.get_state(session)
    assert Session.session_id(session) == current_id
    assert state.continuation.active_request.request_id == request_id
    assert Session.status(session) == :thinking
  end

  @tag :tmp_dir
  test "delivery-in-progress recovery preserves the durable checkpoint and current session", %{
    tmp_dir: dir
  } do
    suffix = System.unique_integer([:positive])

    artifact_opts = [
      name: Module.concat(__MODULE__, "RecoveryArtifactSupervisor#{suffix}"),
      root: Path.join(dir, "private-artifacts"),
      quota: Module.concat(__MODULE__, "RecoveryArtifactQuota#{suffix}"),
      registry: Module.concat(__MODULE__, "RecoveryArtifactRegistry#{suffix}"),
      store_supervisor: Module.concat(__MODULE__, "RecoveryArtifactStores#{suffix}")
    ]

    start_supervised!({MingaAgent.ArtifactSupervisor, artifact_opts})
    {:ok, runtime} = MingaAgent.ArtifactSupervisor.runtime(artifact_opts)
    record = "delivery-in-progress-checkpoint"
    call_id = "in-progress-call"
    arguments = %{"path" => "README.md"}

    {:ok, request, continuation} =
      Continuation.begin_request(Continuation.new(), "in-progress-request", 1, [
        ReqLLM.Context.user("inspect")
      ])

    assistant = %ReqLLM.Message{
      role: :assistant,
      tool_calls: [ReqLLM.ToolCall.new(call_id, "read_file", ~s({"path":"README.md"}))]
    }

    {:ok, checkpoint_id, checkpointed} =
      Continuation.checkpoint_tool_group(
        continuation,
        request.request_id,
        Enum.concat(request.messages, [assistant]),
        [%{tool_call_id: call_id, name: "read_file", arguments: arguments}]
      )

    {:ok, admitted} =
      Continuation.admit_tool_effect(
        checkpointed,
        request.request_id,
        checkpoint_id,
        call_id,
        "read_file",
        arguments
      )

    assert :ok =
             SessionStore.save(
               %{
                 id: record,
                 timestamp: "2026-01-01T00:00:00Z",
                 model_name: "test-model",
                 provider_name: "test",
                 messages: [{:user, "inspect"}],
                 continuation: admitted,
                 usage: %MingaAgent.TurnUsage{}
               },
               dir,
               artifact_runtime: runtime
             )

    {:ok, artifact_store} = ArtifactStores.ensure_record(record, runtime)

    {:ok, capture_spec} =
      CaptureSpec.new(
        media_type: "text/plain",
        mode: :bytes,
        owner_pid: self(),
        delivery_key: {:delivery, checkpoint_id, call_id}
      )

    assert {:ok, _capture} = ArtifactStore.begin(artifact_store, capture_spec)

    session =
      start_test_session(
        provider: Minga.Test.SessionMockProvider,
        provider_opts: [],
        session_store_dir: dir,
        persist?: true,
        artifact_runtime: runtime
      )

    current_id = Session.session_id(session)

    assert {:error, {:checkpoint_reconciliation_failed, :delivery_in_progress}} =
             Session.load_session(session, record)

    assert Session.session_id(session) == current_id
    assert {:ok, saved} = SessionStore.load(record, dir, artifact_runtime: runtime)
    assert saved.continuation.tool_checkpoint.checkpoint_id == checkpoint_id
    assert Enum.at(saved.continuation.tool_checkpoint.calls, 0).status == :admitted
  end

  @tag :tmp_dir
  test "a restarted Session rejects changed instructions without rewriting its saved continuation",
       %{tmp_dir: dir} do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self(), system_prompt: "saved skill prompt"],
        persist?: true,
        session_store_dir: dir
      )

    assert :ok = Session.subscribe(session)
    session_id = Session.session_id(session)
    assert :ok = Session.send_prompt(session, "first prompt")
    assert_receive {:continuation_request, first_request}, @event_timeout

    assert Enum.any?(Session.messages_with_ids(session), fn
             {id, {:user, "first prompt"}} -> id == first_request.turn_id
             _other -> false
           end)

    assistant = %ReqLLM.Message{
      role: :assistant,
      content: [
        ReqLLM.Message.ContentPart.text("first answer"),
        ReqLLM.Message.ContentPart.provider_block(:anthropic, %{
          "type" => "server_tool_use",
          "signature" => <<1, 2, 255>>
        })
      ]
    }

    completed_messages = Enum.concat(first_request.messages, [assistant])
    outcome = MingaAgent.Session.Outcome.new(first_request, completed_messages)
    send_provider_event(session, %MingaAgent.Event.AgentEnd{outcome: outcome})
    await_turn_complete()

    assert {:ok, saved} = SessionStore.load(session_id, dir)
    assert saved.continuation.messages == completed_messages
    GenServer.stop(session)

    restarted =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self(), system_prompt: "changed skill prompt"],
        persist?: true,
        session_store_dir: dir
      )

    assert :ok = Session.subscribe(restarted)
    assert :ok = Session.load_session(restarted, session_id)

    assert {:error, {:portable_context_transition_required, _}} =
             Session.send_prompt(restarted, "follow-up")

    refute {:user, "follow-up"} in Session.messages(restarted)
    assert_receive {:agent_event, ^restarted, {:error, message}}, @event_timeout
    assert Session.editor_snapshot(restarted).error == message
    assert Session.status(restarted) == :error
    assert {:system, message, :error} in Session.messages(restarted)

    refute_receive {:continuation_request, _request}, 0
    assert {:ok, preserved} = SessionStore.load(session_id, dir)
    assert preserved.continuation == saved.continuation
    assert :ok = Session.new_session(restarted)
    refute Session.session_id(restarted) == session_id
    assert :ok = Session.send_prompt(restarted, "fresh prompt")
    assert_receive {:continuation_request, fresh_request}, @event_timeout
    assert hd(fresh_request.messages) == ReqLLM.Context.system("changed skill prompt")
    assert :ok = Session.abort(restarted)
  end

  test "continue includes the original prompt after an interrupted response" do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()]
      )

    assert :ok = Session.subscribe(session)
    assert :ok = Session.send_prompt(session, "original task")
    assert_receive {:continuation_request, request}, @event_timeout

    send_provider_event(session, %MingaAgent.Event.AgentEnd{})
    assert Session.status(session) == :error

    assert :ok = Session.continue(session)
    assert_receive {:continuation_request, resumed_request}, @event_timeout
    assert hd(resumed_request.messages) == hd(request.messages)

    assert [continuation_prompt | _rest] = Enum.reverse(resumed_request.messages)

    assert Enum.any?(continuation_prompt.content, fn part ->
             String.contains?(part.text, "previous response was interrupted")
           end)

    outcome =
      MingaAgent.Session.Outcome.new(
        resumed_request,
        Enum.concat(resumed_request.messages, [ReqLLM.Context.assistant("continued answer")])
      )

    send_provider_event(session, %MingaAgent.Event.AgentEnd{outcome: outcome})
    await_turn_complete()
  end

  test "provider compaction is committed before an immutable request starts" do
    compacted_prefix = [ReqLLM.Context.system("compacted history")]

    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self(), compacted_messages: compacted_prefix]
      )

    assert :ok = Session.subscribe(session)
    assert :ok = Session.send_prompt(session, "continue after compaction")
    assert_receive {:continuation_request, request}, @event_timeout

    assert request.messages ==
             Enum.concat(compacted_prefix, [
               ReqLLM.Context.user("continue after compaction")
             ])

    outcome =
      MingaAgent.Session.Outcome.new(
        request,
        Enum.concat(request.messages, [ReqLLM.Context.assistant("continued answer")])
      )

    send_provider_event(session, %MingaAgent.Event.AgentEnd{outcome: outcome})

    await_turn_complete()

    assert :sys.get_state(session).continuation.messages ==
             Enum.concat(request.messages, [
               ReqLLM.Context.assistant("continued answer")
             ])
  end

  test "compaction retains only the current resumable display boundary" do
    continuation = Continuation.new()

    {:ok, first_request, continuation} =
      Continuation.begin_request(continuation, "first", 1, "first prompt")

    first_outcome =
      MingaAgent.Session.Outcome.new(
        first_request,
        Enum.concat(first_request.messages, [ReqLLM.Context.assistant("first answer")])
      )

    {:ok, continuation} = Continuation.complete(continuation, first_outcome, 2)

    {:ok, second_request, continuation} =
      Continuation.begin_request(continuation, "second", 3, "second prompt")

    second_outcome =
      MingaAgent.Session.Outcome.new(
        second_request,
        Enum.concat(second_request.messages, [ReqLLM.Context.assistant("second answer")])
      )

    {:ok, continuation} = Continuation.complete(continuation, second_outcome, 4)

    compacted_messages = [
      ReqLLM.Context.system("summary"),
      ReqLLM.Context.user("second prompt"),
      ReqLLM.Context.assistant("second answer")
    ]

    assert {:ok, compacted} = Continuation.replace_messages(continuation, compacted_messages)
    assert {:error, :branch_not_resumable} = Continuation.branch_at(compacted, "old", 2)
    assert {:ok, current} = Continuation.branch_at(compacted, "current", 4)
    assert current.messages == compacted_messages
  end

  test "completion rejects a system message prepended before an existing request system prompt" do
    assert {:ok, continuation} =
             Continuation.restore(
               [ReqLLM.Context.system("durable system prompt")],
               0,
               0,
               [],
               %{},
               :lossless
             )

    {:ok, request, continuation} =
      Continuation.begin_request(continuation, "prefix-check", 1, "approved prompt")

    outcome =
      MingaAgent.Session.Outcome.new(
        request,
        Enum.concat(
          [ReqLLM.Context.system("unrequested system message") | request.messages],
          [ReqLLM.Context.assistant("response")]
        )
      )

    assert {:error, :invalid_checkpoint_progression} =
             Continuation.complete(continuation, outcome, 2)
  end

  @tag :tmp_dir
  test "completed boundaries point to the assistant entry before usage", %{tmp_dir: dir} do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()],
        persist?: true,
        session_store_dir: dir
      )

    assert :ok = Session.subscribe(session)
    assert :ok = Session.send_prompt(session, "measure this turn")
    assert_receive {:continuation_request, request}, @event_timeout

    outcome =
      MingaAgent.Session.Outcome.new(
        request,
        Enum.concat(request.messages, [ReqLLM.Context.assistant("measured answer")])
      )

    usage = %MingaAgent.TurnUsage{input: 3, output: 2, cache_read: 0, cache_write: 0, cost: 0.01}

    send_provider_event(session, %MingaAgent.Event.TextDelta{delta: "measured answer"})

    send_provider_event(session, %MingaAgent.Event.AgentEnd{usage: usage, outcome: outcome})
    await_turn_complete()

    entries = Session.messages_with_ids(session)

    assistant_id =
      Enum.find_value(entries, fn
        {id, {:assistant, "measured answer"}} -> id
        _entry -> nil
      end)

    usage_id =
      Enum.find_value(entries, fn
        {id, {:usage, _usage}} -> id
        _entry -> nil
      end)

    boundary_id =
      :sys.get_state(session).continuation.boundaries
      |> List.last()
      |> Map.fetch!(:transcript_id)

    assert boundary_id == assistant_id

    refute assistant_id == usage_id
  end

  test "a late outcome from an aborted request cannot replace the next request" do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()]
      )

    assert :ok = Session.send_prompt(session, "abort this request")
    assert_receive {:continuation_request, first_request}, @event_timeout
    assert :ok = Session.abort(session)

    assert :ok = Session.send_prompt(session, "keep this newer request")
    assert_receive {:continuation_request, second_request}, @event_timeout

    late_outcome =
      MingaAgent.Session.Outcome.new(
        first_request,
        Enum.concat(first_request.messages, [ReqLLM.Context.assistant("late answer")])
      )

    send(
      session,
      {:agent_provider_event, first_request.request_id,
       %MingaAgent.Event.AgentEnd{outcome: late_outcome}}
    )

    state = :sys.get_state(session)
    assert state.continuation.active_request.request_id == second_request.request_id
    assert state.continuation.messages == first_request.messages

    outcome_messages =
      Enum.concat(second_request.messages, [ReqLLM.Context.assistant("current answer")])

    outcome = MingaAgent.Session.Outcome.new(second_request, outcome_messages)

    send(
      session,
      {:agent_provider_event, second_request.request_id,
       %MingaAgent.Event.AgentEnd{outcome: outcome}}
    )

    :sys.get_state(session)

    assert :sys.get_state(session).continuation.messages == outcome_messages
  end

  @tag :tmp_dir
  test "failed boundary write keeps the prior durable continuation resumable", %{tmp_dir: dir} do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()],
        persist?: true,
        session_store_dir: dir
      )

    assert :ok = Session.subscribe(session)

    session_id = Session.session_id(session)
    assert :ok = Session.send_prompt(session, "first durable prompt")
    assert_receive {:continuation_request, first_request}, @event_timeout

    first_messages =
      Enum.concat(first_request.messages, [ReqLLM.Context.assistant("durable answer")])

    first_outcome = MingaAgent.Session.Outcome.new(first_request, first_messages)

    send_provider_event(session, %MingaAgent.Event.AgentEnd{outcome: first_outcome})
    await_turn_complete()

    assert {:ok, saved_before_failure} = SessionStore.load(session_id, dir)
    sessions_dir = SessionStore.sessions_dir(dir)
    blocked_path = sessions_dir <> ".blocked"
    assert :ok = File.rename(sessions_dir, blocked_path)
    assert :ok = File.write(sessions_dir, "blocked")

    try do
      assert {:error, {:conversation_persistence_failed, :enotdir}} =
               Session.send_prompt(session, "second prompt")

      refute_receive {:continuation_request, _request}, 50

      assert :sys.get_state(session).continuation.messages ==
               saved_before_failure.continuation.messages

      assert Enum.any?(Session.messages(session), fn
               {:system, message, :error} ->
                 message =~ "Conversation save failed" and
                   message =~ "previous durable boundary remains resumable"

               _message ->
                 false
             end)
    after
      assert :ok = File.rm(sessions_dir)
      assert :ok = File.rename(blocked_path, sessions_dir)
    end

    assert {:ok, saved_after_failure} = SessionStore.load(session_id, dir)

    assert saved_after_failure.continuation.messages ==
             saved_before_failure.continuation.messages
  end

  @tag :tmp_dir
  test "a completed turn still recovers when another submission is refused during its save retry",
       %{tmp_dir: dir} do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()],
        persist?: true,
        session_store_dir: dir
      )

    assert :ok = Session.subscribe(session)
    session_id = Session.session_id(session)
    assert :ok = Session.send_prompt(session, "finish before the save retry")
    assert_receive {:continuation_request, request}, @event_timeout

    sessions_dir = SessionStore.sessions_dir(dir)
    blocked_path = sessions_dir <> ".blocked"
    assert :ok = File.rename(sessions_dir, blocked_path)
    assert :ok = File.write(sessions_dir, "blocked")

    retry_token =
      try do
        outcome =
          MingaAgent.Session.Outcome.new(
            request,
            Enum.concat(request.messages, [ReqLLM.Context.assistant("completed but not saved")])
          )

        send_provider_event(session, %MingaAgent.Event.AgentEnd{outcome: outcome})
        assert Session.status(session) == :error
        before_retry = :sys.get_state(session).persistence
        durability_error = Session.editor_snapshot(session).error

        assert {:error, {:conversation_persistence_failed, _reason}} =
                 Session.send_prompt(session, "do not publish this rejected draft")

        after_retry = :sys.get_state(session).persistence
        assert after_retry.retry_count == before_retry.retry_count + 1
        assert Session.editor_snapshot(session).error == durability_error
        refute {:user, "do not publish this rejected draft"} in Session.messages(session)
        {token, _timer_ref} = after_retry.timer
        token
      after
        assert :ok = File.rm(sessions_dir)
        assert :ok = File.rename(blocked_path, sessions_dir)
      end

    send(session, {:save_session, retry_token})
    assert Session.status(session) == :idle
    assert {:ok, saved} = SessionStore.load(session_id, dir)
    assert Continuation.durable?(saved.continuation)

    assert Enum.any?(saved.messages, fn
             {:system, message, :info} ->
               message == "The completed turn is now saved and resumable."

             _message ->
               false
           end)
  end

  @tag :tmp_dir
  test "provider dispatch rejection durably preserves the submitted prompt", %{tmp_dir: dir} do
    session =
      start_test_session(
        provider: Minga.Test.StubProvider,
        provider_opts: [send_prompt_result: {:error, :prompt_rejected}],
        persist?: true,
        session_store_dir: dir
      )

    session_id = Session.session_id(session)
    assert {:error, :prompt_rejected} = Session.send_prompt(session, "keep this prompt")
    assert {:ok, saved} = SessionStore.load(session_id, dir)
    assert saved.continuation.active_request == nil
    assert Continuation.durable?(saved.continuation)
    assert [last_message | _rest] = Enum.reverse(saved.continuation.messages)
    assert last_message == ReqLLM.Context.user("keep this prompt")
    assert :sys.get_state(session).continuation == saved.continuation
  end

  test "branch changes do not invalidate an active provider request" do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()]
      )

    assert :ok = Session.send_prompt(session, "keep this request")
    assert_receive {:continuation_request, request}, @event_timeout

    assert {:error, :request_active} = Session.branch_at(session, 1)
    assert {:error, :request_active} = Session.switch_branch(session, 1)
    assert :sys.get_state(session).continuation.active_request.request_id == request.request_id
  end

  test "branching an entry without a model boundary leaves the transcript unchanged" do
    session =
      start_test_session(
        provider: Minga.Test.SessionMockProvider,
        provider_opts: [],
        persist?: false
      )

    assert :ok = Session.seed_messages(session, [{:user, "one"}, {:assistant, "answer"}])
    original_messages = Session.messages_with_ids(session)

    assert {:error, :branch_not_resumable} = Session.branch_at(session, 0)
    assert Session.messages_with_ids(session) == original_messages
  end

  test "a rejected provider outcome preserves the interrupted request prompt" do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()]
      )

    assert :ok = Session.send_prompt(session, "preserve the last boundary")
    assert_receive {:continuation_request, request}, @event_timeout

    missing_attachment = %ReqLLM.Message{
      role: :assistant,
      content: [
        %ReqLLM.Message.ContentPart{
          type: :image,
          data: nil,
          media_type: "image/png"
        }
      ]
    }

    outcome =
      MingaAgent.Session.Outcome.new(
        request,
        Enum.concat(request.messages, [missing_attachment])
      )

    send_provider_event(session, %MingaAgent.Event.AgentEnd{outcome: outcome})

    state = :sys.get_state(session)
    assert Session.status(session) == :error
    assert state.continuation.active_request == nil
    assert state.continuation.messages == request.messages

    assert Enum.any?(Session.messages(session), fn
             {:system, message, :error} ->
               message =~ "Provider outcome was rejected" and
                 message =~ "last durable continuation was preserved"

             _message ->
               false
           end)
  end

  @tag :tmp_dir
  test "tool checkpoint reply is withheld when the Session snapshot cannot be persisted", %{
    tmp_dir: dir
  } do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()],
        session_store_dir: dir,
        persist?: true
      )

    assert :ok = Session.send_prompt(session, "inspect")
    assert_receive {:continuation_request, request}, @event_timeout

    sessions_dir = SessionStore.sessions_dir(dir)
    blocked_path = sessions_dir <> ".blocked"
    assert :ok = File.rename(sessions_dir, blocked_path)
    assert :ok = File.write(sessions_dir, "blocked")

    assistant = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text("working")],
      tool_calls: [ReqLLM.ToolCall.new("blocked-call", "read_file", ~s({"path":"README.md"}))]
    }

    try do
      assert {:error, {:tool_checkpoint_failed, _reason}} =
               GenServer.call(
                 session,
                 {:checkpoint_tool_group, request.request_id,
                  Enum.concat(request.messages, [assistant]),
                  [
                    %{
                      tool_call_id: "blocked-call",
                      name: "read_file",
                      arguments: %{"path" => "README.md"}
                    }
                  ]}
               )

      state = :sys.get_state(session)
      assert state.continuation.tool_checkpoint == nil
    after
      assert :ok = File.rm(sessions_dir)
      assert :ok = File.rename(blocked_path, sessions_dir)
    end
  end

  @tag :tmp_dir
  test "saved expiry retires an actually admitted approval target once", %{tmp_dir: dir} do
    %{
      session: session,
      request: request,
      checkpoint_id: checkpoint_id,
      target: target,
      result: result,
      output: output,
      waiter: waiter,
      raw_status: raw_status
    } =
      start_live_expiry(dir)

    send(waiter.pid, :expire)
    assert :ok = Task.await(waiter, @event_timeout)

    assert_receive {:agent_event, ^session, {:approval_resolved, ^target, :approval_timeout}},
                   @event_timeout

    assert_receive {:agent_event, ^session, {:display_status_changed, ^raw_status}},
                   @event_timeout

    assert Session.editor_snapshot(session).pending_approval == nil
    assert Session.status(session) == raw_status
    assert Session.editor_snapshot(session).display_status == raw_status

    assert {:tool_call,
            %ToolCall{
              status: :error,
              terminal_reason: :approval_timeout,
              duration_ms: nil,
              output: ^output
            }} =
             Enum.find(Session.messages(session), &match?({:tool_call, _}, &1))

    assert {:ok, saved} = SessionStore.load(Session.session_id(session), dir)
    assert [%{status: {:completed, ^result}}] = saved.continuation.tool_checkpoint.calls

    assert :ok =
             GenServer.call(
               session,
               {:complete_tool_effect, request.request_id, checkpoint_id, "expiry-call", result}
             )

    send_provider_event(session, %Event.ToolEnd{
      tool_call_id: "expiry-call",
      name: "shell",
      outcome: :error,
      reason: :approval_timeout,
      result: "Tool approval timed out",
      output: output,
      is_error: true
    })

    assert_receive {:agent_event, ^session,
                    {:tool_ended,
                     %Event.ToolEnd{outcome: :error, reason: :approval_timeout, output: ^output}}},
                   @event_timeout

    refute_received {:agent_event, ^session, {:approval_resolved, ^target, :approval_timeout}}
    refute_received {:agent_event, ^session, {:approval_resolved, ^target, :reject}}
    refute_received {:agent_event, ^session, {:display_status_changed, ^raw_status}}
    refute_received {:agent_event, ^session, {:display_status_changed, :approval_waiting}}

    assert {:error, :approval_not_found} =
             Session.respond_to_approval(session, target, :approve_session)

    assert Session.list_tool_trust(session) == %{}
  end

  @tag :tmp_dir
  test "failed expiry save retires the live target without publishing a durable outcome",
       %{tmp_dir: dir} do
    %{session: session, target: target, output: output, waiter: waiter, raw_status: raw_status} =
      start_live_expiry(dir)

    sessions_dir = SessionStore.sessions_dir(dir)
    backup = sessions_dir <> ".before-expiry"
    assert :ok = File.rename(sessions_dir, backup)
    assert :ok = File.write(sessions_dir, "unavailable snapshot directory")

    try do
      send(waiter.pid, :expire)

      assert {:error, {:tool_outcome_persistence_failed, _reason}} =
               Task.await(waiter, @event_timeout)

      assert_receive {:agent_event, ^session, {:approval_resolved, ^target, :approval_timeout}},
                     @event_timeout

      assert_receive {:agent_event, ^session, {:display_status_changed, ^raw_status}},
                     @event_timeout

      snapshot = Session.editor_snapshot(session)
      assert snapshot.pending_approval == nil
      assert snapshot.status == raw_status
      assert snapshot.display_status == raw_status

      assert {:error, :no_pending_approval} =
               Session.respond_to_approval(session, target, :approve_session)

      assert {:tool_call,
              %ToolCall{
                status: :error,
                terminal_reason: nil,
                duration_ms: nil,
                output: ^output,
                result: explanation
              }} =
               Enum.find(Session.messages(session), &match?({:tool_call, _}, &1))

      assert explanation =~ "result persistence is uncertain"
      assert explanation =~ "Tool approval timed out"
      refute_received {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{}}}
      refute_received {:agent_event, ^session, {:approval_resolved, ^target, :reject}}
      refute_received {:agent_event, ^session, {:approval_resolved, ^target, :approval_timeout}}
      refute_received {:agent_event, ^session, {:display_status_changed, ^raw_status}}
      assert Session.list_tool_trust(session) == %{}
    after
      assert :ok = File.rm(sessions_dir)
      assert :ok = File.rename(backup, sessions_dir)
    end

    assert {:ok, saved} = SessionStore.load(Session.session_id(session), dir)
    assert [%{status: :pending}] = saved.continuation.tool_checkpoint.calls

    send_provider_event(session, %Event.Error{
      kind: :provider_error,
      message: "Tool outcome persistence failed"
    })

    assert Session.editor_snapshot(session).pending_approval == nil
    assert Session.editor_snapshot(session).display_status == :error
    assert_receive {:agent_event, ^session, {:display_status_changed, :error}}, @event_timeout

    assert {:tool_call, %ToolCall{terminal_reason: nil, output: ^output}} =
             Enum.find(Session.messages(session), &match?({:tool_call, _}, &1))

    refute_received {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{}}}
  end

  @tag :tmp_dir
  test "restart installs each saved outcome before ToolEnd without reviving approvals", %{
    tmp_dir: dir
  } do
    {:ok, request, continuation} =
      Continuation.begin_request(
        Continuation.new(),
        "request-display-recovery",
        1,
        "write a file"
      )

    arguments = %{"path" => "a.txt", "content" => "saved"}

    assistant = %ReqLLM.Message{
      role: :assistant,
      tool_calls: [
        ReqLLM.ToolCall.new("call-display", "write_file", ~s({"path":"a.txt","content":"saved"}))
      ]
    }

    assert {:ok, checkpoint_id, checkpoint} =
             Continuation.checkpoint_tool_group(
               continuation,
               request.request_id,
               Enum.concat(request.messages, [assistant]),
               [%{tool_call_id: "call-display", name: "write_file", arguments: arguments}]
             )

    assert {:ok, admitted} =
             Continuation.admit_tool_effect(
               checkpoint,
               request.request_id,
               checkpoint_id,
               "call-display",
               "write_file",
               arguments
             )

    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()],
        session_store_dir: dir,
        persist?: true
      )

    for {outcome, reason} <- [
          {:complete, nil},
          {:denied, nil},
          {:cancelled, nil},
          {:error, nil},
          {:error, :approval_timeout}
        ] do
      metadata = %{is_error: outcome != :complete, tool_outcome: outcome}
      metadata = if reason, do: Map.put(metadata, :tool_outcome_reason, reason), else: metadata

      result =
        ReqLLM.Context.tool_result_message(
          "write_file",
          "call-display",
          "retained explanation",
          metadata
        )

      source =
        if outcome == :denied or reason == :approval_timeout, do: checkpoint, else: admitted

      assert {:ok, completed} =
               Continuation.complete_tool_effect(
                 source,
                 request.request_id,
                 checkpoint_id,
                 "call-display",
                 result
               )

      record_id = "saved-before-display-#{outcome}-#{reason}"

      assert :ok =
               SessionStore.save(
                 %{
                   id: record_id,
                   timestamp: "2026-01-01T00:00:00Z",
                   model_name: "test-model",
                   provider_name: "test",
                   messages: [{:tool_call, ToolCall.new("call-display", "write_file", arguments)}],
                   continuation: completed,
                   usage: %MingaAgent.TurnUsage{}
                 },
                 dir
               )

      assert :ok = Session.load_session(session, record_id)

      assert {:tool_call,
              %ToolCall{
                status: ^outcome,
                terminal_reason: ^reason,
                result: "retained explanation"
              }} =
               Enum.find(Session.messages(session), &match?({:tool_call, _}, &1))

      assert Session.editor_snapshot(session).pending_approval == nil
      assert Session.editor_snapshot(session).display_status == :idle
    end
  end

  @tag :tmp_dir
  test "loading a retained tool result uses the session's configured artifact runtime after restart",
       %{tmp_dir: dir} do
    suffix = System.unique_integer([:positive])

    artifact_opts = [
      name: Module.concat(__MODULE__, "ArtifactSupervisor#{suffix}"),
      root: Path.join(dir, "private-artifacts"),
      quota: Module.concat(__MODULE__, "ArtifactQuota#{suffix}"),
      registry: Module.concat(__MODULE__, "ArtifactRegistry#{suffix}"),
      store_supervisor: Module.concat(__MODULE__, "ArtifactStores#{suffix}")
    ]

    start_supervised!({MingaAgent.ArtifactSupervisor, artifact_opts})
    {:ok, runtime} = MingaAgent.ArtifactSupervisor.runtime(artifact_opts)
    record = "private-runtime-load"
    key = {:delivery, "private-runtime-checkpoint", "read"}
    {:ok, store} = ArtifactStores.ensure_record(record, runtime)
    {:ok, output} = MingaAgent.Tools.OutputCapture.bytes(store, key, "original retained text", [])
    tool_call = ToolCall.new("read", "read_file") |> ToolCall.complete(output.view, output)

    assert :ok =
             SessionStore.save(
               %{
                 id: record,
                 timestamp: "2026-01-01T00:00:00Z",
                 model_name: "test-model",
                 provider_name: "test",
                 messages: [{:tool_call, tool_call}],
                 continuation: Continuation.new(),
                 usage: %MingaAgent.TurnUsage{}
               },
               dir,
               artifact_runtime: runtime
             )

    assert :ok = ArtifactStore.release(store, key)
    assert :ok = DynamicSupervisor.terminate_child(artifact_opts[:store_supervisor], store)

    session =
      start_test_session(
        provider: Minga.Test.SessionMockProvider,
        provider_opts: [],
        session_store_dir: dir,
        artifact_runtime: runtime
      )

    assert :ok = Session.load_session(session, record)

    assert [{:tool_call, %ToolCall{status: :complete, output: restored}}] =
             Session.messages(session)

    {:ok, reopened} = ArtifactStores.ensure_record(record, runtime)

    assert {:ok, %{bytes: "original retained text"}} =
             ArtifactStore.fetch(reopened, restored.reference, restored.selection)
  end

  @tag :tmp_dir
  test "live Stop and provider death reconcile retained output without replacing a saved winner",
       %{tmp_dir: dir} do
    for interruption <- [:stop, :provider_death] do
      session =
        start_test_session(
          provider_restart_backoff_base_ms: 30_000,
          provider_restart_backoff_max_ms: 30_000,
          provider: Minga.Test.SessionContinuationProvider,
          provider_opts: [test_pid: self()],
          session_store_dir: dir,
          persist?: true
        )

      assert :ok = Session.subscribe(session)

      record_id = Session.session_id(session)
      on_exit(fn -> ArtifactStores.delete_record(record_id) end)
      assert :ok = Session.send_prompt(session, "inspect")
      assert_receive {:continuation_request, request}, @event_timeout
      args = %{"command" => "pwd"}
      call_ids = ["retained-stop", "legacy-stop", "unadmitted-stop", "saved-stop"]
      calls = Enum.map(call_ids, &%{tool_call_id: &1, name: "shell", arguments: args})

      assistant =
        ReqLLM.Context.assistant("",
          tool_calls: Enum.map(call_ids, &ReqLLM.ToolCall.new(&1, "shell", JSON.encode!(args)))
        )

      assert {:ok, checkpoint_id} =
               GenServer.call(
                 session,
                 {:checkpoint_tool_group, request.request_id, request.messages ++ [assistant],
                  calls}
               )

      for id <- call_ids do
        send_provider_event(session, %Event.ToolStart{tool_call_id: id, name: "shell", args: args})
      end

      assert Session.status(session) == :tool_executing

      assert {:ok, store} =
               GenServer.call(
                 session,
                 {:admit_tool_effect, request.request_id, checkpoint_id, "retained-stop", "shell",
                  args}
               )

      for id <- ["legacy-stop", "saved-stop"] do
        assert {:ok, ^store} =
                 GenServer.call(
                   session,
                   {:admit_tool_effect, request.request_id, checkpoint_id, id, "shell", args}
                 )
      end

      {:ok, retained} =
        MingaAgent.Tools.OutputCapture.bytes(
          store,
          {:delivery, checkpoint_id, "retained-stop"},
          "exact pre-Stop bytes",
          []
        )

      {:ok, saved_output} =
        MingaAgent.Tools.OutputCapture.bytes(
          store,
          {:delivery, checkpoint_id, "saved-stop"},
          "exact saved result",
          []
        )

      send_provider_event(session, %Event.ToolUpdate{
        tool_call_id: "retained-stop",
        name: "shell",
        partial_result: "exact pre-Stop bytes"
      })

      send_provider_event(session, %Event.ToolUpdate{
        tool_call_id: "legacy-stop",
        name: "shell",
        partial_result: "legacy captured chunk\n"
      })

      saved_result =
        ReqLLM.Context.tool_result_message("shell", "saved-stop", saved_output.view, %{
          tool_outcome: :complete,
          is_error: false,
          output: saved_output
        })

      assert :ok =
               GenServer.call(
                 session,
                 {:complete_tool_effect, request.request_id, checkpoint_id, "saved-stop",
                  saved_result}
               )

      message_ids =
        Map.new(
          for {message_id, {:tool_call, call}} <- Session.messages_with_ids(session),
              do: {call.id, message_id}
        )

      assert :ok = Session.toggle_tool_collapse(session, message_ids["retained-stop"])
      assert :ok = Session.toggle_tool_collapse(session, message_ids["retained-stop"])
      assert :ok = Session.toggle_tool_collapse(session, message_ids["saved-stop"])

      if interruption == :provider_death do
        send_provider_event(session, %Event.ToolUpdate{
          tool_call_id: "unadmitted-stop",
          name: "shell",
          partial_result: "legacy pre-approval bytes"
        })
      end

      send_provider_event(session, %Event.ToolApproval{
        tool_call_id: "unadmitted-stop",
        name: "shell",
        args: args,
        reply_to: self()
      })

      target = Target.new(record_id, request.request_id, "unadmitted-stop")

      assert_receive {:agent_event, ^session, {:approval_pending, %Public{target: ^target}}},
                     @event_timeout

      assert Session.editor_snapshot(session).display_status == :approval_waiting

      before_stop =
        Map.new(for {:tool_call, call} <- Session.messages(session), do: {call.id, call})

      refute before_stop["retained-stop"].collapsed
      refute before_stop["saved-stop"].collapsed
      assert before_stop["saved-stop"].status == :complete
      assert is_integer(before_stop["unadmitted-stop"].started_at)

      expected_status =
        case interruption do
          :stop ->
            assert :ok = Session.abort(session)
            :idle

          :provider_death ->
            Process.exit(Session.get_provider(session), :kill)
            assert_receive {:agent_event, ^session, {:status_changed, :error}}, @event_timeout
            :error
        end

      assert Session.status(session) == expected_status
      assert_receive {:tool_approval_response, "unadmitted-stop", :reject}, @event_timeout

      assert_receive {:agent_event, ^session, {:approval_resolved, ^target, :interrupted}},
                     @event_timeout

      assert Session.editor_snapshot(session).pending_approval == nil
      stopped = Map.new(for {:tool_call, call} <- Session.messages(session), do: {call.id, call})
      assert {:ok, saved} = SessionStore.load(record_id, dir)
      assert saved.continuation.tool_checkpoint == nil

      results =
        Map.new(
          for %ReqLLM.Message{role: :tool, tool_call_id: id} = message <-
                saved.continuation.messages,
              do: {id, message}
        )

      for id <- ["retained-stop", "legacy-stop"] do
        assert stopped[id].status == :error
        assert stopped[id].terminal_reason == nil
        assert stopped[id].is_error
        refute stopped[id].collapsed
        assert results[id].metadata.tool_outcome == :error
        assert results[id].metadata.is_error
        assert results[id].metadata.minga_effect_status == :indeterminate
        assert Map.get(results[id].metadata, :tool_outcome_reason) == nil

        assert stopped[id].result =~
                 "Tool effect outcome is indeterminate after interruption. The call was not rerun."
      end

      assert stopped["retained-stop"].output.reference == retained.reference
      assert results["retained-stop"].metadata.output === stopped["retained-stop"].output

      assert results["retained-stop"].content ==
               [ReqLLM.Message.ContentPart.text(stopped["retained-stop"].result)]

      assert {:ok, %{bytes: "exact pre-Stop bytes"}} =
               ArtifactStore.fetch(
                 store,
                 retained.reference,
                 stopped["retained-stop"].output.selection
               )

      assert stopped["legacy-stop"].output == nil
      assert stopped["legacy-stop"].result =~ "legacy captured chunk\n"
      assert Map.get(results["legacy-stop"].metadata, :output) == nil
      expected_outcome = if interruption == :stop, do: :cancelled, else: :error
      assert stopped["unadmitted-stop"].status == expected_outcome
      assert stopped["unadmitted-stop"].duration_ms == nil
      assert stopped["unadmitted-stop"].terminal_reason == nil
      assert stopped["unadmitted-stop"].collapsed == before_stop["unadmitted-stop"].collapsed
      assert results["unadmitted-stop"].metadata.tool_outcome == expected_outcome
      assert results["unadmitted-stop"].metadata.is_error
      assert results["unadmitted-stop"].metadata.minga_effect_status == :not_executed

      if interruption == :provider_death do
        assert stopped["unadmitted-stop"].result =~
                 "Tool call was not executed because interruption occurred before durable effect admission."

        assert stopped["unadmitted-stop"].result =~ "legacy pre-approval bytes"
      end

      assert stopped["saved-stop"] === before_stop["saved-stop"]
      assert results["saved-stop"] === saved_result

      assert {:ok, %{bytes: "exact saved result"}} =
               ArtifactStore.fetch(store, saved_output.reference, saved_output.selection)

      assert :ok = Session.abort(session)

      assert Map.new(for {:tool_call, call} <- Session.messages(session), do: {call.id, call}) ===
               stopped
    end
  end

  @tag :tmp_dir
  test "restart reconciles admitted and pending calls without replay and preserves opaque provider content",
       %{tmp_dir: dir} do
    record_id =
      "interrupted-checkpoint-" <>
        Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    on_exit(fn -> ArtifactStores.delete_record(record_id) end)

    {:ok, request, continuation} =
      Continuation.begin_request(Continuation.new(), "request-#{record_id}", 11, [
        ReqLLM.Message.ContentPart.text("inspect"),
        ReqLLM.Message.ContentPart.image(<<0, 255, 10>>, "image/png")
      ])

    assistant = %ReqLLM.Message{
      role: :assistant,
      content: [
        ReqLLM.Message.ContentPart.provider_block(:anthropic, %{
          "type" => "server_tool_use",
          "signature" => <<9, 0, 9>>
        })
      ],
      metadata: %{response_id: "response-interrupted", phase: :analysis},
      tool_calls: [
        ReqLLM.ToolCall.new(
          "call-interrupted",
          "write_file",
          ~s({"path":"a","content":"b","mode":"create"})
        ),
        ReqLLM.ToolCall.new(
          "call-pending",
          "write_file",
          ~s({"path":"a","content":"b","mode":"create"})
        )
      ],
      reasoning_details: [
        %ReqLLM.Message.ReasoningDetails{
          text: "opaque reasoning",
          signature: <<1, 2, 255>>,
          encrypted?: true,
          provider: :anthropic,
          format: "anthropic-v1",
          index: 0,
          provider_data: %{"redacted" => <<3, 0, 4>>}
        }
      ]
    }

    arguments = %{"path" => "a", "content" => "b", "mode" => "create"}

    {:ok, checkpoint_id, checkpointed} =
      Continuation.checkpoint_tool_group(
        continuation,
        request.request_id,
        Enum.concat(request.messages, [assistant]),
        [
          %{
            tool_call_id: "call-interrupted",
            name: "write_file",
            arguments: arguments
          },
          %{
            tool_call_id: "call-pending",
            name: "write_file",
            arguments: arguments
          }
        ]
      )

    {:ok, admitted} =
      Continuation.admit_tool_effect(
        checkpointed,
        request.request_id,
        checkpoint_id,
        "call-interrupted",
        "write_file",
        arguments
      )

    {:ok, artifact_store} = ArtifactStores.ensure_record(record_id)

    {:ok, capture_spec} =
      CaptureSpec.new(
        media_type: "text/plain",
        mode: :bytes,
        owner_pid: self(),
        delivery_key: {:delivery, checkpoint_id, "call-interrupted"}
      )

    {:ok, capture} = ArtifactStore.begin(artifact_store, capture_spec)

    assert {:ok, _progress} =
             ArtifactStore.append(artifact_store, capture, "exact pre-crash output")

    assert {:ok, retained} = ArtifactStore.finish(artifact_store, capture, :complete)

    assert :ok =
             SessionStore.save(
               %{
                 id: record_id,
                 timestamp: "2026-01-01T00:00:00Z",
                 model_name: "test-model",
                 provider_name: "test",
                 messages: [
                   {:user, "inspect"},
                   {:tool_call, ToolCall.new("call-interrupted", "write_file", arguments)},
                   {:tool_call, ToolCall.new("call-pending", "write_file", arguments)}
                 ],
                 continuation: admitted,
                 usage: %MingaAgent.TurnUsage{}
               },
               dir
             )

    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()],
        session_store_dir: dir,
        persist?: true
      )

    assert :ok = Session.load_session(session, record_id)

    assert Enum.any?(Session.messages(session), fn
             {:system, message, :error} ->
               message =~ "explicit indeterminate result" and message =~ "without replaying"

             _message ->
               false
           end)

    assert {:ok, recovered} = SessionStore.load(record_id, dir)
    assert recovered.continuation.tool_checkpoint == nil
    assert Enum.at(recovered.continuation.messages, -3) === assistant

    assert [not_executed_result, indeterminate_result | _rest] =
             Enum.reverse(recovered.continuation.messages)

    assert indeterminate_result.metadata.minga_effect_status == :indeterminate
    assert indeterminate_result.metadata.output.reference == retained.reference
    assert indeterminate_result.metadata.tool_outcome == :error
    assert indeterminate_result.metadata.is_error
    assert not_executed_result.metadata.tool_outcome == :error
    assert not_executed_result.metadata.is_error
    assert not_executed_result.metadata.minga_effect_status == :not_executed
    assert Session.editor_snapshot(session).pending_approval == nil
    restored = Map.new(for {:tool_call, call} <- Session.messages(session), do: {call.id, call})
    assert restored["call-interrupted"].status == :error
    assert restored["call-interrupted"].terminal_reason == nil
    assert restored["call-interrupted"].output === indeterminate_result.metadata.output
    assert restored["call-pending"].status == :error
    assert restored["call-pending"].terminal_reason == nil

    assert not_executed_result.content ==
             [ReqLLM.Message.ContentPart.text(restored["call-pending"].result)]

    assert {:ok, %{bytes: "exact pre-crash output"}} =
             ArtifactStore.fetch(
               artifact_store,
               retained.reference,
               indeterminate_result.metadata.output.selection
             )

    recovery_boundary_id =
      Enum.find_value(Session.messages_with_ids(session), fn
        {id, {:tool_call, %ToolCall{id: "call-pending"}}} -> id
        _message -> nil
      end)

    assert {:ok, branch} =
             Continuation.branch_at(
               recovered.continuation,
               "recovered-effects",
               recovery_boundary_id
             )

    assert branch.messages == recovered.continuation.messages
    assert :ok = Session.send_prompt(session, "continue safely")
    assert_receive {:continuation_request, resumed_request}, @event_timeout
    assert Enum.at(resumed_request.messages, -4) === assistant
    assert Enum.at(resumed_request.messages, -3).metadata.minga_effect_status == :indeterminate
    assert Enum.at(resumed_request.messages, -2).metadata.minga_effect_status == :not_executed
    assert [last_message | _rest] = Enum.reverse(resumed_request.messages)
    assert last_message == ReqLLM.Context.user("continue safely")
  end

  @tag :tmp_dir
  test "a restarted Session sends the exact durable provider continuation after display collapse",
       %{
         tmp_dir: dir
       } do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()],
        session_store_dir: dir,
        persist?: true
      )

    session_id = Session.session_id(session)

    parts = [
      ReqLLM.Message.ContentPart.text("inspect this"),
      ReqLLM.Message.ContentPart.image(<<0, 255, 10>>, "image/png")
    ]

    assert :ok = Session.send_prompt(session, parts)
    assert_receive {:continuation_request, request}, @event_timeout

    reasoning = %ReqLLM.Message.ReasoningDetails{
      text: "private provider reasoning",
      signature: <<0, 1, 255>>,
      encrypted?: true,
      provider: :anthropic,
      format: "anthropic-v1",
      index: 2,
      provider_data: %{"redacted_thinking" => <<3, 4, 5>>}
    }

    assistant_tool_message = %ReqLLM.Message{
      role: :assistant,
      content: [
        ReqLLM.Message.ContentPart.text("before"),
        ReqLLM.Message.ContentPart.provider_block(
          :anthropic,
          %{"type" => "server_tool_use", "signature" => <<9, 0, 9>>}
        ),
        ReqLLM.Message.ContentPart.text("after")
      ],
      metadata: %{response_id: "resp_resume", phase: :analysis, phase_items: ["item_1"]},
      tool_calls: [
        ReqLLM.ToolCall.new("call_resume", "read_file", ~s({"path":"README.md"}))
      ],
      reasoning_details: [reasoning]
    }

    messages =
      request.messages ++
        [
          assistant_tool_message,
          ReqLLM.Context.tool_result_message("read_file", "call_resume", "captured source", %{
            tool_outcome: :complete,
            is_error: false
          }),
          ReqLLM.Context.assistant("The attachment and source are readable.")
        ]

    assert :ok =
             Minga.Test.SessionContinuationProvider.complete(
               Session.get_provider(session),
               request,
               messages
             )

    :sys.get_state(session)
    assert {:ok, saved} = SessionStore.load(session_id, dir)
    assert saved.continuation.messages == messages

    [{display_tool_id, {:tool_call, _tool_call}}] =
      Enum.filter(Session.messages_with_ids(session), fn {_id, message} ->
        match?({:tool_call, _}, message)
      end)

    assert :ok = Session.toggle_tool_collapse(session, display_tool_id)
    assert :ok = Session.toggle_all_tool_collapses(session)
    assert {:ok, collapsed_saved} = SessionStore.load(session_id, dir)
    assert collapsed_saved.continuation.messages == messages

    monitor_ref = Process.monitor(session)
    GenServer.stop(session, :normal)
    assert_receive {:DOWN, ^monitor_ref, :process, ^session, :normal}, @event_timeout

    resumed =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()],
        session_store_dir: dir,
        persist?: true
      )

    assert :ok = Session.load_session(resumed, session_id)
    assert :ok = Session.send_prompt(resumed, "Follow-up")
    assert_receive {:continuation_request, resumed_request}, @event_timeout

    assert resumed_request.messages ==
             Enum.concat(messages, [ReqLLM.Context.user("Follow-up")])
  end

  defp start_live_expiry(dir) do
    session =
      start_test_session(
        provider: Minga.Test.SessionContinuationProvider,
        provider_opts: [test_pid: self()],
        session_store_dir: dir,
        persist?: true
      )

    assert :ok = Session.subscribe(session)
    assert :ok = Session.send_prompt(session, "inspect")
    assert_receive {:continuation_request, request}, @event_timeout
    args = %{"command" => "pwd"}

    assistant =
      ReqLLM.Context.assistant("",
        tool_calls: [ReqLLM.ToolCall.new("expiry-call", "shell", JSON.encode!(args))]
      )

    assert {:ok, checkpoint_id} =
             GenServer.call(
               session,
               {:checkpoint_tool_group, request.request_id, request.messages ++ [assistant],
                [%{tool_call_id: "expiry-call", name: "shell", arguments: args}]}
             )

    send_provider_event(session, %Event.ToolStart{
      tool_call_id: "expiry-call",
      name: "shell",
      args: args
    })

    raw_status = Session.status(session)
    assert raw_status == :tool_executing

    assert_receive {:agent_event, ^session, {:display_status_changed, ^raw_status}},
                   @event_timeout

    text = "Tool approval timed out"
    {:ok, selection} = Range.new(:full, :bytes, 0, byte_size(text), byte_size(text))
    {:ok, output} = Output.new(text, :complete, selection)

    result =
      ReqLLM.Context.tool_result_message("shell", "expiry-call", text, %{
        tool_outcome: :error,
        tool_outcome_reason: :approval_timeout,
        is_error: true,
        output: output
      })

    waiter =
      Task.async(fn ->
        receive do
          :expire ->
            GenServer.call(
              session,
              {:complete_tool_effect, request.request_id, checkpoint_id, "expiry-call", result}
            )
        end
      end)

    on_exit(fn -> Process.exit(waiter.pid, :kill) end)

    send_provider_event(session, %Event.ToolApproval{
      tool_call_id: "expiry-call",
      name: "shell",
      args: args,
      reply_to: waiter.pid
    })

    assert_receive {:agent_event, ^session,
                    {:approval_pending, %Public{target: target} = approval}},
                   @event_timeout

    assert target == Target.new(Session.session_id(session), request.request_id, "expiry-call")
    assert Session.editor_snapshot(session).pending_approval == approval
    assert Session.editor_snapshot(session).display_status == :approval_waiting

    assert_receive {:agent_event, ^session, {:display_status_changed, :approval_waiting}},
                   @event_timeout

    assert Process.alive?(waiter.pid)

    %{
      session: session,
      request: request,
      checkpoint_id: checkpoint_id,
      target: target,
      result: result,
      output: output,
      waiter: waiter,
      raw_status: raw_status
    }
  end
end
