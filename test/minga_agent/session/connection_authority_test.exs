defmodule MingaAgent.Session.ConnectionAuthorityTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Credentials
  alias MingaAgent.Credentials.Secret
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.Event
  alias MingaAgent.Session
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.Session.Continuation
  alias MingaAgent.SessionStore
  alias MingaAgent.Test.ModelSelectionFixture

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    env = Map.new(Credentials.known_providers(), &{Credentials.env_var_for(&1), nil})
    opts = [config_dir: directory, oauth_path: Path.join(directory, "oauth.json"), env: env]
    %{credential_opts: opts, credential_path: Path.join([directory, "minga", "credentials.json"])}
  end

  test "snapshot and change events share one exact target and connection projection", context do
    session = start_session(context)
    assert :ok = Session.subscribe(session)
    snapshot = Session.editor_snapshot(session)
    assert %ConnectionSnapshot{target: %{session: ^session}} = snapshot.connection
    assert snapshot.connection.target.session_id == Session.session_id(session)
    assert snapshot.connection.credential_readiness == snapshot.credential_readiness
    assert_receive {:agent_event, ^session, {:connection_changed, connection}}
    assert connection == snapshot.connection
    cookie = make_ref()
    kind = {:api_key, "openai"}

    assert {:ok, ref} =
             Session.begin_connection(session, connection.target, kind, self(), {self(), cookie})

    assert next_connection_event(session) ==
             {:connection_changed, %{connection | operation: {:connecting, ref}}}

    assert next_connection_event(session) ==
             {:connection_input_requested, cookie, connection.target, ref, kind}

    assert :ok = Session.cancel_connection(session, connection.target, ref)
    assert_receive {:agent_event, ^session, {:connection_changed, %{operation: :idle}}}
  end

  test "cancel before commit refuses storage and cancels only the bound worker reference",
       context do
    session = start_session(context)
    target = target(session)
    {:ok, first} = Session.begin_connection(session, target, {:api_key, "openai"}, self())
    worker = cancellation_worker()
    assert :ok = Session.register_connection_worker(session, target, first, worker)
    assert :ok = Session.cancel_connection(session, target, first)
    assert_receive {:worker_cancelled, ^worker, ^first}

    assert {:error, :cancelled} =
             Session.commit_api_key(
               session,
               target,
               first,
               "openai",
               Secret.new("synthetic-late")
             )

    assert {:error, :enoent} = File.read(context.credential_path)

    {:ok, next} = Session.begin_connection(session, target, {:api_key, "openai"}, self())
    next_worker = cancellation_worker()
    assert :ok = Session.register_connection_worker(session, target, next, next_worker)
    assert {:error, :superseded} = Session.cancel_connection(session, target, first)

    assert {:error, :superseded} =
             Session.register_connection_worker(session, target, first, worker)

    refute_receive {:worker_cancelled, ^next_worker, _}
    assert :ok = Session.cancel_connection(session, target, next)
    assert_receive {:worker_cancelled, ^next_worker, ^next}
  end

  test "supersession fences the old writer before any credential bytes change", context do
    assert :ok = Credentials.store("openai", "synthetic-prior", context.credential_opts)
    before = File.read!(context.credential_path)
    session = start_session(context)
    target = target(session)
    {:ok, first} = Session.begin_connection(session, target, {:api_key, "openai"}, self())
    worker = cancellation_worker()
    assert :ok = Session.register_connection_worker(session, target, first, worker)
    {:ok, second} = Session.begin_connection(session, target, {:api_key, "openai"}, self())
    assert_receive {:worker_cancelled, ^worker, ^first}

    assert {:error, :superseded} =
             Session.commit_api_key(
               session,
               target,
               first,
               "openai",
               Secret.new("synthetic-late")
             )

    assert File.read!(context.credential_path) == before

    assert :ok = Session.register_connection_worker(session, target, second, self())

    assert {:ok, %ConnectionSnapshot{}} =
             Session.commit_api_key(
               session,
               target,
               second,
               "openai",
               Secret.new("synthetic-new")
             )

    assert {:ok, "synthetic-new", :file} = Credentials.resolve("openai", context.credential_opts)
    assert {:error, :already_committed} = Session.cancel_connection(session, target, second)

    assert {:error, :already_committed} =
             Session.commit_api_key(
               session,
               target,
               second,
               "openai",
               Secret.new("synthetic-replay")
             )
  end

  test "committed replacement invalidates setup including A to B to A model changes", context do
    session = start_session(context)
    original = target(session)
    {:ok, ref} = Session.begin_connection(session, original, {:api_key, "openai"}, self())
    model = Session.metadata(session).model_name
    assert :ok = Session.set_model(session, "test:replacement")
    second = target(session)
    assert second.epoch != original.epoch
    assert :ok = Session.set_model(session, model)
    returned = target(session)
    assert returned.epoch != original.epoch
    assert returned.epoch != second.epoch

    assert {:error, :stale_target} =
             Session.commit_api_key(
               session,
               original,
               ref,
               "openai",
               Secret.new("synthetic-late")
             )

    assert {:error, :stale_target} = Session.retry_connection(session, original)

    assert {:error, :stale_target} =
             Session.begin_connection(session, original, {:api_key, "openai"}, self())

    assert {:error, :enoent} = File.read(context.credential_path)
  end

  test "failed load preserves the live target, committed same-record loads always invalidate",
       context do
    session = start_session(context, session_store_dir: context.tmp_dir)
    original = target(session)
    {:ok, ref} = Session.begin_connection(session, original, {:api_key, "openai"}, self())
    assert {:error, _reason} = Session.load_session(session, "missing-record")
    assert target(session) == original
    id = Session.session_id(session)

    assert :ok =
             SessionStore.save(
               %{
                 id: id,
                 timestamp: DateTime.to_iso8601(DateTime.utc_now()),
                 model_name: "test:loaded",
                 usage: Session.usage(session),
                 messages: [],
                 continuation: Continuation.new()
               },
               context.tmp_dir
             )

    assert :ok = Session.load_session(session, id)
    assert target(session).session_id == original.session_id
    assert target(session).epoch != original.epoch

    assert {:error, :stale_target} =
             Session.commit_api_key(session, original, ref, "openai", Secret.new("synthetic-key"))

    loaded = target(session)
    assert :ok = Session.load_session(session, id)
    assert target(session).epoch != loaded.epoch
  end

  test "new conversation makes even an earlier committed operation stale", context do
    session = start_session(context)
    original = target(session)
    {:ok, ref} = Session.begin_connection(session, original, {:api_key, "openai"}, self())
    assert :ok = Session.register_connection_worker(session, original, ref, self())

    assert {:ok, _connection} =
             Session.commit_api_key(session, original, ref, "openai", Secret.new("synthetic-key"))

    assert {:error, :already_committed} = Session.cancel_connection(session, original, ref)
    assert :ok = Session.new_session(session)
    assert {:error, :stale_target} = Session.cancel_connection(session, original, ref)
  end

  test "storage failure preserves selection, epoch, previous bytes and readiness", context do
    assert :ok = Credentials.store("openai", "synthetic-prior", context.credential_opts)
    before = File.read!(context.credential_path)

    session =
      start_session(context,
        provider: MingaAgent.Providers.Native,
        provider_opts: [
          model: ModelSelectionFixture.model_intent(),
          config: %MingaAgent.Config{},
          credential_opts: context.credential_opts,
          model_resolver_opts: resolver_opts()
        ]
      )

    previous = Session.editor_snapshot(session)
    assert previous.model_selection != nil
    directory = Path.dirname(context.credential_path)
    File.chmod!(directory, 0o500)

    try do
      {:ok, ref} =
        Session.begin_connection(
          session,
          previous.connection.target,
          {:api_key, "openai"},
          self()
        )

      assert :ok =
               Session.register_connection_worker(
                 session,
                 previous.connection.target,
                 ref,
                 self()
               )

      assert {:error, :credential_store_failed} =
               Session.commit_api_key(
                 session,
                 previous.connection.target,
                 ref,
                 "openai",
                 Secret.new("synthetic-new")
               )

      assert File.read!(context.credential_path) == before
      current = Session.editor_snapshot(session)
      assert current.connection.target == previous.connection.target
      assert current.model_selection == previous.model_selection
      assert current.credential_readiness == previous.credential_readiness

      assert {:error, :credential_store_failed} =
               Session.cancel_connection(session, previous.connection.target, ref)
    after
      File.chmod!(directory, 0o700)
    end
  end

  test "owner death and worker death retire only their exact operation", context do
    session = start_session(context)
    target = target(session)
    owner = start_supervised!({Agent, fn -> nil end})
    worker = cancellation_worker()
    {:ok, ref} = Session.begin_connection(session, target, {:api_key, "openai"}, owner)

    assert :ok =
             Agent.get(owner, fn _ ->
               Session.register_connection_worker(session, target, ref, worker)
             end)

    monitor = Process.monitor(owner)
    Agent.stop(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    assert_receive {:worker_cancelled, ^worker, ^ref}

    assert {:error, :cancelled} =
             Session.commit_api_key(session, target, ref, "openai", Secret.new("synthetic-key"))

    assert :ok = Session.subscribe(session)
    assert_receive {:agent_event, ^session, {:connection_changed, %{operation: :idle}}}
    worker = waiting_process()
    {:ok, next} = Session.begin_connection(session, target, {:api_key, "openai"}, self())
    assert :ok = Session.register_connection_worker(session, target, next, worker)

    assert_receive {:agent_event, ^session,
                    {:connection_changed, %{operation: {:connecting, ^next}}}}

    send(worker, :stop)
    assert_receive {:agent_event, ^session, {:connection_changed, %{operation: :idle}}}

    assert {:error, :cancelled} =
             Session.commit_api_key(session, target, next, "openai", Secret.new("synthetic-key"))
  end

  test "commits refresh the originating Session only and never submit or replay a retained draft",
       context do
    test = self()

    snapshot = fn ->
      facts = Credentials.snapshot(context.credential_opts)
      send(test, {:acquired, self(), Snapshot.locally_configured?(facts)})
      facts
    end

    first = start_session(context, credentials_snapshot_fn: snapshot)
    second = start_session(context, credentials_snapshot_fn: snapshot)
    assert_receive {:acquired, ^first, false}
    assert_receive {:acquired, ^second, false}
    messages = Session.messages(first)
    target = target(first)
    {:ok, ref} = Session.begin_connection(first, target, {:api_key, "openai"}, self())
    assert :ok = Session.register_connection_worker(first, target, ref, self())

    assert {:ok, connection} =
             Session.commit_api_key(first, target, ref, "openai", Secret.new("synthetic-local"))

    assert connection.credential_readiness == :configured
    assert_receive {:acquired, ^first, true}
    refute_receive {:acquired, ^second, _}
    assert Session.messages(first) == messages
    assert Session.status(first) == :idle
    assert :ok = Session.retry_connection(first, connection.target)
    assert_receive {:acquired, ^first, true}
    refute_receive {:acquired, ^second, _}
    assert Session.messages(first) == messages
    assert Session.status(first) == :idle
  end

  test "method mismatch and malformed material never persist or replace the selection", context do
    session = start_session(context)
    target = target(session)

    assert {:error, :unsupported_method} =
             Session.begin_connection(session, target, {:api_key, "unknown"}, self())

    {:ok, ref} = Session.begin_connection(session, target, {:api_key, "openai"}, self())
    assert :ok = Session.register_connection_worker(session, target, ref, self())

    assert {:error, :method_mismatch} =
             Session.commit_api_key(session, target, ref, "anthropic", Secret.new("synthetic"))

    assert {:error, :invalid_secret} =
             Session.commit_api_key(session, target, ref, "openai", Secret.new("synthetic\nkey"))

    assert target(session) == target
    assert {:error, :enoent} = File.read(context.credential_path)
  end

  test "only the editor's registered writer can save while its admitted driver is attached",
       context do
    assert :ok = Credentials.store("openai", "synthetic-prior", context.credential_opts)
    before = File.read!(context.credential_path)
    session = start_session(context)
    target = target(session)
    driver = waiting_process()
    writer = start_supervised!({Agent, fn -> nil end})
    assert :ok = Session.subscribe(session, driver, role: :driver)

    assert {:ok, ref} =
             Session.begin_connection(session, target, {:api_key, "openai"}, self(), {driver, 1})

    commit = fn _ ->
      Session.commit_api_key(session, target, ref, "openai", Secret.new("synthetic-refused"))
    end

    assert {:error, :not_connection_actor} =
             Agent.get(writer, fn _ ->
               Session.register_connection_worker(session, target, ref, self())
             end)

    assert {:error, :not_connection_actor} = Agent.get(writer, commit)

    assert {:error, :not_connection_actor} =
             Agent.get(writer, fn _ -> Session.cancel_connection(session, target, ref) end)

    assert :ok = Session.register_connection_worker(session, target, ref, writer)
    assert {:error, :not_connection_actor} = commit.(nil)
    assert :ok = Session.unsubscribe(session, driver)
    assert {:error, :cancelled} = Agent.get(writer, commit)
    assert File.read!(context.credential_path) == before
  end

  test "a successful save follows its post-commit connection snapshot on the driver stream",
       context do
    session = start_session(context)
    target = target(session)
    assert :ok = Session.subscribe(session)
    assert_receive {:agent_event, ^session, {:connection_changed, _snapshot}}
    owner = self()
    kind = {:api_key, "openai"}
    {:ok, ref} = Session.begin_connection(session, target, kind, owner, {owner, 1})

    assert {:connection_changed, %{operation: {:connecting, ^ref}}} =
             next_connection_event(session)

    assert {:connection_input_requested, 1, ^target, ^ref, ^kind} = next_connection_event(session)
    assert :ok = Session.register_connection_worker(session, target, ref, self())

    assert {:ok, snapshot} =
             Session.commit_api_key(session, target, ref, "openai", Secret.new("synthetic-saved"))

    assert next_connection_event(session) == {:connection_changed, snapshot}
    assert next_connection_event(session) == {:connection_api_key_saved, 1, snapshot.target, ref}
  end

  test "native unconfigured readiness preserves typed resolver failure, without startup or provider requests",
       context do
    session =
      start_session(context,
        provider: MingaAgent.Providers.Native,
        provider_opts: [
          model: ModelSelectionFixture.model_intent(),
          credential_opts: context.credential_opts,
          config: %MingaAgent.Config{},
          model_resolver_opts: resolver_opts()
        ]
      )

    connection = Session.editor_snapshot(session).connection
    assert connection.credential_readiness == :unconfigured
    assert connection.provider_phase == :stopped
    assert {:resolution, _typed_problem} = connection.problem
    assert ConnectionSnapshot.status(connection) != :ready
    previous = connection.target
    assert {:error, _reason} = Session.set_model(session, "openai:model-not-in-fixture")
    assert target(session) == previous
  end

  test "a first native model activation retires setup for the unconfigured target", context do
    intent = ModelSelectionFixture.model_intent()

    session =
      start_session(context,
        provider: MingaAgent.Providers.Native,
        provider_opts: [
          model: intent,
          credential_opts: context.credential_opts,
          config: %MingaAgent.Config{},
          model_resolver_opts: resolver_opts()
        ]
      )

    original = target(session)
    assert original.selection_id == nil
    assert {:ok, ref} = Session.begin_connection(session, original, {:api_key, "openai"}, self())
    worker = cancellation_worker()
    assert :ok = Session.register_connection_worker(session, original, ref, worker)
    assert :ok = Credentials.store("openai", "synthetic-configured", context.credential_opts)
    assert :ok = Session.set_model_for_target(session, original, intent)
    assert_receive {:worker_cancelled, ^worker, ^ref}

    assert %{target: activated, operation: :idle} = Session.editor_snapshot(session).connection
    assert activated.selection_id != nil
    assert activated.epoch != original.epoch
    assert Session.cancel_connection(session, original, ref) == {:error, :stale_target}
  end

  test "structured provider auth failure differs from ordinary tool failure", context do
    session = start_session(context)

    send(
      session,
      {:agent_provider_lifecycle_event, %Event.Error{kind: :tool_error, message: "auth failed"}}
    )

    assert Session.editor_snapshot(session).connection.problem == nil

    send(
      session,
      {:agent_provider_lifecycle_event,
       %Event.Error{kind: :auth_failed, message: "no string clues"}}
    )

    connection = Session.editor_snapshot(session).connection
    assert connection.problem == {:provider, :auth_failed}
    assert ConnectionSnapshot.status(connection) == :credential_failure
    assert connection.credential_readiness == :configured
    assert :ok = Session.retry_connection(session, connection.target)
    assert Session.editor_snapshot(session).connection.problem == nil
  end

  defp resolver_opts do
    Keyword.delete(ModelSelectionFixture.resolver_opts(), :credential_snapshot)
  end

  defp start_session(context, extra \\ []) do
    opts =
      Keyword.merge(
        [
          provider: Minga.Test.SessionMockProvider,
          provider_opts: [credential_opts: context.credential_opts],
          persist?: false,
          hooks_enabled?: false,
          session_start_hook_enabled?: false,
          recover_interrupted_work?: false
        ],
        extra
      )

    session = start_supervised!({Session, opts}, id: make_ref())
    Session.editor_snapshot(session)
    session
  end

  defp target(session), do: Session.editor_snapshot(session).connection.target

  defp waiting_process do
    start_supervised!(
      {Task,
       fn ->
         receive do
           :stop -> :ok
         end
       end},
      id: make_ref()
    )
  end

  defp cancellation_worker do
    test = self()

    start_supervised!(
      {Task,
       fn ->
         receive do
           {:connection_cancelled, ref} -> send(test, {:worker_cancelled, self(), ref})
         end
       end},
      id: make_ref()
    )
  end

  defp next_connection_event(session) do
    receive do
      {:agent_event, ^session, {event, _snapshot} = message} when event == :connection_changed ->
        message

      {:agent_event, ^session, {:connection_input_requested, _, _, _, _} = message} ->
        message

      {:agent_event, ^session, {:connection_api_key_saved, _, _, _} = message} ->
        message
    after
      1_000 -> flunk("timed out waiting for connection event")
    end
  end
end
