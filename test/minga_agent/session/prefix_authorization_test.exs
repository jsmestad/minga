defmodule MingaAgent.Session.PrefixAuthorizationTest do
  # Advice, project discovery and scoped cwd use shared owners; the approved shell spawns an OS process.
  use ExUnit.Case, async: false

  alias Minga.Config.Advice
  alias Minga.Config.Options
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaAgent.ProjectView
  alias MingaAgent.ArtifactStore
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias MingaAgent.ArtifactStores
  alias MingaAgent.ArtifactSupervisor
  alias MingaAgent.Checklist
  alias MingaAgent.Credentials
  alias MingaAgent.DraftAttachment
  alias MingaAgent.DraftSnapshot
  alias MingaAgent.Event
  alias MingaAgent.EventLog
  alias MingaAgent.OAuth
  alias MingaAgent.Providers.Native
  alias MingaAgent.Session
  alias MingaAgent.Session.Continuation
  alias MingaAgent.Session.Outcome
  alias MingaAgent.Session.PrefixStore
  alias MingaAgent.SessionStore
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.Tool.Registry, as: ToolRegistry
  alias MingaAgent.Tool.Spec
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target
  alias ReqLLM.StreamChunk

  @moduletag :tmp_dir
  @timeout 5_000
  @source {:extension, :prefix_authority_fixture}

  setup_all do
    # Native stream fixtures and cost calculation use the real catalog before tool events arrive.
    # Load it before tests start their event deadlines.
    assert [_ | _] = LLMDB.models()
    :ok
  end

  setup %{tmp_dir: dir} do
    Advice.reset()
    on_exit(&Advice.reset/0)
    suffix = System.unique_integer([:positive])
    events = unique_name("Events", suffix)
    start_supervised!({Registry, name: events, keys: :duplicate})
    options_name = unique_name("Options", suffix)
    options_opts = [name: options_name, events_registry: events]
    options_child = {:options, suffix}
    options = start_supervised!({Options, options_opts}, id: options_child)
    assert {:ok, :none} = Options.set(options_name, :agent_tool_approval, :none)
    registry = unique_name("Tools", suffix)
    start_supervised!({ToolRegistry, name: registry})
    journal = unique_name("Journal", suffix)

    start_supervised!(
      {EventLog,
       name: journal,
       db_dir: Path.join(dir, "events"),
       retention_sweep?: false,
       health_check: :none},
      id: {:journal, suffix}
    )

    artifact_opts = [
      name: unique_name("Artifacts", suffix),
      root: Path.join(dir, "artifacts"),
      quota: unique_name("Quota", suffix),
      registry: unique_name("ArtifactRegistry", suffix),
      store_supervisor: unique_name("ArtifactStores", suffix)
    ]

    start_supervised!({ArtifactSupervisor, artifact_opts}, id: {:artifacts, suffix})
    {:ok, runtime} = ArtifactSupervisor.runtime(artifact_opts)
    oauth_path = Path.join(dir, "credentials/oauth.json")

    assert :ok =
             OAuth.write_oauth_file(
               %{
                 access: "fixture-access",
                 refresh: "fixture-refresh",
                 expires: System.system_time(:millisecond) + 3_600_000,
                 account_id: "fixture-account"
               },
               oauth_path
             )

    env =
      Map.new(Credentials.known_providers(), fn provider ->
        {Credentials.env_var_for(provider), nil}
      end)

    credential_opts = [
      config_dir: Path.join(dir, "credentials"),
      env: env,
      oauth_path: oauth_path
    ]

    resolver_opts = ModelSelectionFixture.resolver_opts(model_id: "gpt-6.1-sol")
    other = ModelSelectionFixture.resolver_opts(model_id: "other-model")[:models]

    resolver_opts =
      resolver_opts
      |> Keyword.delete(:credential_snapshot)
      |> Keyword.update!(:models, &(&1 ++ other))

    File.mkdir_p!(Path.join(dir, "project"))

    %{
      dir: dir,
      project: Path.join(dir, "project"),
      runtime: runtime,
      registry: registry,
      journal: journal,
      options: options,
      options_name: options_name,
      options_opts: options_opts,
      options_child: options_child,
      resolver_opts: resolver_opts,
      credential_opts: credential_opts,
      store_dir: Path.join(dir, "records"),
      suffix: suffix
    }
  end

  for {response, outcome} <- [
        {{:choice, 1}, %{"status" => "answered", "answer" => "Keep existing output"}},
        {{:text, "Keep café output"}, %{"status" => "answered", "answer" => "Keep café output"}},
        {:cancel, %{"status" => "cancelled"}}
      ] do
    test "a capable driver resolves one exact durable clarification with #{inspect(response)}",
         context do
      prompt = "Which behavior should I preserve?"
      choices = ["Keep output format", "Keep existing output"]

      session =
        start_session(context,
          questions?: true,
          tool_calls: [{"ask_user", %{"prompt" => prompt, "choices" => choices}, "clarify-1"}]
        )

      assert :ok = Session.send_prompt(session, "Clarify the behavior")
      assert_receive {:transport_request, 1, _, options}, @timeout
      assert Enum.any?(options[:tools], &(&1.name == "ask_user"))

      assert_receive {:agent_event, ^session, {:question_requested, target, question}}, @timeout
      assert %{prompt: ^prompt, choices: ^choices} = question
      assert {^target, ^question} = Session.pending_question(session)
      refute_receive {:transport_request, 2, _, _}, 0
      assert :ok = Session.unsubscribe(session)
      assert {^target, ^question} = Session.pending_question(session)
      assert :ok = Session.subscribe(session, self(), role: :viewer, questions?: true)

      assert {:error, :not_driver} =
               Session.respond_to_question_as(session, self(), target, :cancel)

      assert :ok = Session.claim_driver(session, self())

      assert {:error, :invalid_answer} =
               Session.respond_to_question_as(session, self(), target, {:choice, 12})

      assert :ok =
               Session.respond_to_question_as(
                 session,
                 self(),
                 target,
                 unquote(Macro.escape(response))
               )

      assert {:error, :question_not_found} =
               Session.respond_to_question_as(session, self(), target, :cancel)

      assert_receive {:transport_request, 2, messages, _}, @timeout
      assert [%{tool_call_id: "clarify-1"} = result] = Enum.filter(messages, &(&1.role == :tool))

      assert JSON.decode!(Enum.map_join(result.content, "", & &1.text)) ==
               unquote(Macro.escape(outcome))

      await_done(session, "ask_user")
      assert saved_tool_result(context, session, "clarify-1").content == result.content
      assert Session.list_tool_trust(session) == %{}
    end
  end

  test "a session without a capable driver does not advertise clarification", context do
    session = start_session(context, tool_call?: false)
    assert :ok = Session.send_prompt(session, "No clarification surface")
    assert_receive {:transport_request, 1, _, options}, @timeout
    refute Enum.any?(options[:tools], &(&1.name == "ask_user"))
    await_idle(session)
  end

  for initially_capable? <- [true, false] do
    test "retained native history does not change its tool schema when driver capability was #{initially_capable?}",
         context do
      initial = unquote(initially_capable?)
      session = start_session(context, questions?: initial, tool_call?: false)

      assert :ok = Session.send_prompt(session, "Before capability change")
      assert_receive {:transport_request, 1, _, before}, @timeout
      assert Enum.any?(before[:tools], &(&1.name == "ask_user")) == initial
      await_idle(session)

      assert :ok = Session.unsubscribe(session)
      assert :ok = Session.subscribe(session, self(), questions?: not initial)

      assert :ok = Session.send_prompt(session, "After capability change")
      assert_receive {:transport_request, 2, _, current}, @timeout
      assert Enum.any?(current[:tools], &(&1.name == "ask_user")) == initial
      await_idle(session)
    end
  end

  for answer_queued_first? <- [true, false] do
    test "a dead clarification worker cannot answer or open the next question, answer queued first: #{answer_queued_first?}",
         context do
      session =
        start_session(context,
          questions?: true,
          tool_calls: [
            {"ask_user", %{"prompt" => "Which output?"}, "first-question"},
            {"ask_user", %{"prompt" => "Which format?"}, "second-question"}
          ]
        )

      assert :ok = Session.send_prompt(session, "Clarify both settings")
      assert_receive {:agent_event, ^session, {:question_requested, target, _}}, @timeout
      assert target.tool_call_id == "first-question"

      %{turn_execution: execution} = :sys.get_state(session)
      %{reply_to: {worker, _}} = Session.TurnExecution.pending_question(execution)

      if unquote(answer_queued_first?) do
        assert :ok = :sys.suspend(session)
        reply = make_ref()

        try do
          send(
            session,
            {:"$gen_call", {self(), reply}, {:respond_to_question_as, self(), target, :cancel}}
          )

          stop_question_worker(worker)
        after
          :sys.resume(session)
        end

        assert_receive {^reply, {:error, :question_not_found}}, @timeout
      else
        stop_question_worker(worker)
      end

      assert_receive {:agent_event, ^session, {:question_interrupted, ^target}}, @timeout
      assert_receive {:agent_event, ^session, {:error, _message}}, @timeout
      assert Session.pending_question(session) == nil

      assert {:error, :question_not_found} =
               Session.respond_to_question_as(session, self(), target, :cancel)

      refute_receive {:agent_event, ^session, {:question_cancelled, ^target}}, 0
      refute_receive {:agent_event, ^session, {:question_requested, _, _}}, 0
      refute_receive {:transport_request, 2, _, _}, 0
    end
  end

  test "aborting a waiting clarification retires its exact target without answering", context do
    session =
      start_session(context,
        questions?: true,
        tool_calls: [{"ask_user", %{"prompt" => "Which output?"}, "interrupted-question"}]
      )

    assert :ok = Session.send_prompt(session, "Clarify first")
    assert_receive {:agent_event, ^session, {:question_requested, target, _}}, @timeout
    assert :ok = Session.abort(session)
    assert_receive {:agent_event, ^session, {:question_interrupted, ^target}}, @timeout
    assert Session.pending_question(session) == nil

    assert {:error, :question_not_found} =
             Session.respond_to_question_as(session, self(), target, {:text, "Too late"})

    refute_receive {:transport_request, 2, _, _}, 0
  end

  test "reopening a waiting clarification makes the interruption explicit without asking again",
       context do
    session =
      start_session(context,
        questions?: true,
        tool_calls: [{"ask_user", %{"prompt" => "Which output?"}, "restart-question"}]
      )

    record = Session.session_id(session)
    assert :ok = Session.send_prompt(session, "Clarify before restart")
    assert_receive {:transport_request, 1, _, _}, @timeout
    assert_receive {:agent_event, ^session, {:question_requested, target, _}}, @timeout
    assert :ok = stop_supervised!({:session, context.suffix})

    restored = start_session(context, questions?: true, tool_call?: false)
    assert :ok = Session.load_session(restored, record)
    assert Session.pending_question(restored) == nil

    assert {:error, :question_not_found} =
             Session.respond_to_question_as(restored, self(), target, {:text, "Too late"})

    result = saved_tool_result(context, restored, "restart-question")
    assert Enum.map_join(result.content, "", & &1.text) =~ "Clarification interrupted"
    refute_receive {:transport_request, _, _, _}, 0
  end

  test "the broker requires private driver proof and preserves the exact question across detach",
       context do
    alias MingaAgent.RemoteAPI

    opts =
      native_session_options(context,
        tool_calls: [{"ask_user", %{"prompt" => "Which output?"}, "remote-question"}]
      )

    assert {:ok, %{session_id: id, pid: session, token: token}} = RemoteAPI.start_session(opts)
    on_exit(fn -> RemoteAPI.stop_session(id, token) end)

    assert {:ok, %{role: :driver}} =
             RemoteAPI.attach(id, token, self(), role: :driver, questions?: true)

    assert_receive {:agent_question_attachment, ^session, original_receipt}, @timeout

    assert :ok = RemoteAPI.send_prompt(id, token, self(), "Clarify remotely")
    assert_receive {:transport_request, 1, _, _}, @timeout
    assert_receive {:agent_event, ^session, {:question_requested, target, question}}, @timeout

    driver = self()

    viewer =
      Task.async(fn ->
        assert {:ok, %{role: :viewer}} =
                 RemoteAPI.attach(id, token, self(), role: :viewer, questions?: true)

        assert {:error, :not_driver} = RemoteAPI.detach(id, token, driver)
        assert {:error, :not_driver} = RemoteAPI.detach(id, token, {driver, <<0::256>>})

        assert {:error, :invalid_event_cursor} =
                 RemoteAPI.attach(id, token, driver, role: :driver, last_seen_event_id: -1)

        assert {:error, :driver_taken} = Session.claim_driver(session, self())

        assert {:error, :not_driver} =
                 RemoteAPI.respond_to_question(id, token, driver, target, :cancel)

        assert {:error, :not_driver} =
                 RemoteAPI.respond_to_question(
                   id,
                   token,
                   {driver, :binary.copy(<<0>>, 32)},
                   target,
                   :cancel
                 )

        refute_received {:agent_question_attachment, ^session, _}
        :ok
      end)

    assert :ok = Task.await(viewer)
    assert {:ok, {^target, ^question}} = RemoteAPI.pending_question(id, token)

    assert {:error, :not_driver} =
             Session.respond_to_question_as(session, driver, target, :cancel)

    assert :driver = Session.subscriber_role(session, driver)
    assert :ok = RemoteAPI.detach(id, token, {driver, original_receipt})
    assert {:error, :unauthorized} = RemoteAPI.pending_question(id, "invalid token")
    assert {:ok, {^target, ^question}} = RemoteAPI.pending_question(id, token)

    assert {:error, :not_driver} =
             RemoteAPI.respond_to_question(id, token, {driver, original_receipt}, target, :cancel)

    assert {:ok, %{role: :viewer}} = RemoteAPI.attach(id, token, self(), role: :viewer)

    assert {:error, :not_driver} =
             RemoteAPI.respond_to_question(id, token, {driver, original_receipt}, target, :cancel)

    assert :ok = RemoteAPI.detach(id, token, self())

    assert {:ok, %{role: :driver, snapshot: %{pending_question: {^target, ^question}}}} =
             RemoteAPI.attach(id, token, self(), role: :driver, questions?: true)

    assert_receive {:agent_question_attachment, ^session, current_receipt}, @timeout

    assert {:error, :not_driver} =
             RemoteAPI.respond_to_question(id, token, {driver, original_receipt}, target, :cancel)

    assert :ok =
             RemoteAPI.respond_to_question(id, token, {driver, current_receipt}, target, :cancel)

    assert_receive {:transport_request, 2, messages, _}, @timeout

    assert [%{tool_call_id: "remote-question"} = result] =
             Enum.filter(messages, &(&1.role == :tool))

    assert JSON.decode!(Enum.map_join(result.content, "", & &1.text)) == %{
             "status" => "cancelled"
           }

    await_done(session, "ask_user")
  end

  for model_id <- ["gpt-6.1-sol", "gpt-5.6-luna", "gpt-5.6-terra"] do
    test "#{model_id} preserves its actual wire prefix and opaque reasoning through restart",
         context do
      model_id = unquote(model_id)
      install_write_tool(context)

      resolver_opts =
        ModelSelectionFixture.resolver_opts(model_id: model_id)
        |> Keyword.delete(:credential_snapshot)

      opts = [
        model: "openai:#{model_id}",
        tool_call?: false,
        wire?: true,
        opaque?: true,
        provider_opts: [model_resolver_opts: resolver_opts]
      ]

      session = start_session(context, opts)
      assert :ok = Session.send_prompt(session, "first")
      assert_receive {:transport_request, 1, _messages, _options}, @timeout
      assert_receive {:wire_request, 1, first_wire}, @timeout
      await_idle(session)
      record = Session.session_id(session)

      assert {:ok, saved} =
               SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

      captured =
        PrefixStore.resolve(saved.continuation.prefixes, saved.continuation.prefixes.selected)

      {instructions, tools} = wire_prefix(first_wire)
      assert instructions == captured.instructions
      assert Enum.any?(tools, &(&1["name"] == "prefix_write"))

      # Reproduce records written before these routes were qualified without rewriting their evidence.
      restored =
        if model_id == "gpt-6.1-sol" do
          saved
        else
          assert {:ok, historical_prefix} =
                   PrefixStore.candidate(
                     :unknown,
                     captured.instructions,
                     captured.schemas,
                     Map.put(captured.identity, :native_contract, :unknown),
                     captured.skills
                   )

          assert {:ok, :applied, initial} =
                   Continuation.change_prefix(Continuation.new(), historical_prefix)

          user_id =
            Enum.zip(saved.message_ids, saved.messages)
            |> Enum.find_value(fn
              {id, {:user, "first"}} -> id
              _other -> nil
            end)

          assert {:ok, request, active} =
                   Continuation.begin_request(initial, "historical-request", user_id, "first")

          outcome = Outcome.new(request, saved.continuation.messages)
          boundary = List.last(saved.continuation.boundaries)

          assert {:ok, historical} =
                   Continuation.complete(active, outcome, boundary.transcript_id)

          Map.put(saved, :continuation, Continuation.mark_durable(historical))
        end

      restored = Map.put(restored, :model_selection, GenServer.call(session, :model_selection))

      assert :ok =
               SessionStore.save(restored, context.store_dir, artifact_runtime: context.runtime)

      assert :ok = stop_supervised!({:session, context.suffix})
      restarted = start_session(context, opts)
      assert :ok = Session.load_session(restarted, record)
      assert :ok = Session.send_prompt(restarted, "second")
      assert_receive {:transport_request, 1, second_messages, _options}, @timeout
      assert_receive {:wire_request, 1, second_wire}, @timeout
      await_idle(restarted)

      assert Enum.take(second_messages, length(restored.continuation.messages)) ==
               restored.continuation.messages

      assert wire_prefix(second_wire) == {instructions, tools}

      assert Enum.any?(second_wire["input"], fn item ->
               item["type"] == "reasoning" and item["id"] == "rs_fixture_1" and
                 item["encrypted_content"] == "fixture-opaque-1"
             end)

      assert {:ok, final} =
               SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

      assert final.continuation.prefixes == restored.continuation.prefixes

      assert Enum.filter(Session.messages(restarted), &match?({:user, _text}, &1)) ==
               [{:user, "first"}, {:user, "second"}]

      refute_received :callback_built
    end
  end

  defp wire_prefix(%{"instructions" => instructions, "tools" => tools}),
    do: {instructions, tools}

  defp wire_prefix(%{"input" => input, "reasoning" => %{"context" => "all_turns"}} = wire) do
    refute Map.has_key?(wire, "instructions")
    refute Map.has_key?(wire, "tools")

    assert [
             %{"type" => "additional_tools", "role" => "developer", "tools" => tools},
             %{
               "type" => "message",
               "role" => "developer",
               "content" => [%{"type" => "input_text", "text" => instructions}]
             }
             | _
           ] = input

    {instructions, tools}
  end

  test "reopening at Native's tool handoff restores steering once and leaves Queue Next pending",
       context do
    install_write_tool(context)

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{"prefix_write" => :ask})

    session = start_session(context, hold_transport: 2)
    assert :ok = Session.send_prompt(session, "write once")

    assert_receive {:agent_event, ^session,
                    {:approval_pending, %Public{target: %Target{} = approval_target}}},
                   @timeout

    assert {:queued, :steering} = Session.send_prompt(session, "steer now")
    record = Session.session_id(session)
    opts = [artifact_runtime: context.runtime]

    draft = %DraftSnapshot{
      text: "after this turn",
      cursor: {0, 0},
      paste_blocks: [],
      attachments: []
    }

    assert {:ok, 1, attachment} =
             SessionStore.attach_text(
               record,
               0,
               draft,
               {:selection, "note.ex", "note.ex", "original bytes"},
               context.store_dir,
               opts
             )

    assert {:ok, target} = Session.queue_target(session, record)
    token = "queue-submission-token01"
    shown = [DraftAttachment.identity(attachment)]

    assert {:ok, {2, ^token, :follow_up, 2}} =
             Session.submit_queued_draft(
               session,
               target,
               :follow_up,
               {1, token, shown, draft.text},
               draft.text
             )

    assert {:ok, 2, nil} = SessionStore.read_presentation(record, context.store_dir, opts)
    assert :ok = Session.respond_to_approval(session, approval_target, :approve)

    assert_receive {:transport_request, 2, messages, _options}, @timeout

    assert %ReqLLM.Message{role: :user, content: [%{text: "steer now"}]} = List.last(messages)

    refute Enum.any?(messages, fn message ->
             Enum.any?(message.content || [], &match?(%{text: "after this turn"}, &1))
           end)

    assert :ok = stop_supervised!({:session, context.suffix})
    restored = start_session(context, tool_call?: false)
    assert :ok = Session.load_session(restored, record)

    assert {[], [[%{text: "after this turn"}, %{text: retained}]]} =
             Session.get_queued_messages(restored)

    assert retained =~ "original bytes"

    assert {:ok, saved} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert saved.continuation.tool_checkpoint == nil

    assert Enum.count(saved.continuation.messages, fn
             %ReqLLM.Message{role: :user, content: [%{text: "steer now"}]} -> true
             _ -> false
           end) == 1

    refute_receive {:transport_request, 3, _, _}, 0

    newer = %DraftSnapshot{draft | text: "new composer text", cursor: {0, 4}}
    assert {:ok, 3} = SessionStore.save_presentation(record, 2, newer, context.store_dir, opts)
    stale_recall = make_ref()

    assert :ok =
             Session.request_composer_draft(
               restored,
               record,
               stale_recall,
               {:recall, 2, newer, :keep_running}
             )

    assert_receive {:composer_draft_result, ^restored, ^record, ^stale_recall,
                    {:error, {:stale_draft_revision, 3}}},
                   @timeout

    current = %DraftSnapshot{newer | text: "not yet autosaved"}
    recall = make_ref()

    assert :ok =
             Session.request_composer_draft(
               restored,
               record,
               recall,
               {:recall, 3, current, :keep_running}
             )

    assert_receive {:composer_draft_result, ^restored, ^record, ^recall, {:ok, 4, recalled}},
                   @timeout

    assert recalled.text == "after this turn\n\nnot yet autosaved"
    assert recalled.cursor == {2, 4}
    assert recalled.attachments == [attachment]
    assert Session.get_queued_messages(restored) == {[], []}
    assert {:ok, 4, ^recalled} = SessionStore.read_presentation(record, context.store_dir, opts)

    assert {:ok, ^attachment, "original bytes"} =
             SessionStore.read_draft_attachment(record, hd(shown), context.store_dir, opts)
  end

  test "revocation during approval is an ordinary durable refusal, not a storage failure",
       context do
    install_write_tool(context)

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{"prefix_write" => :ask})

    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write once")

    assert_receive {:agent_event, ^session,
                    {:approval_pending, %Public{target: %Target{} = approval_target}}},
                   @timeout

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{"prefix_write" => :deny})

    assert :ok = Session.respond_to_approval(session, approval_target, :approve)
    await_done(session)
    assert_refused(context, session)
    refute_received :callback_built
    refute File.exists?(target(context))
  end

  test "removed sources refuse effects while the active unqualified request finishes",
       context do
    install_write_tool(context)
    before_start_barrier()
    owner = self()
    calls = :atomics.new(1, [])

    resolver_opts =
      ModelSelectionFixture.resolver_opts(
        model_id: "gpt-6.1-sol",
        provider_model_id: "unqualified-native-route"
      )
      |> Keyword.delete(:credential_snapshot)

    client = fn model, messages, options ->
      count = :atomics.add_get(calls, 1, 1)
      send(owner, {:transport_request, count, messages, options})

      chunks =
        if count == 1 do
          [
            StreamChunk.thinking("opaque fixture summary", %{
              signature: "fixture-refused-opaque",
              encrypted?: true,
              provider: :openai_codex,
              format: "openai-responses-v1",
              provider_data: %{"type" => "reasoning", "id" => "rs_refused_fixture"}
            }),
            StreamChunk.tool_call("prefix_write", %{"path" => "effect.txt"}, %{id: "prefix-call"}),
            StreamChunk.meta(%{finish_reason: :tool_use})
          ]
        else
          [StreamChunk.text("refused"), StreamChunk.meta(%{finish_reason: :stop})]
        end

      stream_response(model, chunks)
    end

    session =
      start_session(context,
        provider_opts: [
          llm_client: client,
          model_resolver_opts: resolver_opts
        ]
      )

    assert :ok = Session.send_prompt(session, "write once")
    assert_receive {:before_start, worker}, @timeout
    record = Session.session_id(session)

    assert {:ok, checkpoint} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    frozen = checkpoint.continuation.tool_checkpoint.messages

    assert Enum.any?(frozen, fn message ->
             Enum.any?(
               message.reasoning_details || [],
               &(&1.signature == "fixture-refused-opaque")
             )
           end)

    assert :ok = ToolRegistry.unregister_source(context.registry, @source)
    send(worker, :continue_start)

    assert_receive {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{name: "prefix_write"}}},
                   @timeout

    await_idle(session)
    assert Session.editor_snapshot(session).error == nil
    assert_receive {:transport_request, 2, continued, _options}, @timeout
    assert Enum.take(continued, length(frozen)) == frozen
    assert Session.session_id(session) == record

    assert {:ok, saved} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert saved.continuation.prefixes == checkpoint.continuation.prefixes
    assert Enum.take(saved.continuation.messages, length(frozen)) == frozen
    assert_receive {:transport_request, 1, _messages, _options}, @timeout
    assert saved_tool_result(context, session).metadata.is_error == true
    refute_received :callback_built
    refute File.exists?(target(context))

    assert {:error, {:portable_context_transition_required, _}} =
             Session.send_prompt(session, "continue")

    assert {:ok, retained} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert retained.continuation == saved.continuation

    refute_receive {:transport_request, 3, _messages, _options}, 0
  end

  test "same-name same-schema replacement does not inherit the earlier approval subject",
       context do
    install_write_tool(context)

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{"prefix_write" => :ask})

    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write once")

    assert_receive {:agent_event, ^session,
                    {:approval_pending, %Public{target: %Target{} = approval_target}}},
                   @timeout

    install_write_tool(context, "replacement\n")
    assert :ok = Session.respond_to_approval(session, approval_target, :approve)
    await_done(session)
    assert_refused(context, session)
    refute_received :callback_built
    refute File.exists?(target(context))
  end

  test "permission changes before the final callback gate cannot use cached configuration",
       context do
    install_write_tool(context)
    before_start_barrier()
    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write once")
    assert_receive {:before_start, worker}, @timeout

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{"prefix_write" => :deny})

    send(worker, :continue_start)
    await_done(session)
    assert_refused(context, session)
    refute File.exists?(target(context))
  end

  test "allow deny allow between policy reads invalidates the final start", context do
    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{
               "prefix_write" => :allow
             })

    run_policy_fence(context, fn ->
      assert {:ok, _} =
               Options.set(context.options_name, :agent_tool_permissions, %{
                 "prefix_write" => :deny
               })

      assert {:ok, _} =
               Options.set(context.options_name, :agent_tool_permissions, %{
                 "prefix_write" => :allow
               })
    end)
  end

  test "reset reseeding cannot validate an older permissive publication", context do
    run_policy_fence(context, fn -> assert :ok = Options.reset(context.options_name) end)
  end

  test "replacing the Options table invalidates its former incarnation", context do
    run_policy_fence(context, fn ->
      assert :ok = stop_supervised(context.options_child)
      start_supervised!({Options, context.options_opts}, id: context.options_child)
    end)
  end

  test "an invocation that won admission can settle after source and permission revocation",
       context do
    parent = self()

    install_write_tool(context, "admitted\n", fn ->
      send(parent, {:callback_started, self()})
      receive do: (:settle -> :ok)
    end)

    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write once")
    assert_receive {:callback_started, worker}, @timeout
    assert :ok = ToolRegistry.unregister_source(context.registry, @source)

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{"prefix_write" => :deny})

    send(worker, :settle)
    await_done(session)
    assert File.read!(target(context)) == "admitted\n"
    assert saved_tool_result(context, session).metadata.is_error == false
    assert Session.editor_snapshot(session).error == nil
  end

  test "an advice continuation cannot start the same correlated call twice", context do
    parent = self()
    install_write_tool(context)

    Advice.register(:around, :prefix_write, fn inner, state ->
      first = inner.(state)
      send(parent, {:second_start, inner.(state)})
      first
    end)

    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write once")
    await_done(session)
    assert File.read!(target(context)) == "written\n"

    assert_receive {:second_start, {:returned, _state, {:error, {:tool_refused, _reason}}}},
                   @timeout

    assert saved_tool_result(context, session).metadata.is_error == false
  end

  test "busy and retained-native skill changes reject before effective activation", context do
    write_skill(context, "selected")
    install_write_tool(context)
    before_start_barrier()
    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write once")
    assert_receive {:before_start, worker}, @timeout
    assert {:error, :request_active} = Session.activate_skill(session, "selected")
    assert {:error, :request_active} = Session.set_model(session, "openai:other-model")
    selection = Session.editor_snapshot(session).model_selection
    assert {:error, :request_active} = Session.set_thinking_level(session, "low")
    assert Session.editor_snapshot(session).model_selection == selection
    assert {:ok, _skills, []} = Session.list_skills(session)
    send(worker, :continue_start)
    await_done(session)

    assert {:error, {:portable_context_transition_required, _}} =
             Session.activate_skill(session, "selected")

    assert {:ok, _skills, []} = Session.list_skills(session)
  end

  test "failed prefix persistence retains the previous record and effective skills", context do
    write_skill(context, "first")
    write_skill(context, "second")
    session = start_session(context)
    assert {:ok, _skill} = Session.activate_skill(session, "first")
    record = Session.session_id(session)

    assert {:ok, original} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    directory = SessionStore.sessions_dir(context.store_dir)
    backup = directory <> ".saved"
    assert :ok = File.rename(directory, backup)
    File.write!(directory, "blocked fixture directory")
    assert {:error, {:prefix_persistence_failed, _}} = Session.activate_skill(session, "second")
    assert {:ok, _skills, ["first"]} = Session.list_skills(session)
    assert :ok = File.rm(directory)
    assert :ok = File.rename(backup, directory)

    assert {:ok, saved} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert saved.continuation == original.continuation
    assert {:ok, _skill} = Session.activate_skill(session, "second")
    assert {:ok, _skills, ["first", "second"]} = Session.list_skills(session)
    refute_receive {:transport_request, _count, _messages, _options}, 0
  end

  test "an unqualified route keeps active tool signatures but projects retained history on the next turn",
       context do
    install_write_tool(context)

    resolver_opts =
      ModelSelectionFixture.resolver_opts(
        model_id: "gpt-6.1-sol",
        provider_model_id: "unqualified-native-route"
      )
      |> Keyword.delete(:credential_snapshot)

    session =
      start_session(context, opaque?: true, provider_opts: [model_resolver_opts: resolver_opts])

    assert :ok = Session.send_prompt(session, "first")
    await_done(session)
    assert_receive {:transport_request, 1, _messages, _options}, @timeout
    assert_receive {:transport_request, 2, _messages, _options}, @timeout
    assert :ok = Session.send_prompt(session, "second")
    await_idle(session)
    assert_receive {:transport_request, 3, messages, _options}, @timeout
    assert Enum.any?(messages, &(&1.role == :tool and &1.tool_call_id == "prefix-call"))
    assert Enum.all?(messages, &(&1.reasoning_details == nil))

    assert Enum.filter(Session.messages(session), &match?({:user, _}, &1)) == [
             {:user, "first"},
             {:user, "second"}
           ]

    assert File.read!(target(context)) == "written\n"
  end

  test "a rejected first request can recover by selecting another model without clearing its prompt",
       context do
    attempts = :atomics.new(1, [])
    owner = self()

    client = fn model, messages, _options ->
      case :atomics.add_get(attempts, 1, 1) do
        1 ->
          {:error, :model_not_found}

        _ ->
          send(owner, {:recovered_request, model, messages})

          stream_response(model, [
            StreamChunk.text("recovered"),
            StreamChunk.meta(%{finish_reason: :stop})
          ])
      end
    end

    session = start_session(context, provider_opts: [llm_client: client])
    assert :ok = Session.send_prompt(session, "first rejected prompt")
    assert_receive {:agent_event, ^session, {:error, _message}}, @timeout
    assert_receive {:agent_event, ^session, {:resumable_boundary, _boundary}}, @timeout
    record = Session.session_id(session)
    assert :ok = Session.set_model(session, "openai:other-model")
    assert Session.editor_snapshot(session).model_selection.route.model_id == "other-model"
    assert :ok = Session.send_prompt(session, "try again")
    await_idle(session)
    assert_receive {:recovered_request, model, messages}, @timeout
    assert model.id == "other-model"

    assert Enum.filter(messages, &(&1.role == :user)) == [
             ReqLLM.Context.user("first rejected prompt"),
             ReqLLM.Context.user("try again")
           ]

    assert Session.session_id(session) == record
  end

  test "a PDF handoff rejects an image-only transport without saving and preserves bytes on a compatible route",
       context do
    credential_opts =
      Keyword.update!(
        context.credential_opts,
        :env,
        &Map.merge(&1, %{
          "OPENAI_API_KEY" => "fixture-openai-key",
          "OPENROUTER_API_KEY" => "fixture-openrouter-key"
        })
      )

    template = hd(context.resolver_opts[:models])

    router_model = %{
      template
      | id: "openrouter/router-document",
        provider: :openrouter,
        provider_model_id: "router-document",
        execution: %{
          text: %{
            supported: true,
            family: "openai_chat_compatible",
            wire_protocol: "openai_chat",
            transport: "http",
            provider_model_id: "router-document",
            base_url: "https://openrouter.ai/api/v1",
            path: "/chat/completions"
          }
        }
    }

    resolver_opts =
      context.resolver_opts
      |> Keyword.update!(:models, &(&1 ++ [router_model]))
      |> Keyword.update!(
        :providers,
        &(&1 ++ [%{id: :openrouter, runtime: %{"base_url" => "https://openrouter.ai/api/v1"}}])
      )

    context = %{context | credential_opts: credential_opts, resolver_opts: resolver_opts}

    candidates =
      MingaAgent.ModelResolver.candidates(
        Keyword.put(
          context.resolver_opts,
          :credential_snapshot,
          Credentials.snapshot(credential_opts)
        )
      )

    source =
      Enum.find(
        candidates,
        &(&1.selection.route.request_provider == :openai_codex and
            &1.selection.route.model_id == "gpt-6.1-sol")
      )

    incompatible = Enum.find(candidates, &(&1.selection.route.request_provider == :openai))

    compatible =
      Enum.find(
        candidates,
        &(&1.selection.route.request_provider == :openai_codex and
            &1.selection.route.model_id == "other-model")
      )

    router = Enum.find(candidates, &(&1.selection.route.request_provider == :openrouter))
    owner = self()
    attempts = :atomics.new(1, [])

    client = fn model, messages, options ->
      count = :atomics.add_get(attempts, 1, 1)
      send(owner, {:transport_request, count, messages, options})

      if model.provider == :openrouter do
        {:ok, request} =
          ReqLLM.Providers.OpenRouter.prepare_request(:chat, model, messages, options)

        wire =
          request
          |> ReqLLM.Providers.OpenRouter.encode_body()
          |> Req.Steps.encode_body()
          |> Map.fetch!(:body)
          |> IO.iodata_to_binary()
          |> JSON.decode!()

        send(owner, {:openrouter_request, wire})
      end

      stream_response(model, response_chunks(false, count, []))
    end

    session =
      start_session(context,
        model: MingaAgent.ModelSelection.id(source.selection),
        tool_call?: false,
        provider_opts: [llm_client: client]
      )

    assert :ok = Session.set_model(session, source.selection)
    file = ReqLLM.Message.ContentPart.file("%PDF-1.7\nfixture", "notes.pdf", "application/pdf")

    assert :ok =
             Session.send_prompt(session, [
               ReqLLM.Message.ContentPart.text("read this document"),
               file
             ])

    await_idle(session)
    assert_receive {:transport_request, 1, _messages, _options}, @timeout
    record = Session.session_id(session)
    before_selection = Session.editor_snapshot(session).model_selection
    before_messages = Session.messages(session)

    assert {:ok, before_record} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert {:error, reason} = Session.set_model(session, incompatible.selection)
    assert reason =~ "application/pdf"
    assert Session.editor_snapshot(session).model_selection == before_selection
    assert Session.messages(session) == before_messages

    assert {:ok, rejected_record} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert rejected_record.model_selection == before_record.model_selection
    assert rejected_record.continuation == before_record.continuation

    assert :ok = Session.set_model(session, compatible.selection)
    assert :ok = Session.send_prompt(session, "continue on the compatible model")
    await_idle(session)
    assert_receive {:transport_request, 2, messages, _options}, @timeout
    assert Enum.any?(messages, &(file in &1.content))

    assert {:ok, saved} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert Enum.any?(saved.continuation.messages, &(file in &1.content))

    assert :ok = Session.set_model(session, router.selection)

    for prompt <- ["continue with OpenRouter", "keep the document on the next turn"] do
      assert :ok = Session.send_prompt(session, prompt)
      await_idle(session)
      assert_receive {:openrouter_request, wire}, @timeout

      content =
        Enum.flat_map(wire["messages"], fn message ->
          Enum.filter(List.wrap(message["content"]), &is_map/1)
        end)

      expected_data = "data:application/pdf;base64," <> Base.encode64(file.data)

      assert Enum.any?(
               content,
               &match?(
                 %{
                   "type" => "file",
                   "file" => %{"filename" => "notes.pdf", "file_data" => ^expected_data}
                 },
                 &1
               )
             )
    end
  end

  test "a timed-out model preview cannot leave a late reservation blocking future selections",
       context do
    session = start_session(context, tool_call?: false)
    provider = Session.get_provider(session)
    :ok = :sys.suspend(provider)
    attempt = Task.async(fn -> Session.set_model(session, "openai:other-model", 10_000) end)

    result =
      try do
        Task.await(attempt, 10_000)
      after
        :sys.resume(provider)
      end

    assert {:error, {:provider_unavailable, _reason}} = result
    assert :ok = Session.set_model(session, "openai:other-model")
    assert Session.editor_snapshot(session).model_selection.route.model_id == "other-model"
  end

  test "a historical branch rejects a mismatched model without changing history, then resumes exactly",
       context do
    session = start_session(context, tool_call?: false, opaque?: true)
    assert :ok = Session.send_prompt(session, "first")
    await_idle(session)
    assert :ok = Session.send_prompt(session, "second")
    await_idle(session)
    assert_receive {:transport_request, 1, _messages, _options}, @timeout
    assert_receive {:transport_request, 2, _messages, _options}, @timeout

    first_answer =
      Enum.find_index(Session.messages(session), &match?({:assistant, "finished"}, &1))

    assert {:ok, _message} = Session.branch_at(session, first_answer)
    assert :ok = Session.set_model(session, "openai:other-model")
    current = Session.messages(session)
    assert {:error, message} = Session.switch_branch(session, 0)
    assert message =~ "another model"
    assert Session.messages(session) == current
    assert Session.editor_snapshot(session).model_selection.route.model_id == "other-model"
    assert :ok = Session.set_model(session, "openai:gpt-6.1-sol")
    assert :ok = Session.switch_branch(session, 0)
    assert :ok = Session.send_prompt(session, "third")
    await_idle(session)
    assert_receive {:transport_request, 3, messages, _options}, @timeout

    assert Enum.any?(messages, fn message ->
             Enum.any?(message.reasoning_details || [], &(&1.signature == "fixture-opaque-2"))
           end)
  end

  test "a fork before a same-user continuation restores its own checklist through restart",
       context do
    requests = :atomics.new(1, [])
    task = %{"id" => "verify", "description" => "Verify the build"}

    client = fn model, _messages, _options ->
      chunks =
        case :atomics.add_get(requests, 1, 1) do
          1 ->
            args = %{"expected_revision" => 0, "tasks" => [Map.put(task, "status", "done")]}
            response_chunks(true, 1, tool_calls: [{"todo_write", args, "branch-initial"}])

          3 ->
            args = %{"expected_revision" => 1, "tasks" => [Map.put(task, "status", "blocked")]}
            response_chunks(true, 3, tool_calls: [{"todo_write", args, "branch-later"}])

          count ->
            response_chunks(false, count, [])
        end

      stream_response(model, chunks)
    end

    session = start_session(context, provider_opts: [llm_client: client])
    assert :ok = Session.send_prompt(session, "Finish the task")
    await_done(session, "todo_write")

    first_answer =
      Enum.find_index(Session.messages(session), &match?({:assistant, "finished"}, &1))

    assert :ok = Session.continue(session)
    await_done(session, "todo_write")

    assert [{:user, "Finish the task"}] =
             Enum.filter(Session.messages(session), &match?({:user, _}, &1))

    assert {2, [%{id: "verify", status: :blocked}]} =
             Checklist.snapshot(Session.editor_snapshot(session).checklist)

    assert {:ok, _message} = Session.branch_at(session, first_answer)

    assert {1, [%{id: "verify", status: :done}]} =
             Checklist.snapshot(Session.editor_snapshot(session).checklist)

    record = Session.session_id(session)
    assert :ok = stop_supervised!({:session, context.suffix})

    session = start_session(context, tool_call?: false)
    assert :ok = Session.load_session(session, record)

    assert {1, [%{id: "verify", status: :done}]} =
             Checklist.snapshot(Session.editor_snapshot(session).checklist)

    assert :ok = Session.switch_branch(session, 0)

    assert {2, [%{id: "verify", status: :blocked}]} =
             Checklist.snapshot(Session.editor_snapshot(session).checklist)
  end

  test "a rejected model change during provider backoff preserves the scheduled restart",
       context do
    session =
      start_session(context,
        tool_call?: false,
        session_opts: [
          provider_restart_backoff_base_ms: 30_000,
          provider_restart_backoff_max_ms: 30_000
        ]
      )

    assert :ok = Session.send_prompt(session, "first")
    await_idle(session)
    provider = Session.get_provider(session)
    monitor = Process.monitor(provider)
    Process.exit(provider, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^provider, :killed}, @timeout
    assert_receive {:agent_event, ^session, {:error, _message}}, @timeout
    # This assertion checks the provider lifecycle's owned timer, not editor presentation state.
    {timer, token} =
      :sys.get_state(session).provider |> MingaAgent.Session.ProviderLifecycle.retry_timer()

    directory = SessionStore.sessions_dir(context.store_dir)
    backup = directory <> ".saved"
    assert :ok = File.rename(directory, backup)
    File.write!(directory, "blocked fixture directory")
    assert {:error, _reason} = Session.set_model(session, "openai:other-model")
    assert is_integer(Process.read_timer(timer))
    assert Session.editor_snapshot(session).model_selection.route.model_id == "gpt-6.1-sol"
    assert :ok = File.rm(directory)
    assert :ok = File.rename(backup, directory)
    send(session, {:start_provider, token})
    assert is_pid(Session.get_provider(session))
    assert :ok = Session.set_model(session, "openai:other-model")
    assert Session.editor_snapshot(session).model_selection.route.model_id == "other-model"
  end

  test "switching from Codex to Anthropic sends completed tools but no foreign replay state",
       context do
    install_write_tool(context)
    template = hd(context.resolver_opts[:models])

    anthropic = %{
      template
      | id: "anthropic/target-model",
        provider: :anthropic,
        provider_model_id: "target-model",
        execution: %{
          text: %{
            supported: true,
            family: "anthropic_messages",
            wire_protocol: "anthropic_messages",
            transport: "http",
            provider_model_id: "target-model",
            base_url: "https://api.anthropic.com",
            path: "/v1/messages"
          }
        }
    }

    resolver_opts =
      context.resolver_opts
      |> Keyword.update!(:models, &(&1 ++ [anthropic]))
      |> Keyword.update!(
        :providers,
        &(&1 ++ [%{id: :anthropic, runtime: %{"base_url" => "https://api.anthropic.com"}}])
      )

    credential_opts =
      Keyword.update!(
        context.credential_opts,
        :env,
        &Map.put(&1, "ANTHROPIC_API_KEY", "fixture-key")
      )

    context = %{context | resolver_opts: resolver_opts, credential_opts: credential_opts}
    owner = self()
    attempts = :atomics.new(1, [])

    client = fn model, messages, options ->
      count = :atomics.add_get(attempts, 1, 1)

      if model.provider == :anthropic do
        {:ok, request} =
          ReqLLM.Providers.Anthropic.prepare_request(:chat, model, messages, options)

        wire =
          request
          |> ReqLLM.Providers.Anthropic.encode_body()
          |> Req.Steps.encode_body()
          |> Map.fetch!(:body)
          |> IO.iodata_to_binary()
          |> JSON.decode!()

        send(owner, {:anthropic_request, wire})
      end

      stream_response(model, response_chunks(count == 1, count, opaque?: true))
    end

    session = start_session(context, provider_opts: [llm_client: client])
    assert :ok = Session.send_prompt(session, "inspect the project")
    await_done(session)
    assert :ok = Session.set_model(session, "anthropic:target-model")
    assert Session.editor_snapshot(session).model_selection.route.request_provider == :anthropic
    assert :ok = Session.send_prompt(session, "continue with Anthropic")
    await_idle(session)
    assert_receive {:anthropic_request, wire}, @timeout
    assert wire["model"] == "target-model"

    content =
      Enum.flat_map(wire["messages"], fn message ->
        Enum.filter(List.wrap(message["content"]), &is_map/1)
      end)

    assert Enum.any?(content, &(&1["type"] == "tool_use" and &1["name"] == "prefix_write"))

    assert Enum.any?(
             content,
             &(&1["type"] == "tool_result" and &1["tool_use_id"] == "prefix-call")
           )

    refute JSON.encode!(wire) =~ "fixture-opaque"
    refute Enum.any?(content, &(&1["type"] == "thinking"))
    assert File.read!(target(context)) == "written\n"
  end

  test "model switching preserves completed tools and resumes the same conversation after restart",
       context do
    write_skill(context, "selected")
    install_write_tool(context)
    session = start_session(context, opaque?: true)
    assert :ok = Session.send_prompt(session, "first turn")
    await_done(session)
    assert_receive {:transport_request, 1, _messages, _options}, @timeout
    assert_receive {:transport_request, 2, _messages, _options}, @timeout
    record = Session.session_id(session)

    assert {:ok, saved} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert :ok = Session.set_model(session, "openai:other-model")
    assert Session.editor_snapshot(session).model_selection.route.model_id == "other-model"
    assert Session.session_id(session) == record

    assert {:ok, switched} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert Enum.any?(
             switched.continuation.messages,
             &(&1.role == :tool and &1.tool_call_id == "prefix-call")
           )

    assert Enum.all?(switched.continuation.messages, &(&1.reasoning_details == nil))
    assert Enum.any?(saved.continuation.messages, &(&1.reasoning_details not in [nil, []]))

    assert :ok = stop_supervised!({:session, context.suffix})
    session = start_session(context, model: "openai:other-model", tool_call?: false)
    assert :ok = Session.load_session(session, record)
    assert :ok = Session.send_prompt(session, "continue on the selected model")
    await_idle(session)
    assert_receive {:transport_request, 1, messages, _options}, @timeout

    assert Enum.take(messages, length(switched.continuation.messages)) ==
             Enum.map(
               switched.continuation.messages,
               &MingaAgent.Providers.Native.ReqLLMAdapter.request_message/1
             )

    assert List.last(messages) == ReqLLM.Context.user("continue on the selected model")
    assert File.read!(target(context)) == "written\n"

    assert {:error, {:portable_context_transition_required, _}} =
             Session.activate_skill(session, "selected")

    assert {:ok, before_new} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert :ok = Session.new_session(session)
    refute Session.session_id(session) == record

    assert {:ok, preserved} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert preserved.continuation == before_new.continuation
    assert {:ok, _skill} = Session.activate_skill(session, "selected")
  end

  test "outgoing requests freeze schema order and selected instructions without optional default tools",
       context do
    File.write!(
      Path.join(context.project, "AGENTS.md"),
      "Selected project instructions for this fixture."
    )

    install_write_tool(context)
    session = start_session(context, wire?: true)
    assert :ok = Session.send_prompt(session, "write once")
    assert_receive {:transport_request, 1, messages, options}, @timeout
    names = Enum.map(options[:tools], & &1.name)
    assert names == Enum.sort(names)
    assert "todo_read" in names
    assert "todo_write" in names

    refute Enum.any?(
             names,
             &(&1 in [
                 "memory_write",
                 "memory_read",
                 "describe_runtime",
                 "describe_tools",
                 "cycle_model",
                 "notebook_read",
                 "notebook_write"
               ])
           )

    assert Enum.map_join(hd(messages).content, "", &(&1.text || "")) =~
             "Selected project instructions for this fixture."

    assert_receive {:transport_request, 2, next_messages, next_options}, @timeout
    assert next_options[:tools] == options[:tools]
    assert Enum.take(next_messages, length(messages)) == messages
    await_done(session)
    assert_receive {:wire_request, 1, first_wire}, @timeout
    assert_receive {:wire_request, 2, next_wire}, @timeout
    assert Enum.map(first_wire["tools"], & &1["name"]) == names
    assert next_wire["tools"] == first_wire["tools"]
    assert next_wire["instructions"] == first_wire["instructions"]
    assert first_wire["instructions"] =~ "Selected project instructions for this fixture."
    refute first_wire["instructions"] =~ "notebook_write"
    assert Enum.take(next_wire["input"], length(first_wire["input"])) == first_wire["input"]
  end

  test "the model reads the checklist after compaction and restart and rejects a stale write",
       context do
    items = [
      %{
        "id" => "build",
        "description" => "Build the editor",
        "status" => "done",
        "note" => "Build passed"
      },
      %{
        "id" => "verify",
        "description" => "Verify on hardware",
        "status" => "blocked",
        "note" => "Hardware unavailable"
      }
    ]

    session =
      start_session(context,
        tool_calls: [
          {"todo_write", %{"expected_revision" => 0, "tasks" => items}, "checklist-first"}
        ]
      )

    assert :ok = Session.send_prompt(session, "Save the task state")
    await_done(session, "todo_write")
    assert_receive {:transport_request, 2, written, _options}, @timeout

    assert %{"revision" => 1, "durable" => true, "task_count" => 2} =
             tool_json(written, "checklist-first")

    Enum.each(1..4, fn turn ->
      assert :ok = Session.send_prompt(session, "Ordinary turn #{turn}")
      await_idle(session)
    end)

    assert {:ok, "Context compacted" <> _details} = Session.compact(session)

    record = Session.session_id(session)

    assert :ok = stop_supervised!({:session, context.suffix})

    session =
      start_session(context,
        tool_calls: [
          {"todo_write", %{"expected_revision" => 0, "tasks" => []}, "checklist-stale"},
          {"todo_read", %{}, "checklist-read"}
        ]
      )

    assert :ok = Session.load_session(session, record)
    assert :ok = Session.send_prompt(session, "Continue the restored task list")
    await_done(session, "todo_read")
    assert_receive {:transport_request, 2, restored, _options}, @timeout

    assert %{"revision" => 1, "durable" => true, "tasks" => restored_tasks, "next_offset" => nil} =
             tool_json(restored, "checklist-read")

    assert Enum.map(restored_tasks, &Map.drop(&1, ["result_ref"])) == items

    assert tool_text(restored, "checklist-stale") =~ "stale_revision"

    assert {:ok, saved} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert {1, [%{id: "build", status: :done}, %{id: "verify", status: :blocked}]} =
             Checklist.snapshot(saved.checklist)
  end

  test "the provider reads every maximal checklist row without clipping JSON or losing the result token",
       context do
    id = "checklist-max-#{context.suffix}"
    {:ok, store} = ArtifactStores.ensure_record(id, context.runtime)

    {:ok, spec} =
      CaptureSpec.new(
        media_type: "text/plain",
        mode: :bytes,
        owner_pid: self(),
        delivery_key: {:delivery, "checklist-fixture", "retained-result"}
      )

    assert {:ok, capture} = ArtifactStore.begin(store, spec)
    assert {:ok, _progress} = ArtifactStore.append(store, capture, "build receipt")
    assert {:ok, %{reference: %{token: token}}} = ArtifactStore.finish(store, capture, :complete)

    tasks =
      for i <- 1..100 do
        %{
          "id" => "task-#{i}",
          "description" => String.duplicate("d", 512),
          "status" => "blocked",
          "note" => String.duplicate("n", 2048),
          "result_ref" => if(i == 100, do: token)
        }
      end

    owner = self()
    requests = :atomics.new(1, [])

    client = fn model, messages, _options ->
      count = :atomics.add_get(requests, 1, 1)
      call = checklist_page_call(count, messages, tasks, owner)

      chunks =
        if call,
          do: response_chunks(true, count, tool_calls: [call]),
          else: response_chunks(false, count, [])

      stream_response(model, chunks)
    end

    # The maximal checklist payload is ~300KB of JSON. Raise the fixture model's
    # context ceiling so the hosted admission gate does not refuse it.
    resolver_opts =
      Keyword.update!(context.resolver_opts, :models, fn [model | rest] ->
        [%{model | limits: Map.put(model.limits, "context", 1_000_000)} | rest]
      end)

    session =
      start_session(context,
        provider_opts: [llm_client: client, model_resolver_opts: resolver_opts],
        session_opts: [session_id: id]
      )

    assert :ok = Session.send_prompt(session, "Read and verify every task")
    assert_receive {:checklist_write, %{"revision" => 1, "task_count" => 100}}, @timeout
    assert checklist_pages([]) == tasks
    assert_receive {:stale_checklist_page, error}, @timeout
    assert error =~ "stale_revision"
    await_idle(session)
  end

  defp checklist_page_call(1, _messages, tasks, _owner),
    do: {"todo_write", %{"expected_revision" => 0, "tasks" => tasks}, "write-max"}

  defp checklist_page_call(2, messages, _tasks, owner) do
    send(owner, {:checklist_write, tool_json(messages, "write-max")})
    {"todo_read", %{}, "page-2"}
  end

  defp checklist_page_call(count, messages, _tasks, owner) do
    case List.last(messages).tool_call_id do
      "stale-page" ->
        send(owner, {:stale_checklist_page, tool_text(messages, "stale-page")})
        nil

      "page-" <> _ = id ->
        %{"revision" => 1, "tasks" => rows, "next_offset" => next} = tool_json(messages, id)
        send(owner, {:checklist_page, rows, next})

        if is_integer(next),
          do: {"todo_read", %{"offset" => next, "expected_revision" => 1}, "page-#{count}"},
          else: {"todo_read", %{"offset" => 1, "expected_revision" => 0}, "stale-page"}
    end
  end

  defp checklist_pages(reversed) do
    assert_receive {:checklist_page, rows, next}, @timeout
    pages = [rows | reversed]
    if is_nil(next), do: pages |> Enum.reverse() |> Enum.concat(), else: checklist_pages(pages)
  end

  test "failed checklist publication never replaces in-memory or durable state", context do
    args = %{
      "expected_revision" => 0,
      "tasks" => [%{"id" => "verify", "description" => "Run checks", "status" => "in_progress"}]
    }

    session =
      start_session(context,
        tool_calls: [{"todo_write", args, "checklist-denied-write"}]
      )

    backup = Path.join(context.dir, "records-before-checklist-write")

    restore_store = fn ->
      if File.dir?(backup) do
        File.rm!(context.store_dir)
        File.rename!(backup, context.store_dir)
      end
    end

    on_exit(restore_store)

    debug = fn
      :ready,
      {:in, {:"$gen_call", _worker, {:checklist_invocation, %{name: "todo_write"}}}},
      _metadata ->
        File.rename!(context.store_dir, backup)
        File.write!(context.store_dir, "snapshot storage unavailable")
        :denied

      phase, _event, _metadata ->
        phase
    end

    assert :ok = :sys.install(session, {debug, :ready})
    assert :ok = Session.send_prompt(session, "Save a task while storage is unavailable")

    assert_receive {:agent_event, ^session,
                    {:error, "Tool state could not be saved." <> _recovery}},
                   @timeout

    restore_store.()

    assert Checklist.snapshot(Session.editor_snapshot(session).checklist) == {0, []}
    refute_received {:agent_event, ^session, {:todo_plan_updated, [_ | _]}}
    refute_received {:transport_request, 2, _messages, _options}

    record = Session.session_id(session)

    assert {:ok, saved} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert Checklist.snapshot(saved.checklist) == {0, []}
  end

  defp tool_json(messages, id), do: messages |> tool_text(id) |> JSON.decode!()

  defp tool_text(messages, id) do
    message = Enum.find(messages, &(&1.role == :tool and &1.tool_call_id == id))
    Enum.map_join(message.content, "", & &1.text)
  end

  test "attached send rejects stale revisions and preserves each distinct snapshot kind",
       context do
    session = start_session(context, tool_call?: false)
    id = Session.session_id(session)
    opts = [artifact_runtime: context.runtime]

    draft = %DraftSnapshot{
      text: "Explain this",
      cursor: {0, 12},
      paste_blocks: [],
      attachments: []
    }

    text = "αβ\ntrailing spaces  \n"
    selection = {:selection, "example.ex", "example.ex", text}

    assert {:ok, 1, attachment} =
             SessionStore.attach_text(id, 0, draft, selection, context.store_dir, opts)

    {token, _digest} = identity = DraftAttachment.identity(attachment)
    unsaved_text = "Unsaved edit\n" <> text
    buffer = {:buffer, "example.ex", "example.ex", unsaved_text}

    assert {:ok, 2, whole_buffer} =
             SessionStore.attach_text(
               id,
               1,
               %{draft | attachments: [attachment]},
               buffer,
               context.store_dir,
               opts
             )

    buffer_identity = DraftAttachment.identity(whole_buffer)
    saved_text = "Saved on disk\n" <> text
    file = {:file, "/project/example.ex", "example.ex", saved_text}

    assert {:ok, 3, saved_file} =
             SessionStore.attach_text(
               id,
               2,
               %{draft | attachments: [whole_buffer, attachment]},
               file,
               context.store_dir,
               opts
             )

    file_identity = DraftAttachment.identity(saved_file)
    diagnostic_text = "warning line 2, column 1 (utf8) [fixture linter]: Check this expression\n"
    diagnostics = {:diagnostics, "/project/example.ex", "example.ex", diagnostic_text}

    assert {:ok, 4, retained_diagnostics} =
             SessionStore.attach_text(
               id,
               3,
               %{draft | attachments: [saved_file, whole_buffer, attachment]},
               diagnostics,
               context.store_dir,
               opts
             )

    diagnostic_identity = DraftAttachment.identity(retained_diagnostics)
    messages_before = Session.messages(session)

    assert {:error, :draft_attachments_changed} =
             Session.send_attached_prompt(
               session,
               id,
               [diagnostic_identity, file_identity, buffer_identity, {token, "wrong revision"}],
               draft.text
             )

    refute_received {:transport_request, _, _, _}
    assert Session.messages(session) == messages_before

    assert {:ok, 5} =
             Session.send_attached_prompt(
               session,
               id,
               [diagnostic_identity, file_identity, buffer_identity, identity],
               draft.text
             )

    assert_receive {:transport_request, 1, messages, _options}, @timeout

    assert [
             %{type: :text, text: "Explain this"},
             %{type: :text, text: diagnostic_snapshot},
             %{type: :text, text: file_snapshot},
             %{type: :text, text: buffer_snapshot},
             %{type: :text, text: selection_snapshot}
           ] =
             List.last(messages).content

    assert diagnostic_snapshot == "\n\nDiagnostics snapshot: example.ex\n" <> diagnostic_text
    assert file_snapshot == "\n\nFile snapshot: example.ex\n" <> saved_text
    assert buffer_snapshot == "\n\nBuffer snapshot: example.ex\n" <> unsaved_text
    assert selection_snapshot == "\n\nSelection snapshot: example.ex\n" <> text
    await_idle(session)
    assert {:ok, _conversation} = SessionStore.load(id, context.store_dir, opts)
    assert {:ok, 5, nil} = SessionStore.read_presentation(id, context.store_dir, opts)
  end

  test "equal source reloads and OAuth provider restart preserve opaque history and selected skills",
       context do
    write_skill(context, "selected")
    session = start_session(context, tool_call?: false, opaque?: true, wire?: true)
    assert {:ok, _skill} = Session.activate_skill(session, "selected")
    assert :ok = Session.send_prompt(session, "first")
    await_idle(session)
    record = Session.session_id(session)

    assert {:ok, original} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assistant = List.last(original.continuation.messages)

    assert [
             %ReqLLM.Message.ReasoningDetails{
               provider: :openai_codex,
               signature: "fixture-opaque-1",
               encrypted?: true
             }
           ] = assistant.reasoning_details

    assert_receive {:wire_request, 1, first_wire}, @timeout

    for _reload <- 1..3, spec <- ToolRegistry.all(context.registry) do
      assert :ok = ToolRegistry.register(context.registry, spec)
    end

    assert :ok = Session.send_prompt(session, "after identical reloads")
    await_idle(session)
    assert_receive {:wire_request, 2, reloaded_wire}, @timeout
    assert reloaded_wire["instructions"] == first_wire["instructions"]
    assert reloaded_wire["tools"] == first_wire["tools"]

    assert {:ok, reloaded} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert reloaded.continuation.prefixes == original.continuation.prefixes
    assert :ok = stop_supervised({:session, context.suffix})
    restored = start_session(context, tool_call?: false, wire?: true)
    assert :ok = Session.load_session(restored, record)
    assert {:ok, _available, ["selected"]} = Session.list_skills(restored)
    assert :ok = Session.send_prompt(restored, "after restart")
    await_idle(restored)
    assert_receive {:wire_request, 1, restarted_wire}, @timeout
    assert restarted_wire["instructions"] == first_wire["instructions"]
    assert Enum.any?(restarted_wire["input"], &(&1["encrypted_content"] == "fixture-opaque-1"))

    assert {:ok, saved} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert Enum.take(saved.continuation.messages, length(reloaded.continuation.messages)) ==
             reloaded.continuation.messages

    assert saved.continuation.prefixes == original.continuation.prefixes

    assert {:error, {:portable_context_transition_required, _}} =
             Session.deactivate_skill(restored, "selected")

    assert {:ok, _available, ["selected"]} = Session.list_skills(restored)
  end

  test "successful activation and deactivation before history publish only the effective prefix",
       context do
    write_skill(context, "selected")
    session = start_session(context, tool_call?: false, wire?: true)
    assert {:ok, _skill} = Session.activate_skill(session, "selected")
    assert {:ok, _available, ["selected"]} = Session.list_skills(session)
    assert :ok = Session.deactivate_skill(session, "selected")
    assert {:ok, _available, []} = Session.list_skills(session)
    assert :ok = Session.send_prompt(session, "first")
    await_idle(session)
    assert_receive {:wire_request, 1, wire}, @timeout
    refute wire["instructions"] =~ "Apply the selected fixture instructions."

    assert {:ok, saved} =
             SessionStore.load(Session.session_id(session), context.store_dir,
               artifact_runtime: context.runtime
             )

    assert map_size(saved.continuation.prefixes.epochs) == 1
  end

  test "changed skill files are considered at the next boundary without changing last-good selection",
       context do
    write_skill(context, "selected")
    session = start_session(context, tool_call?: false)
    assert {:ok, _skill} = Session.activate_skill(session, "selected")
    assert :ok = Session.send_prompt(session, "first")
    await_idle(session)
    skill_path = Path.join([context.project, ".minga", "skills", "selected", "SKILL.md"])

    File.write!(
      skill_path,
      "---\nname: selected\ndescription: Changed\n---\nChanged fixture instructions.\n"
    )

    assert {:error, {:portable_context_transition_required, _}} =
             Session.send_prompt(session, "next")

    assert {:ok, _available, ["selected"]} = Session.list_skills(session)
    refute_receive {:transport_request, 2, _messages, _options}, 0
  end

  test "advice cannot disguise failed durable admission as an ordinary completed result",
       context do
    install_write_tool(context)
    before_start_barrier()
    replace_advice_result()
    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write")
    assert_receive {:before_start, worker}, @timeout
    directory = SessionStore.sessions_dir(context.store_dir)
    backup = directory <> ".saved"
    assert :ok = File.rename(directory, backup)
    File.write!(directory, "blocked fixture directory")
    send(worker, :continue_start)
    assert_receive {:inner_result, {:returned, _state, {:storage_error, _reason}}}, @timeout
    assert_receive {:agent_event, ^session, {:error, _message}}, @timeout
    assert :ok = File.rm(directory)
    assert :ok = File.rename(backup, directory)
    refute_received :callback_built
    refute File.exists?(target(context))
    assert is_binary(Session.editor_snapshot(session).error)

    assert {:ok, saved} =
             SessionStore.load(Session.session_id(session), context.store_dir,
               artifact_runtime: context.runtime
             )

    refute is_nil(saved.continuation.tool_checkpoint)
    assert saved_tool_result(context, session) == nil

    assert {:error, :effect_reconciliation_required} =
             Session.send_prompt(session, "do not advance")

    assert Session.editor_snapshot(session).error =~ "Reload"
    refute_receive {:transport_request, 2, _messages, _options}, 0
  end

  test "capture owner loss remains a storage failure even when advice replaces its result",
       context do
    owner = self()

    install_write_tool(context, "admitted\n", fn ->
      send(owner, {:callback_started, self()})
      receive do: (:settle -> :ok)
    end)

    replace_advice_result()
    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write")
    assert_receive {:callback_started, worker}, @timeout
    assert {:ok, store} = Session.artifact_store(session)
    assert :ok = GenServer.stop(store, :normal)
    send(worker, :settle)
    assert_receive {:inner_result, {:returned, _state, {:storage_error, _reason}}}, @timeout
    assert_receive {:agent_event, ^session, {:error, _message}}, @timeout
    assert File.read!(target(context)) == "admitted\n"
    assert is_binary(Session.editor_snapshot(session).error)
    assert saved_tool_result(context, session) == nil

    assert {:error, :effect_reconciliation_required} =
             Session.send_prompt(session, "do not advance")

    assert Session.editor_snapshot(session).error =~ "Reload"
    refute_receive {:transport_request, 2, _messages, _options}, 0
  end

  test "per-tool allow overrides extension denial and global all without recycling approval",
       context do
    install_write_tool(context)
    {:ok, spec} = ToolRegistry.lookup(context.registry, "prefix_write")

    assert :ok =
             ToolRegistry.register(
               context.registry,
               Spec.new!(Map.put(Map.from_struct(spec), :approval_level, :deny))
             )

    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :all)

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{
               "prefix_write" => :allow
             })

    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write")
    await_done(session)
    assert File.read!(target(context)) == "written\n"
    refute_received {:agent_event, ^session, {:approval_pending, _approval}}
    assert saved_tool_result(context, session).metadata.is_error == false
  end

  test "extension ask is honored in destructive mode even with an empty destructive name list",
       context do
    install_write_tool(context)
    {:ok, spec} = ToolRegistry.lookup(context.registry, "prefix_write")

    assert :ok =
             ToolRegistry.register(
               context.registry,
               Spec.new!(Map.put(Map.from_struct(spec), :approval_level, :ask))
             )

    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :destructive)
    assert {:ok, _} = Options.set(context.options_name, :agent_destructive_tools, [])
    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write")

    assert_receive {:agent_event, ^session,
                    {:approval_pending, %Public{target: %Target{} = approval_target}}},
                   @timeout

    refute File.exists?(target(context))
    assert :ok = Session.respond_to_approval(session, approval_target, :approve)
    await_done(session)
    assert File.read!(target(context)) == "written\n"
  end

  test "configured destructive names require approval even for a normally read-only builtin",
       context do
    File.write!(target(context), "sensitive fixture")
    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :destructive)
    assert {:ok, _} = Options.set(context.options_name, :agent_destructive_tools, ["read_file"])

    session =
      start_session(context,
        tool_calls: [{"read_file", %{"path" => "effect.txt"}, "prefix-call"}]
      )

    assert :ok = Session.send_prompt(session, "read")

    assert_receive {:agent_event, ^session,
                    {:approval_pending, %Public{target: %Target{} = approval_target}}},
                   @timeout

    assert :ok = Session.respond_to_approval(session, approval_target, :reject)
    await_done(session, "read_file")
    result = saved_tool_result(context, session)
    assert result.metadata.is_error == true
    refute Enum.map_join(result.content, "", & &1.text) =~ "sensitive fixture"
    assert File.read!(target(context)) == "sensitive fixture"
  end

  test "approved shell execution uses the working directory when no project is active", context do
    # A nil override discovers the active Project before falling back to cwd.
    # Close that owner explicitly instead of inheriting another scenario's workspace.
    assert :ok = Minga.Project.close()
    assert Minga.Project.root() == nil
    working_directory = Path.join(context.dir, "no-project-cwd")
    File.mkdir_p!(working_directory)
    expected = "approval working-directory fixture"
    File.write!(Path.join(working_directory, "cwd-proof.txt"), expected)

    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :destructive)
    assert {:ok, _} = Options.set(context.options_name, :agent_destructive_tools, ["shell"])

    File.cd!(working_directory, fn ->
      session =
        start_session(context,
          tool_calls: [{"shell", %{"command" => "cat cwd-proof.txt"}, "prefix-call"}],
          provider_opts: [project_root: nil]
        )

      assert :ok = Session.send_prompt(session, "read the working directory's proof file")

      assert_receive {:agent_event, ^session,
                      {:approval_pending, %Public{target: %Target{} = approval_target}}},
                     @timeout

      assert :ok = Session.respond_to_approval(session, approval_target, :approve)
      await_done(session, "shell")
      result = saved_tool_result(context, session)
      assert result.metadata.is_error == false
      assert Enum.map_join(result.content, "", & &1.text) == expected
    end)
  end

  test "builtin and bundled metadata do not add approval beyond the current global policy",
       context do
    File.write!(target(context), "read fixture")
    {:ok, reader} = ToolRegistry.lookup(context.registry, "read_file")

    directory =
      Enum.find(
        MingaAgent.Tools.specs_for_source({:bundle, :read_only_tools}),
        &(&1.name == "list_directory")
      )

    for spec <- [reader, directory] do
      assert :ok =
               ToolRegistry.register(
                 context.registry,
                 Spec.new!(Map.put(Map.from_struct(spec), :approval_level, :ask))
               )
    end

    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :destructive)
    assert {:ok, _} = Options.set(context.options_name, :agent_destructive_tools, [])

    session =
      start_session(context,
        tool_calls: [
          {"read_file", %{"path" => "effect.txt"}, "prefix-call"},
          {"list_directory", %{"path" => "."}, "directory-call"}
        ]
      )

    assert :ok = Session.send_prompt(session, "read")
    await_done(session, "read_file")
    assert saved_tool_result(context, session).metadata.is_error == false
    assert File.read!(target(context)) == "read fixture"
    refute_received {:agent_event, ^session, {:approval_pending, _approval}}
  end

  test "global all keeps each ask subject separate within one tool group", context do
    install_write_tool(context)
    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :all)

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{"prefix_write" => :ask})

    session =
      start_session(context,
        tool_calls: [
          {"prefix_write", %{"path" => "effect.txt"}, "first-call"},
          {"prefix_write", %{"path" => "effect.txt"}, "prefix-call"}
        ]
      )

    assert :ok = Session.send_prompt(session, "write twice")

    assert_receive {:agent_event, ^session,
                    {:approval_pending,
                     %Public{target: %Target{tool_call_id: "first-call"} = first_target}}},
                   @timeout

    assert :ok = Session.respond_to_approval(session, first_target, :approve)

    assert_receive {:agent_event, ^session,
                    {:approval_pending,
                     %Public{target: %Target{tool_call_id: "prefix-call"} = second_target}}},
                   @timeout

    assert second_target.session_id == first_target.session_id
    assert second_target.request_id == first_target.request_id

    assert {:error, :approval_not_found} =
             Session.respond_to_approval(session, first_target, :approve_session)

    assert Session.list_tool_trust(session) == %{}
    assert :ok = Session.respond_to_approval(session, second_target, :approve)
    await_done(session)
    assert File.read!(target(context)) == "written\nwritten\n"
  end

  test "a later provider group cannot recreate an approved target with different arguments",
       context do
    owner = self()
    calls = :atomics.new(1, [])
    install_write_tool(context)

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{"prefix_write" => :ask})

    client = fn model, messages, _options ->
      count = :atomics.add_get(calls, 1, 1)
      send(owner, {:reuse_group_request, count, messages})

      chunks =
        case count do
          1 ->
            [
              StreamChunk.tool_call("prefix_write", %{"path" => "effect.txt"}, %{
                id: "prefix-call"
              }),
              StreamChunk.meta(%{finish_reason: :tool_use})
            ]

          2 ->
            [
              StreamChunk.tool_call("prefix_write", %{"path" => "different.txt"}, %{
                id: "prefix-call"
              }),
              StreamChunk.meta(%{finish_reason: :tool_use})
            ]

          _ ->
            [StreamChunk.text("finished"), StreamChunk.meta(%{finish_reason: :stop})]
        end

      stream_response(model, chunks)
    end

    session = start_session(context, provider_opts: [llm_client: client])
    assert :ok = Session.send_prompt(session, "write the first file")

    assert_receive {:agent_event, ^session,
                    {:tool_started, _call_id, "prefix_write", %{"path" => "effect.txt"}}},
                   @timeout

    assert_receive {:agent_event, ^session,
                    {:approval_pending,
                     %Public{
                       target: %Target{tool_call_id: "prefix-call"} = approval_target,
                       args: %{"path" => "effect.txt"}
                     }}},
                   @timeout

    assert :ok = Session.respond_to_approval(session, approval_target, :approve)

    assert_receive {:agent_event, ^session, {:approval_resolved, ^approval_target, :approve}},
                   @timeout

    assert_receive :callback_built, @timeout

    assert_receive {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{name: "prefix_write"}}},
                   @timeout

    assert File.read!(target(context)) == "written\n"
    assert_receive {:reuse_group_request, 2, second_group_messages}, @timeout

    assert Enum.any?(second_group_messages, fn
             %{role: :tool, tool_call_id: "prefix-call", metadata: %{is_error: false}} -> true
             _ -> false
           end)

    assert_receive {:agent_event, ^session, {:error, message}}, @timeout
    assert Session.editor_snapshot(session).error == message
    assert Session.editor_snapshot(session).status == :error
    assert Session.editor_snapshot(session).pending_approval == nil

    assert Session.list_tool_trust(session) == %{}
    assert :atomics.get(calls, 1) == 2
    assert File.read!(target(context)) == "written\n"
    refute File.exists?(Path.join(context.project, "different.txt"))
    refute_received :callback_built
    refute_received {:agent_event, ^session, {:approval_pending, _}}
    refute_received {:agent_event, ^session, {:approval_resolved, _, _}}
    refute_received {:agent_event, ^session, {:tool_started, _call_id, "prefix_write", _}}
    refute_received {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{name: "prefix_write"}}}

    session_id = Session.session_id(session)
    assert :ok = Session.load_session(session, session_id)
    assert Session.editor_snapshot(session).status == :idle
    assert Session.editor_snapshot(session).pending_approval == nil

    assert {:error, :stale_request} =
             Session.respond_to_approval(session, approval_target, :approve_session)

    assert Session.list_tool_trust(session) == %{}
    assert File.read!(target(context)) == "written\n"
    assert :atomics.get(calls, 1) == 2

    assert {:ok, saved} =
             SessionStore.load(Session.session_id(session), context.store_dir,
               artifact_runtime: context.runtime
             )

    assert [%{tool_call_id: "prefix-call", metadata: %{is_error: false}} = result] =
             Enum.filter(saved.continuation.messages, &(&1.role == :tool))

    assert Enum.map_join(result.content, "", & &1.text) =~ "written"
  end

  test "an allowed write after a pending approval waits for the approved call to finish",
       context do
    owner = self()
    install_write_tool(context)

    install_write_tool(
      context,
      "allowed\n",
      fn ->
        send(owner, {:allowed_started, self()})
        receive do: (:settle -> :ok)
      end,
      "allowed_write"
    )

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{
               "prefix_write" => :ask,
               "allowed_write" => :allow
             })

    session =
      start_session(context,
        tool_calls: [
          {"prefix_write", %{"path" => "effect.txt"}, "prefix-call"},
          {"allowed_write", %{"path" => "allowed.txt"}, "allowed-call"}
        ]
      )

    assert :ok = Session.send_prompt(session, "write")

    assert_receive {:agent_event, ^session,
                    {:approval_pending, %Public{target: %Target{} = approval_target}}},
                   @timeout

    # Model order: the later mutating call is not admitted while the earlier call awaits approval.
    refute_receive {:allowed_started, _worker}, 150
    assert :ok = Session.respond_to_approval(session, approval_target, :approve)

    assert_receive {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{name: "prefix_write"}}},
                   @timeout

    assert File.read!(target(context)) == "written\n"
    assert_receive {:allowed_started, worker}, @timeout
    refute File.exists?(Path.join(context.project, "allowed.txt"))
    send(worker, :settle)
    await_done(session, "allowed_write")
    assert File.read!(Path.join(context.project, "allowed.txt")) == "allowed\n"
  end

  test "an expired approval cannot retain its slot or grant trust before a later allowed write",
       context do
    owner = self()
    install_write_tool(context)

    install_write_tool(
      context,
      "allowed\n",
      fn ->
        send(owner, {:allowed_started, self()})
        receive do: (:settle -> :ok)
      end,
      "allowed_write"
    )

    permissions = %{"prefix_write" => :ask, "allowed_write" => :allow}
    assert {:ok, _} = Options.set(context.options_name, :agent_tool_permissions, permissions)

    config = %MingaAgent.Config{
      compaction_threshold: nil,
      tool_approval: Options.get(context.options_name, :agent_tool_approval),
      tool_permissions: permissions,
      destructive_tools: Options.get(context.options_name, :agent_destructive_tools),
      approval_timeout_ms: 0
    }

    session =
      start_session(context,
        provider_opts: [config: config],
        tool_calls: [
          {"prefix_write", %{"path" => "effect.txt"}, "prefix-call"},
          {"allowed_write", %{"path" => "allowed.txt"}, "allowed-call"}
        ]
      )

    assert :ok = Session.send_prompt(session, "write")
    assert_receive {:allowed_started, worker}, @timeout

    assert_receive {:agent_event, ^session,
                    {:tool_ended,
                     %Event.ToolEnd{
                       name: "prefix_write",
                       result: result,
                       outcome: :error,
                       reason: :approval_timeout
                     }}},
                   @timeout

    assert result =~ "approval timed out"

    assert {:ok, saved} =
             SessionStore.load(Session.session_id(session), context.store_dir,
               artifact_runtime: context.runtime
             )

    target =
      Target.new(
        Session.session_id(session),
        saved.continuation.tool_checkpoint.request_id,
        "prefix-call"
      )

    assert Session.editor_snapshot(session).pending_approval == nil

    assert {:tool_call, %{status: :error, terminal_reason: :approval_timeout, duration_ms: nil}} =
             Enum.find(Session.messages(session), &match?({:tool_call, _}, &1))

    assert {:error, :approval_not_found} =
             Session.respond_to_approval(session, target, :approve_session)

    assert Session.list_tool_trust(session) == %{}

    refute File.exists?(target(context))
    refute File.exists?(Path.join(context.project, "allowed.txt"))
    send(worker, :settle)
    await_done(session, "allowed_write")
    assert File.read!(Path.join(context.project, "allowed.txt")) == "allowed\n"
    assert saved_tool_result(context, session).metadata.is_error
  end

  test "Native retries saving expiry without reopening its effect or granting trust",
       context do
    owner = self()
    install_write_tool(context)
    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :all)
    requests = :atomics.new(1, [])

    client = fn model, _messages, _options ->
      case :atomics.add_get(requests, 1, 1) do
        1 ->
          stream_response(model, response_chunks(true, 1, []))

        2 ->
          send(owner, {:after_timeout, self()})
          receive do: (:finish -> :ok)
          stream_response(model, response_chunks(false, 2, []))
      end
    end

    config = %MingaAgent.Config{
      compaction_threshold: nil,
      tool_approval: Options.get(context.options_name, :agent_tool_approval),
      tool_permissions: Options.get(context.options_name, :agent_tool_permissions),
      destructive_tools: Options.get(context.options_name, :agent_destructive_tools),
      approval_timeout_ms: 0
    }

    session = start_session(context, provider_opts: [config: config, llm_client: client])
    backup = Path.join(context.dir, "records-before-outcome")

    on_exit(fn ->
      if File.regular?(context.store_dir) and File.dir?(backup) do
        File.rm!(context.store_dir)
        File.rename!(backup, context.store_dir)
      end
    end)

    debug = fn
      count,
      {:in,
       {:"$gen_call", _from,
        {:complete_tool_effect, request_id, checkpoint_id, call_id, result, _change}}},
      _extra ->
        next = count + 1

        case next do
          1 ->
            File.rename!(context.store_dir, backup)
            File.write!(context.store_dir, "temporarily unavailable snapshot directory")

          2 ->
            File.rm!(context.store_dir)
            File.rename!(backup, context.store_dir)

          _later ->
            :ok
        end

        send(owner, {:completion_attempt, next, request_id, checkpoint_id, call_id, result})
        next

      count, _event, _extra ->
        count
    end

    assert :ok = :sys.install(session, {debug, 0})
    assert :ok = Session.send_prompt(session, "write")

    assert_receive {:completion_attempt, 1, request_id, checkpoint_id, "prefix-call", result},
                   @timeout

    assert_receive {:completion_attempt, 2, ^request_id, ^checkpoint_id, "prefix-call", ^result},
                   @timeout

    assert_receive {:after_timeout, continuation_worker}, @timeout
    target = Target.new(Session.session_id(session), request_id, "prefix-call")
    assert Session.editor_snapshot(session).pending_approval == nil
    assert result.metadata.tool_outcome == :error
    assert result.metadata.tool_outcome_reason == :approval_timeout

    output = result.metadata.output

    assert_receive {:agent_event, ^session,
                    {:tool_ended,
                     %Event.ToolEnd{
                       tool_call_id: "prefix-call",
                       name: "prefix_write",
                       outcome: :error,
                       reason: :approval_timeout,
                       output: ^output,
                       is_error: true
                     }}},
                   @timeout

    refute_received {:agent_event, ^session, {:approval_resolved, ^target, :reject}}

    assert {:error, :approval_not_found} =
             Session.respond_to_approval(session, target, :approve_session)

    assert Session.list_tool_trust(session) == %{}
    refute File.exists?(target(context))
    refute_received :callback_built
    send(continuation_worker, :finish)
    await_idle(session)
    assert saved_tool_result(context, session).metadata.is_error
    assert saved_tool_result(context, session).metadata.tool_outcome == :error
    assert saved_tool_result(context, session).metadata.tool_outcome_reason == :approval_timeout
  end

  test "Stop before approval saves the same cancellation outcome without admitting an effect",
       context do
    install_write_tool(context)
    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :all)
    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write")

    assert_receive {:agent_event, ^session, {:approval_pending, %Public{target: target}}},
                   @timeout

    assert :ok = Session.abort(session)
    assert_receive {:agent_event, ^session, {:approval_resolved, ^target, :interrupted}}, @timeout
    assert Session.editor_snapshot(session).pending_approval == nil
    assert {:error, _stale} = Session.respond_to_approval(session, target, :approve)

    assert {:tool_call, %{status: :cancelled, terminal_reason: nil, duration_ms: nil}} =
             Enum.find(Session.messages(session), &match?({:tool_call, _}, &1))

    result = saved_tool_result(context, session)
    assert result.metadata.tool_outcome == :cancelled
    assert result.metadata.is_error
    assert result.metadata.minga_effect_status == :not_executed
    assert Map.get(result.metadata, :tool_outcome_reason) == nil
    refute File.exists?(target(context))
    refute_received :callback_built
    refute_received {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{}}}
    assert :ok = Session.abort(session)
    refute_received {:agent_event, ^session, {:approval_resolved, ^target, _resolution}}
  end

  test "Stop gives every admitted call exactly one terminal result and admits nothing after it",
       context do
    owner = self()
    install_write_tool(context)

    install_write_tool(
      context,
      "blocked\n",
      fn ->
        send(owner, {:blocked_started, self()})
        receive do: (:never -> :ok)
      end,
      "blocked_write"
    )

    install_write_tool(context, "later\n", fn -> :ok end, "later_write")

    session =
      start_session(context,
        tool_calls: [
          {"prefix_write", %{"path" => "effect.txt"}, "prefix-call"},
          {"blocked_write", %{"path" => "blocked.txt"}, "blocked-call"},
          {"later_write", %{"path" => "later.txt"}, "later-call"}
        ]
      )

    assert :ok = Session.send_prompt(session, "write three files")

    assert_receive {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{name: "prefix_write"}}},
                   @timeout

    assert_receive {:blocked_started, worker}, @timeout
    worker_ref = Process.monitor(worker)

    assert :ok = Session.abort(session)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, @timeout

    assert {:ok, saved} =
             SessionStore.load(Session.session_id(session), context.store_dir,
               artifact_runtime: context.runtime
             )

    results = Enum.filter(saved.continuation.messages, &(&1.role == :tool))
    assert Enum.map(results, & &1.tool_call_id) == ["prefix-call", "blocked-call", "later-call"]

    assert Enum.map(results, &Map.get(&1.metadata, :minga_effect_status)) ==
             [nil, :indeterminate, :not_executed]

    assert Enum.map(results, & &1.metadata.is_error) == [false, true, true]

    refute_receive {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{name: "blocked_write"}}},
                   100

    refute_received {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{name: "later_write"}}}

    assert File.read!(target(context)) == "written\n"
    refute File.exists?(Path.join(context.project, "blocked.txt"))
    refute File.exists?(Path.join(context.project, "later.txt"))
  end

  test "an unanswered approval ends as an approval timeout, not a tool timeout", context do
    install_write_tool(context)
    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :all)

    session =
      start_session(context,
        provider_opts: [
          config: approval_config(context, approval_timeout_ms: 300, tool_call_timeout_ms: 50)
        ]
      )

    assert :ok = Session.send_prompt(session, "write")
    assert_receive {:agent_event, ^session, {:approval_pending, %Public{}}}, @timeout

    assert_receive {:agent_event, ^session,
                    {:tool_ended,
                     %Event.ToolEnd{
                       name: "prefix_write",
                       outcome: :error,
                       reason: :approval_timeout
                     }}},
                   @timeout

    refute File.exists?(target(context))
  end

  test "an approval answered after the tool timeout still runs the call", context do
    install_write_tool(context)
    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :all)

    session =
      start_session(context,
        provider_opts: [
          config:
            approval_config(context, approval_timeout_ms: @timeout, tool_call_timeout_ms: 50)
        ]
      )

    assert :ok = Session.send_prompt(session, "write")

    assert_receive {:agent_event, ^session,
                    {:approval_pending, %Public{target: approval_target}}},
                   @timeout

    # Wait past the tool-call timeout; the approval wait is not tool execution.
    refute_receive {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{}}}, 150
    assert :ok = Session.respond_to_approval(session, approval_target, :approve)
    await_done(session)
    assert File.read!(target(context)) == "written\n"
    assert saved_tool_result(context, session).metadata.is_error == false
  end

  test "a read the provider config would run at once still waits for live Session approval",
       context do
    owner = self()

    spec =
      Spec.new!(
        source: @source,
        name: "gated_read",
        description: "Read one fixture value",
        parameter_schema: %{"type" => "object", "properties" => %{}},
        category: :filesystem,
        effect: :read_only,
        capabilities: [:read_project],
        build: fn _tool_context ->
          fn _args ->
            send(owner, :gated_read_ran)
            {:ok, "read"}
          end
        end
      )

    assert :ok = ToolRegistry.register(context.registry, spec)
    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :all)

    # The provider schedules the read as a concurrent batch; the Session's live policy still gates it.
    session =
      start_session(context,
        tool_calls: [{"gated_read", %{}, "read-call"}],
        provider_opts: [config: approval_config(context, tool_approval: :none)]
      )

    assert :ok = Session.send_prompt(session, "read")

    assert_receive {:agent_event, ^session,
                    {:approval_pending, %Public{target: approval_target}}},
                   @timeout

    refute_received :gated_read_ran
    assert :ok = Session.respond_to_approval(session, approval_target, :approve)
    await_done(session, "gated_read")
    assert_received :gated_read_ran
    assert saved_tool_result(context, session, "read-call").metadata.is_error == false
  end

  test "a rejected approval settles before a later allowed write runs",
       context do
    install_write_tool(context)
    install_write_tool(context, "allowed\n", fn -> :ok end, "allowed_write")
    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :all)

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{
               "prefix_write" => :ask,
               "allowed_write" => :allow
             })

    session =
      start_session(context,
        tool_calls: [
          {"prefix_write", %{"path" => "effect.txt"}, "prefix-call"},
          {"allowed_write", %{"path" => "allowed.txt"}, "allowed-call"}
        ]
      )

    assert :ok = Session.send_prompt(session, "write")

    assert_receive {:agent_event, ^session,
                    {:approval_pending, %Public{target: %Target{} = approval_target}}},
                   @timeout

    # Model order: the later write has neither run nor ended while approval is pending.
    refute_receive {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{name: "allowed_write"}}},
                   150

    refute File.exists?(Path.join(context.project, "allowed.txt"))
    refute File.exists?(target(context))
    assert :ok = Session.respond_to_approval(session, approval_target, :reject)
    await_done(session)
    assert File.read!(Path.join(context.project, "allowed.txt")) == "allowed\n"
    assert saved_tool_result(context, session).metadata.is_error == true

    assert {:ok, saved} =
             SessionStore.load(Session.session_id(session), context.store_dir,
               artifact_runtime: context.runtime
             )

    results = Enum.filter(saved.continuation.messages, &(&1.role == :tool))
    assert Enum.map(results, & &1.tool_call_id) == ["prefix-call", "allowed-call"]
    assert Enum.map(results, & &1.metadata.is_error) == [true, false]
    refute File.exists?(target(context))
  end

  test "session-local SDK validation supplies normalized defaults to the actual callback",
       context do
    owner = self()

    tool =
      ReqLLM.Tool.new!(
        name: "prefix_write",
        description: "Write a validated fixture",
        parameter_schema: [
          path: [type: :string, required: true],
          label: [type: :string, default: "normalized"]
        ],
        callback: fn args ->
          send(owner, {:normalized_arguments, args})

          File.write!(
            Path.join(context.project, Map.fetch!(args, :path)),
            Map.fetch!(args, :label)
          )

          {:ok, "written"}
        end
      )

    session = start_session(context, provider_opts: [tools: [tool]])
    assert :ok = Session.send_prompt(session, "write")
    await_done(session)
    assert_receive {:normalized_arguments, %{path: "effect.txt", label: "normalized"}}, @timeout
    assert File.read!(target(context)) == "normalized"
    assert saved_tool_result(context, session).metadata.is_error == false
  end

  test "a current builtin context fails closed after its owned fork store dies",
       context do
    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :destructive)
    assert {:ok, _} = Options.set(context.options_name, :agent_destructive_tools, [])
    path = Path.join(context.project, "buffer.txt")
    File.write!(path, "original\n")
    {:ok, buffer} = start_supervised({BufferProcess, content: "original\n", file_path: path})
    client = file_writer_client("buffer.txt")
    session = start_session(context, provider_opts: [llm_client: client])
    provider = Session.get_provider(session)
    store = Native.fork_store(provider)
    assert is_pid(store)
    assert :ok = Session.send_prompt(session, "forked\n")

    assert_receive {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{name: "read_file"}}},
                   @timeout

    await_done(session, "write_file")
    assert File.read!(path) == "original\n"
    assert Minga.Buffer.content(buffer) == "original\n"
    monitor = Process.monitor(store)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^store, _reason}, @timeout
    assert Native.fork_store(provider) == nil
    assert :ok = Session.send_prompt(session, "direct\n")

    assert_receive {:agent_event, ^session,
                    {:tool_ended, %Event.ToolEnd{name: "read_file", result: failure}}},
                   @timeout

    assert failure =~ "unavailable"
    await_idle(session)
    refute_received {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{name: "write_file"}}}
    assert File.read!(path) == "original\n"
    assert Minga.Buffer.content(buffer) == "original\n"
  end

  test "current local factories receive refreshed context without exposing executable advertisements",
       context do
    owner = self()

    spec =
      Spec.new!(
        source: :config,
        name: "prefix_write",
        description: "Report bound context",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}}
        },
        build: fn tool_context ->
          send(owner, {:bound_fork_store, tool_context.router_context.fork_store})

          fn _args ->
            File.write!(target(context), "written\n", [:append])
            {:ok, "written"}
          end
        end
      )

    session = start_session(context, each_prompt?: true, provider_opts: [tools: [spec]])
    provider = Session.get_provider(session)
    store = Native.fork_store(provider)
    assert :ok = Session.send_prompt(session, "first")
    await_done(session)
    assert_receive {:bound_fork_store, ^store}, @timeout
    monitor = Process.monitor(store)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^store, _reason}, @timeout
    assert Native.fork_store(provider) == nil
    assert :ok = Session.send_prompt(session, "second")
    await_done(session)
    assert_receive {:bound_fork_store, nil}, @timeout
    assert File.read!(target(context)) == "written\nwritten\n"
  end

  test "workspace-owned drafts survive a Session and its Native provider exiting", context do
    path = Path.join(context.project, "buffer.txt")
    File.write!(path, "original\n")
    {:ok, buffer} = start_supervised({BufferProcess, content: "original\n", file_path: path})
    {:ok, view} = ProjectView.overlay(context.project)
    owner = self()
    writer = file_writer_client("buffer.txt")

    client = fn model, messages, options ->
      case Enum.reverse(messages) do
        [%{role: :tool, name: "write_file"} | _] ->
          send(owner, :file_written_round_waiting)
          receive do: (:continue -> :ok)

        _ ->
          :ok
      end

      writer.(model, messages, options)
    end

    debug = fn
      acc,
      {:in, {:"$gen_call", _, {:complete_tool_effect, _, _, _, _, %{path: ^path}} = call}},
      _ ->
        send(owner, {:mutation_completion, call})
        acc

      acc, _, _ ->
        acc
    end

    session =
      start_session(context,
        provider_opts: [project_view: view, llm_client: client]
      )

    assert :ok = :sys.install(session, {debug, nil})

    assert :ok = Session.send_prompt(session, "draft\n")

    assert_receive {:agent_event, ^session,
                    {:tool_ended, %Event.ToolEnd{name: "write_file", is_error: false}}},
                   15_000

    assert_receive :file_written_round_waiting, @timeout
    assert_receive {:mutation_completion, completion}, @timeout
    backup = context.store_dir <> ".replay-backup"
    File.rename!(context.store_dir, backup)

    try do
      File.write!(context.store_dir, "snapshot writes are unavailable")
      assert :ok = GenServer.call(session, completion)
    after
      File.rm!(context.store_dir)
      File.rename!(backup, context.store_dir)
    end

    {:complete_tool_effect, request, checkpoint, call_id, message, change} = completion
    conflicting = %{change | path: path <> ".other"}

    assert {:error, {:tool_outcome_persistence_failed, :file_change_identity_conflict}} =
             GenServer.call(
               session,
               {:complete_tool_effect, request, checkpoint, call_id, message, conflicting}
             )

    record_id = Session.session_id(session)
    assert {:ok, "draft\n"} = ProjectView.read_file(view, "buffer.txt")
    assert :ok = stop_supervised({:session, context.suffix})

    assert {:ok, %{file_changes: [%{path: ^path, before: before, after: after_content}]}} =
             SessionStore.load(record_id, context.store_dir, artifact_runtime: context.runtime)

    reopened = start_session(%{context | suffix: {context.suffix, :reopened}})
    :ok = Session.subscribe(reopened)
    assert_receive {:agent_event, ^reopened, {:connection_changed, _initial}}
    %{connection: %{target: previous_target}} = Session.editor_snapshot(reopened)
    assert :ok = Session.load_session(reopened, record_id)

    receive do
      {:agent_event, ^reopened, {:connection_changed, %{target: %{session_id: ^record_id}}}} ->
        :ok

      {:agent_event, ^reopened, :messages_changed} ->
        flunk("restored transcript was published before its connection target")
    after
      @timeout -> flunk("restored connection target was not published")
    end

    assert {:ok, source} = ProjectView.resolve_source(view, "buffer.txt")

    revision =
      Minga.Buffer.FileMutation.revision("draft\n", nil, {:project_view, source.source_id})

    assert {:error, :stale_target} =
             Session.apply_review_mutation(
               previous_target,
               view,
               "buffer.txt",
               source,
               revision,
               {:replace, "original\n"}
             )

    assert {:ok, "draft\n"} = ProjectView.read_file(view, "buffer.txt")

    %{connection: %{target: target}} = Session.editor_snapshot(reopened)
    assert {:ok, %{^path => 1}} = Session.changed_file_counts(target)
    assert {:ok, {"original\n", "draft\n"}} = Session.read_cumulative_file_change(target, path)

    assert {:error, :no_file_change} =
             Session.read_cumulative_file_change(target, path <> ".other")

    assert :ok = Session.load_session(reopened, record_id)
    assert {:error, :stale_target} = Session.read_cumulative_file_change(target, path)
    assert {:error, :stale_target} = Session.changed_file_counts(target)
    assert {:ok, artifacts} = Session.artifact_store(reopened)

    for {reference, expected} <- [{before, "original\n"}, {after_content, "draft\n"}] do
      assert {:ok, range} =
               MingaAgent.Tool.Output.Range.new(
                 :full,
                 :bytes,
                 0,
                 byte_size(expected),
                 byte_size(expected)
               )

      assert {:ok, %{bytes: ^expected}} =
               MingaAgent.ArtifactStore.fetch(artifacts, reference, range)
    end

    assert {:ok, "draft\n"} = ProjectView.read_file(view, "buffer.txt")
    assert {:ok, diff} = ProjectView.diff(view)
    assert %{path: "buffer.txt", kind: :modified} in diff
    assert File.read!(path) == "original\n"
    assert Minga.Buffer.content(buffer) == "original\n"
  end

  defp replace_advice_result do
    owner = self()

    Advice.register(:around, :prefix_write, fn inner, state ->
      send(owner, {:inner_result, inner.(state)})
      {:returned, state, {:ok, "replacement must not hide storage failure"}}
    end)
  end

  defp file_writer_client(path) do
    fn model, messages, _options ->
      stream_response(model, file_writer_chunks(path, Enum.reverse(messages)))
    end
  end

  defp file_writer_chunks(path, [%{role: :user} | _]) do
    [
      StreamChunk.tool_call("read_file", %{"path" => path}, %{
        id: "read-" <> Integer.to_string(System.unique_integer([:positive]))
      }),
      StreamChunk.meta(%{finish_reason: :tool_use})
    ]
  end

  defp file_writer_chunks(
         path,
         [%{role: :tool, name: "read_file", content: parts} | _] = messages
       ) do
    result = Enum.map_join(parts, "", & &1.text)

    case Regex.run(~r/\[expected_revision: ([0-9a-f]{64})\]\z/, result) do
      [_, revision] ->
        user = Enum.find(messages, &(&1.role == :user))
        content = Enum.map_join(user.content, "", & &1.text)

        [
          StreamChunk.tool_call(
            "write_file",
            %{
              "path" => path,
              "mode" => "replace",
              "content" => content,
              "expected_revision" => revision
            },
            %{id: "write-" <> Integer.to_string(System.unique_integer([:positive]))}
          ),
          StreamChunk.meta(%{finish_reason: :tool_use})
        ]

      nil ->
        [StreamChunk.text("read failed; no mutation attempted")]
    end
  end

  defp file_writer_chunks(_path, _messages), do: [StreamChunk.text("finished")]

  defp run_policy_fence(context, publication) do
    install_write_tool(context)
    before_start_barrier()
    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write once")
    assert_receive {:before_start, worker}, @timeout
    gate = install_registry_barrier(context.registry, 2)
    send(worker, :continue_start)
    assert_receive {:registry_gate, registry_pid, ^gate}, @timeout
    publication.()
    send(registry_pid, {:release_gate, gate})
    await_done(session)
    assert_refused(context, session)
    refute_received :callback_built
    refute File.exists?(target(context))
  end

  defp install_registry_barrier(registry, target) do
    owner = self()
    token = make_ref()

    debug = fn count, event, _extra -> registry_barrier(count, event, target, owner, token) end

    assert :ok = :sys.install(registry, {debug, 0})
    token
  end

  defp registry_barrier(
         count,
         {:in, {:"$gen_call", _from, {:resolve_execution, "prefix_write"}}},
         target,
         owner,
         token
       ) do
    next = count + 1

    if next == target do
      send(owner, {:registry_gate, self(), token})
      receive do: ({:release_gate, ^token} -> :ok)
    end

    next
  end

  defp registry_barrier(count, _event, _target, _owner, _token), do: count

  defp before_start_barrier do
    owner = self()

    Advice.register(:before, :prefix_write, fn state ->
      send(owner, {:before_start, self()})
      receive do: (:continue_start -> state)
    end)
  end

  defp install_write_tool(
         context,
         bytes \\ "written\n",
         before_write \\ fn -> :ok end,
         name \\ "prefix_write"
       ) do
    parent = self()

    spec =
      Spec.new!(
        source: @source,
        name: name,
        description: "Write one fixture file",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}},
          "required" => ["path"]
        },
        category: :filesystem,
        capabilities: [:mutate_project],
        context_requirements: [:tool_context],
        build: fn tool_context ->
          send(parent, :callback_built)

          fn args ->
            before_write.()
            path = Path.expand(args["path"], tool_context.project_root)

            case File.write(path, bytes, [:append]) do
              :ok -> {:ok, "written"}
              {:error, reason} -> {:error, reason}
            end
          end
        end
      )

    assert :ok = ToolRegistry.register(context.registry, spec)
  end

  defp start_session(context, opts \\ []) do
    session_opts = native_session_options(context, opts)
    session = start_supervised!({Session, session_opts}, id: {:session, context.suffix})

    assert :ok =
             Session.subscribe(session, self(), questions?: Keyword.get(opts, :questions?, false))

    assert is_pid(Session.get_provider(session))
    session
  end

  defp native_session_options(context, opts) do
    owner = self()
    calls = :atomics.new(1, [])
    model = Keyword.get(opts, :model, "openai:gpt-6.1-sol")

    client = fn model, messages, options ->
      count = :atomics.add_get(calls, 1, 1)
      send(owner, {:transport_request, count, messages, options})

      if Keyword.get(opts, :hold_transport) == count do
        receive do
          :release_transport -> :ok
        after
          @timeout -> raise "test did not release Native transport"
        end
      end

      if Keyword.get(opts, :wire?, false) do
        {:ok, request} =
          ReqLLM.Providers.OpenAICodex.prepare_request(:chat, model, messages, options)

        wire =
          request
          |> ReqLLM.Providers.OpenAICodex.encode_body()
          |> Req.Steps.encode_body()
          |> Map.fetch!(:body)
          |> IO.iodata_to_binary()
          |> JSON.decode!()

        send(owner, {:wire_request, count, wire})
      end

      call? =
        Keyword.get(opts, :tool_call?, true) and
          (count == 1 or
             (Keyword.get(opts, :each_prompt?, false) and List.last(messages).role == :user))

      chunks = response_chunks(call?, count, opts)

      stream_response(model, chunks)
    end

    session_opts = [
      provider: Native,
      model_name: model,
      persist?: true,
      session_store_dir: context.store_dir,
      artifact_runtime: context.runtime,
      event_log_server: context.journal,
      options_server: context.options_name,
      hooks_enabled?: false,
      credentials_snapshot_fn: fn -> Credentials.snapshot(context.credential_opts) end,
      provider_opts:
        [
          model: model,
          model_resolver_opts: context.resolver_opts,
          config: %MingaAgent.Config{
            compaction_threshold: nil,
            tool_approval: Options.get(context.options_name, :agent_tool_approval),
            tool_permissions: Options.get(context.options_name, :agent_tool_permissions),
            destructive_tools: Options.get(context.options_name, :agent_destructive_tools)
          },
          credential_opts: context.credential_opts,
          tool_registry: context.registry,
          project_root: context.project,
          llm_client: client,
          max_retries: 0
        ]
        |> Keyword.merge(Keyword.get(opts, :provider_opts, []))
    ]

    Keyword.merge(session_opts, Keyword.get(opts, :session_opts, []))
  end

  defp response_chunks(true, _count, opts) do
    calls =
      Keyword.get(opts, :tool_calls, [
        {"prefix_write", %{"path" => "effect.txt"}, "prefix-call"}
      ])

    Enum.map(calls, fn {name, args, id} -> StreamChunk.tool_call(name, args, %{id: id}) end) ++
      [StreamChunk.meta(%{finish_reason: :tool_use})]
  end

  defp response_chunks(false, count, opts) do
    opaque =
      if Keyword.get(opts, :opaque?, false) do
        [
          StreamChunk.thinking("fixture reasoning summary", %{
            signature: "fixture-opaque-#{count}",
            encrypted?: true,
            provider: :openai_codex,
            format: "openai-responses-v1",
            provider_data: %{"type" => "reasoning", "id" => "rs_fixture_#{count}"}
          })
        ]
      else
        []
      end

    opaque ++ [StreamChunk.text("finished"), StreamChunk.meta(%{finish_reason: :stop})]
  end

  defp stream_response(model, chunks) do
    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{usage: %{total_cost: 0.0}, finish_reason: :stop}
      end)

    {:ok,
     %ReqLLM.StreamResponse{
       stream: chunks,
       metadata_handle: handle,
       cancel: fn -> :ok end,
       model: model,
       context: ReqLLM.Context.new()
     }}
  end

  defp await_done(session, name \\ "prefix_write") do
    assert_receive {:agent_event, ^session, {:tool_ended, %Event.ToolEnd{name: ^name}}}, @timeout
    await_idle(session)
  end

  defp await_idle(session) do
    assert_receive {:agent_event, ^session, {:resumable_boundary, _boundary}}, @timeout
    assert Session.editor_snapshot(session).status == :idle
  end

  defp stop_question_worker(worker) do
    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, @timeout
  end

  defp saved_tool_result(context, session, tool_call_id \\ "prefix-call") do
    assert {:ok, saved} =
             SessionStore.load(Session.session_id(session), context.store_dir,
               artifact_runtime: context.runtime
             )

    Enum.find(
      saved.continuation.messages,
      &(&1.role == :tool and &1.tool_call_id == tool_call_id)
    )
  end

  defp assert_refused(context, session) do
    assert saved_tool_result(context, session).metadata.is_error == true
    assert Session.editor_snapshot(session).error == nil
  end

  defp write_skill(context, name) do
    path = Path.join([context.project, ".minga", "skills", name, "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      "---\nname: #{name}\ndescription: Selected fixture instructions\n---\nApply the #{name} fixture instructions.\n"
    )
  end

  defp approval_config(context, fields) do
    struct!(
      %MingaAgent.Config{
        compaction_threshold: nil,
        tool_approval: Options.get(context.options_name, :agent_tool_approval),
        tool_permissions: Options.get(context.options_name, :agent_tool_permissions),
        destructive_tools: Options.get(context.options_name, :agent_destructive_tools)
      },
      fields
    )
  end

  defp target(context), do: Path.join(context.project, "effect.txt")
  defp unique_name(label, suffix), do: Module.concat(__MODULE__, "#{label}#{suffix}")
end
