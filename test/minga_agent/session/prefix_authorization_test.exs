defmodule MingaAgent.Session.PrefixAuthorizationTest do
  # Executor advice uses the shared Advice table; every other owner is isolated below.
  use ExUnit.Case, async: false

  alias Minga.Config.Advice
  alias Minga.Config.Options
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaAgent.ProjectView
  alias MingaAgent.ArtifactSupervisor
  alias MingaAgent.Credentials
  alias MingaAgent.EventLog
  alias MingaAgent.OAuth
  alias MingaAgent.Providers.Native
  alias MingaAgent.Session
  alias MingaAgent.SessionStore
  alias MingaAgent.Test.ModelSelectionFixture
  alias MingaAgent.Tool.Registry, as: ToolRegistry
  alias MingaAgent.Tool.Spec
  alias ReqLLM.StreamChunk

  @moduletag :tmp_dir
  @timeout 5_000
  @source {:extension, :prefix_authority_fixture}

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

  test "revocation during approval is an ordinary durable refusal, not a storage failure",
       context do
    install_write_tool(context)

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{"prefix_write" => :ask})

    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write once")
    assert_receive {:agent_event, ^session, {:approval_pending, _approval}}, @timeout

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{"prefix_write" => :deny})

    assert :ok = Session.respond_to_approval(session, :approve)
    await_done(session)
    assert_refused(context, session)
    refute_received :callback_built
    refute File.exists?(target(context))
  end

  test "removed sources refuse effects and unsupported replay retains actionable context",
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

      stream_response(model, [
        StreamChunk.thinking("opaque fixture summary", %{
          signature: "fixture-refused-opaque",
          encrypted?: true,
          provider: :openai_codex,
          format: "openai-responses-v1",
          provider_data: %{"type" => "reasoning", "id" => "rs_refused_fixture"}
        }),
        StreamChunk.tool_call("prefix_write", %{"path" => "effect.txt"}, %{id: "prefix-call"}),
        StreamChunk.meta(%{finish_reason: :tool_use})
      ])
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

    assert 1 == :erlang.trace(session, true, [:receive])
    assert :ok = ToolRegistry.unregister_source(context.registry, @source)
    send(worker, :continue_start)

    assert_receive {:agent_event, ^session, {:tool_ended, "prefix_write", _result, _status}},
                   @timeout

    assert_receive {:trace, ^session, :receive,
                    {:agent_provider_event, _request_id,
                     %MingaAgent.Event.Error{
                       kind: :context_transition_required,
                       message: native_message
                     }}},
                   @timeout

    assert_receive {:agent_event, ^session, {:error, public_message}}, @timeout

    assert_receive {:trace, ^session, :receive,
                    {:agent_provider_event, _request_id, %MingaAgent.Event.AgentEnd{}}},
                   @timeout

    assert 1 == :erlang.trace(session, false, [:receive])
    assert public_message == native_message
    assert public_message =~ "/new"
    assert public_message =~ "Retain"
    refute public_message =~ "provider"
    refute public_message =~ "/model"
    assert Session.editor_snapshot(session).error == public_message
    assert {:system, public_message, :error} in Session.messages(session)
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

    refute_receive {:transport_request, 2, _messages, _options}, 0
  end

  test "same-name same-schema replacement does not inherit the earlier approval subject",
       context do
    install_write_tool(context)

    assert {:ok, _} =
             Options.set(context.options_name, :agent_tool_permissions, %{"prefix_write" => :ask})

    session = start_session(context)
    assert :ok = Session.send_prompt(session, "write once")
    assert_receive {:agent_event, ^session, {:approval_pending, _approval}}, @timeout
    install_write_tool(context, "replacement\n")
    assert :ok = Session.respond_to_approval(session, :approve)
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

  test "model transitions preserve the effective selection and fresh conversations preserve the old record",
       context do
    write_skill(context, "selected")
    session = start_session(context, tool_call?: false)
    assert :ok = Session.send_prompt(session, "first turn")
    await_idle(session)
    original = Session.editor_snapshot(session).model_selection
    record = Session.session_id(session)

    assert {:ok, saved} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert {:error, {:portable_context_transition_required, _}} =
             Session.set_model(session, "openai:other-model")

    assert Session.editor_snapshot(session).model_selection == original

    assert {:error, {:portable_context_transition_required, _}} =
             Session.activate_skill(session, "selected")

    assert :ok = Session.new_session(session)
    refute Session.session_id(session) == record

    assert {:ok, preserved} =
             SessionStore.load(record, context.store_dir, artifact_runtime: context.runtime)

    assert preserved.continuation == saved.continuation
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

    refute Enum.any?(
             names,
             &(&1 in [
                 "memory_write",
                 "memory_read",
                 "describe_runtime",
                 "describe_tools",
                 "cycle_model"
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
    assert_receive {:agent_event, ^session, {:approval_pending, _approval}}, @timeout
    refute File.exists?(target(context))
    assert :ok = Session.respond_to_approval(session, :approve)
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
    assert_receive {:agent_event, ^session, {:approval_pending, _approval}}, @timeout
    assert :ok = Session.respond_to_approval(session, :reject)
    await_done(session, "read_file")
    result = saved_tool_result(context, session)
    assert result.metadata.is_error == true
    refute Enum.map_join(result.content, "", & &1.text) =~ "sensitive fixture"
    assert File.read!(target(context)) == "sensitive fixture"
  end

  test "approved shell execution uses the working directory when no project is active", context do
    assert {:ok, _} = Options.set(context.options_name, :agent_tool_approval, :destructive)
    assert {:ok, _} = Options.set(context.options_name, :agent_destructive_tools, ["shell"])

    session =
      start_session(context,
        tool_calls: [{"shell", %{"command" => "pwd"}, "prefix-call"}],
        provider_opts: [project_root: nil]
      )

    assert :ok = Session.send_prompt(session, "print the working directory")
    assert_receive {:agent_event, ^session, {:approval_pending, _approval}}, @timeout
    assert :ok = Session.respond_to_approval(session, :approve)
    await_done(session, "shell")
    result = saved_tool_result(context, session)
    assert result.metadata.is_error == false
    assert Enum.map_join(result.content, "", & &1.text) =~ File.cwd!()
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
    assert_receive {:agent_event, ^session, {:approval_pending, _first}}, @timeout
    assert :ok = Session.respond_to_approval(session, :approve)
    assert_receive {:agent_event, ^session, {:approval_pending, _second}}, @timeout
    assert :ok = Session.respond_to_approval(session, :approve)
    await_done(session)
    assert File.read!(target(context)) == "written\nwritten\n"
  end

  test "approval can start its call while an admitted allowed sibling is still running",
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
    assert_receive {:agent_event, ^session, {:approval_pending, _approval}}, @timeout
    assert_receive {:allowed_started, worker}, @timeout
    assert :ok = Session.respond_to_approval(session, :approve)

    assert_receive {:agent_event, ^session, {:tool_ended, "prefix_write", _result, _status}},
                   @timeout

    assert File.read!(target(context)) == "written\n"
    refute File.exists?(Path.join(context.project, "allowed.txt"))
    send(worker, :settle)
    await_done(session, "allowed_write")
    assert File.read!(Path.join(context.project, "allowed.txt")) == "allowed\n"
  end

  test "an allowed sibling settles while another call awaits approval and can be rejected",
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
    assert_receive {:agent_event, ^session, {:approval_pending, _approval}}, @timeout

    assert_receive {:agent_event, ^session, {:tool_ended, "allowed_write", _result, _status}},
                   @timeout

    assert File.read!(Path.join(context.project, "allowed.txt")) == "allowed\n"
    refute File.exists?(target(context))
    assert :ok = Session.respond_to_approval(session, :reject)
    await_done(session)
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

  test "a current builtin context stops using a dead fork store on the next invocation",
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
    await_done(session, "write_file")
    assert File.read!(path) == "original\n"
    assert Minga.Buffer.content(buffer) == "original\n"
    monitor = Process.monitor(store)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^store, _reason}, @timeout
    assert Native.fork_store(provider) == nil
    assert :ok = Session.send_prompt(session, "direct\n")
    await_done(session, "write_file")
    assert File.read!(path) == "original\n"
    assert Minga.Buffer.content(buffer) == "direct\n"
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

    session =
      start_session(context,
        provider_opts: [project_view: view, llm_client: file_writer_client("buffer.txt")]
      )

    assert :ok = Session.send_prompt(session, "draft\n")
    await_done(session, "write_file")
    assert {:ok, "draft\n"} = ProjectView.read_file(view, "buffer.txt")
    assert :ok = stop_supervised({:session, context.suffix})
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
      chunks =
        case List.last(messages) do
          %{role: :user, content: parts} ->
            content = Enum.map_join(parts, "", & &1.text)

            [
              StreamChunk.tool_call(
                "write_file",
                %{"path" => path, "content" => content},
                %{id: "write-" <> Integer.to_string(System.unique_integer([:positive]))}
              ),
              StreamChunk.meta(%{finish_reason: :tool_use})
            ]

          _tool_result ->
            [StreamChunk.text("finished")]
        end

      stream_response(model, chunks)
    end
  end

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
    owner = self()
    calls = :atomics.new(1, [])

    client = fn model, messages, options ->
      count = :atomics.add_get(calls, 1, 1)
      send(owner, {:transport_request, count, messages, options})

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
      model_name: "openai:gpt-6.1-sol",
      persist?: true,
      session_store_dir: context.store_dir,
      artifact_runtime: context.runtime,
      event_log_server: context.journal,
      options_server: context.options_name,
      hooks_enabled?: false,
      credentials_snapshot_fn: fn -> Credentials.snapshot(context.credential_opts) end,
      provider_opts:
        [
          model: "openai:gpt-6.1-sol",
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

    session = start_supervised!({Session, session_opts}, id: {:session, context.suffix})
    assert :ok = Session.subscribe(session)
    assert is_pid(Session.get_provider(session))
    session
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
    assert_receive {:agent_event, ^session, {:tool_ended, ^name, _result, _status}}, @timeout
    await_idle(session)
  end

  defp await_idle(session) do
    assert_receive {:agent_event, ^session, {:resumable_boundary, _boundary}}, @timeout
    assert Session.editor_snapshot(session).status == :idle
  end

  defp saved_tool_result(context, session) do
    assert {:ok, saved} =
             SessionStore.load(Session.session_id(session), context.store_dir,
               artifact_runtime: context.runtime
             )

    Enum.find(
      saved.continuation.messages,
      &(&1.role == :tool and &1.tool_call_id == "prefix-call")
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

  defp target(context), do: Path.join(context.project, "effect.txt")
  defp unique_name(label, suffix), do: Module.concat(__MODULE__, "#{label}#{suffix}")
end
