defmodule MingaAgent.SessionRecoveryTest do
  use ExUnit.Case, async: true

  alias Minga.Test.StubProvider
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Credentials.AvailabilityCheck
  alias MingaAgent.Credentials.Snapshot, as: CredentialSnapshot
  alias MingaAgent.Providers.Native
  alias MingaAgent.ModelResolver
  alias MingaAgent.Session
  alias MingaAgent.Session.ProviderLifecycle
  alias MingaAgent.SessionStore
  alias MingaAgent.TurnUsage

  # Provider startup runs synchronously inside the Session process
  # (`start_provider/1` -> `provider_module.start_link/1` -> `Native.init/1`).
  # That startup is only ~10ms idle, but under full-suite scheduler contention the
  # Session can stall well past the default 5s `GenServer.call` timeout, so any
  # call that triggers or waits behind startup times out (issue #2663). We wait for
  # startup to finish with `:sys.get_state/2` (a synchronization barrier that
  # drains the Session mailbox) and give startup-triggering calls a generous
  # ceiling, instead of racing the 5s default.
  @startup_timeout 30_000

  # Blocks until the Session has processed every message enqueued before this call,
  # including any `:start_provider` scheduled during `start_link/1` or a preceding
  # `refresh_credentials/1` cast. After it returns the Session is idle, so the
  # following assertions run against a settled provider without racing the timeout.
  defp await_provider_startup(session), do: :sys.get_state(session, @startup_timeout)

  defp start_credential_checker(initial_state) do
    checker =
      {Agent, fn -> initial_state end}
      |> Supervisor.child_spec(id: {:credential_checker, make_ref()})
      |> start_supervised!()

    {checker, fn -> Agent.get(checker, & &1) end}
  end

  defp start_session(opts, initial_credentials_state) do
    {checker, credentials_configured_fn} = start_credential_checker(initial_credentials_state)

    credentials_snapshot_fn = fn ->
      sources =
        if credentials_configured_fn.(),
          do: %{"anthropic" => :env},
          else: %{}

      CredentialSnapshot.new(sources, nil, "http://ollama.test")
    end

    test_pid = self()

    credential_probe_fn = fn _snapshot ->
      send(test_pid, {:credential_probe_started, self()})

      receive do
        {:release_credential_probe, ^test_pid} -> {:unavailable, :test}
      end
    end

    provider_opts =
      Keyword.get(opts, :provider_opts, [])
      |> Keyword.merge(skip_api_key_env: true)
      |> Keyword.put_new(:model_resolver_opts, recovery_model_opts())

    {:ok, session} =
      Session.start_link(
        opts
        |> Keyword.put(:provider_opts, provider_opts)
        |> Keyword.put(:credentials_configured_fn, credentials_configured_fn)
        |> Keyword.put(:credentials_snapshot_fn, credentials_snapshot_fn)
        |> Keyword.put(:credential_probe_fn, credential_probe_fn)
      )

    # `start_link/1` schedules `:start_provider` when credentials are already
    # configured; wait it out here so callers observe a settled session.
    await_provider_startup(session)

    {session, checker}
  end

  defmodule FailingProvider do
    @behaviour MingaAgent.Provider

    @impl MingaAgent.Provider
    def start_link(_opts), do: {:error, {:spawn_failed, "boom"}}

    @impl MingaAgent.Provider
    def send_prompt(_pid, _text), do: :ok

    @impl MingaAgent.Provider
    def abort(_pid), do: :ok

    @impl MingaAgent.Provider
    def new_session(_pid), do: :ok

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: nil}}
  end

  defmodule FlakyStartProvider do
    @behaviour MingaAgent.Provider

    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      tracker = Keyword.fetch!(opts, :tracker)

      attempt =
        Agent.get_and_update(tracker, fn state ->
          attempt = Map.get(state, :attempts, 0) + 1
          failures_remaining = Map.get(state, :failures_remaining, 0)

          next_failures =
            if failures_remaining == :always, do: :always, else: max(failures_remaining - 1, 0)

          next_state = %{state | attempts: attempt, failures_remaining: next_failures}
          {{attempt, failures_remaining}, next_state}
        end)

      send(test_pid, {:flaky_start_attempt, elem(attempt, 0)})

      case attempt do
        {_attempt, :always} ->
          {:error, {:spawn_failed, "boom"}}

        {_attempt, failures_remaining} when failures_remaining > 0 ->
          {:error, {:spawn_failed, "boom"}}

        _attempt ->
          GenServer.start_link(__MODULE__, opts)
      end
    end

    @impl MingaAgent.Provider
    def send_prompt(_pid, _text), do: :ok

    @impl MingaAgent.Provider
    def abort(_pid), do: :ok

    @impl MingaAgent.Provider
    def new_session(_pid), do: :ok

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: nil}}

    @impl GenServer
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:flaky_provider_started, self()})
      {:ok, %{test_pid: test_pid}}
    end
  end

  defmodule CrashableProvider do
    @behaviour MingaAgent.Provider

    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl MingaAgent.Provider
    def send_prompt(_pid, _text), do: :ok

    @impl MingaAgent.Provider
    def abort(_pid), do: :ok

    @impl MingaAgent.Provider
    def new_session(_pid), do: :ok

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: nil}}

    @impl GenServer
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:crashable_provider_started, self()})
      {:ok, %{test_pid: test_pid}}
    end
  end

  defp empty_credential_snapshot do
    CredentialSnapshot.new(%{}, nil, "http://ollama.test")
  end

  defp recovery_model_opts do
    remote_models =
      Enum.filter(LLMDB.models(), fn model ->
        model.provider == :anthropic and
          model.id in ["claude-sonnet-4-20250514", "claude-opus-4-20250514"]
      end)

    local_models =
      Enum.map(["llama3", "loaded", "model-b", "model-c"], fn id ->
        %{
          id: id,
          provider: :ollama,
          provider_model_id: id,
          capabilities: %{"streaming" => %{"text" => true}},
          execution: %{
            text: %{
              supported: true,
              family: "openai_chat_compatible",
              wire_protocol: "openai_chat",
              transport: "http",
              provider_model_id: id,
              path: "/chat/completions"
            }
          }
        }
      end)

    [models: remote_models ++ local_models]
  end

  defp start_held_discovery_session(opts \\ []) do
    test_pid = self()

    {:ok, sequence} = Agent.start_link(fn -> 0 end)

    probe = fn _snapshot ->
      index = Agent.get_and_update(sequence, fn value -> {value + 1, value + 1} end)
      send(test_pid, {:credential_probe_started, index, self()})

      receive do
        {:credential_probe_result, result} -> result
        :crash_credential_probe -> exit(:probe_crash)
      end
    end

    session_opts =
      [
        provider: Native,
        provider_opts: [
          model: "ollama:llama3",
          skip_api_key_env: true,
          model_resolver_opts: recovery_model_opts()
        ],
        credentials_snapshot_fn: &empty_credential_snapshot/0,
        credential_probe_fn: probe
      ]
      |> Keyword.merge(opts)

    session = start_supervised!({Session, session_opts})
    {session, sequence}
  end

  defp start_running_held_model_session(keep_credentials? \\ false, opts \\ []) do
    {checker, credentials_configured_fn} = start_credential_checker(true)

    credentials_snapshot_fn = fn ->
      sources = if credentials_configured_fn.(), do: %{"anthropic" => :env}, else: %{}
      CredentialSnapshot.new(sources, nil, "http://ollama.test")
    end

    test_pid = self()
    {:ok, sequence} = Agent.start_link(fn -> 0 end)

    probe = fn _snapshot ->
      index = Agent.get_and_update(sequence, fn value -> {value + 1, value + 1} end)
      send(test_pid, {:credential_probe_started, index, self()})

      receive do
        {:credential_probe_result, result} -> result
      end
    end

    session_opts =
      [
        provider: Native,
        provider_opts: [
          model: "anthropic:claude-sonnet-4-20250514",
          skip_api_key_env: true,
          model_resolver_opts: recovery_model_opts()
        ],
        credentials_configured_fn: credentials_configured_fn,
        credentials_snapshot_fn: credentials_snapshot_fn,
        credential_probe_fn: probe
      ]
      |> Keyword.merge(opts)

    session = start_supervised!({Session, session_opts})

    await_provider_startup(session)
    provider = Session.get_provider(session)
    assert is_pid(provider)
    Agent.update(checker, fn _configured? -> keep_credentials? end)
    {session, provider}
  end

  test "local activation probes the same snapshot that resolved its immutable endpoint" do
    counter = start_supervised!({Agent, fn -> 0 end})

    snapshot_fn = fn ->
      count = Agent.get_and_update(counter, fn count -> {count, count + 1} end)
      host = if count == 0, do: "http://endpoint-a:11434", else: "http://endpoint-b:11434"
      CredentialSnapshot.new(%{"anthropic" => :env}, nil, host)
    end

    parent = self()

    probe = fn snapshot ->
      send(parent, {:probed_host, snapshot.ollama_host, self()})

      receive do
        :accept -> :available
      end
    end

    session =
      start_supervised!(
        {Session,
         provider: Native,
         provider_opts: [
           model: "anthropic:claude-sonnet-4-20250514",
           skip_api_key_env: true,
           model_resolver_opts: recovery_model_opts()
         ],
         credentials_snapshot_fn: snapshot_fn,
         credential_probe_fn: probe}
      )

    await_provider_startup(session)
    Agent.update(counter, fn _ -> 0 end)
    Session.subscribe(session, self())
    assert {:pending, :credential_discovery} = Session.set_model(session, "ollama:model-b")
    assert_receive {:probed_host, "http://endpoint-a:11434", worker}
    send(worker, :accept)
    assert_receive {:agent_event, ^session, {:model_selection_changed, selection}}
    assert URI.parse(selection.route.execution.base_url).host == "endpoint-a"
  end

  @tag :tmp_dir
  test "a failed detached restore preserves the original provider retry", %{tmp_dir: dir} do
    tracker = start_supervised!({Agent, fn -> %{attempts: 0, failures_remaining: :always} end})

    session =
      start_supervised!(
        {Session,
         provider: FlakyStartProvider,
         provider_opts: [test_pid: self(), tracker: tracker],
         session_store_dir: dir,
         persist?: false,
         provider_restart_backoff_base_ms: 30_000,
         provider_restart_backoff_max_ms: 30_000,
         provider_restart_max_attempts: 3}
      )

    assert_receive {:flaky_start_attempt, 1}
    state = await_provider_startup(session)
    {timer_ref, token} = ProviderLifecycle.retry_timer(state.provider)
    original_id = Session.session_id(session)

    assert :ok =
             SessionStore.save(
               %{
                 id: "failed-detached-restore",
                 model_name: "custom-model",
                 provider_name: "custom",
                 messages: [],
                 continuation: MingaAgent.Session.Continuation.new(),
                 usage: %TurnUsage{}
               },
               dir
             )

    assert {:error, {:provider_model_restore_failed, _reason}} =
             Session.load_session(session, "failed-detached-restore")

    assert_receive {:flaky_start_attempt, 2}
    assert Session.session_id(session) == original_id
    assert is_integer(Process.read_timer(timer_ref))
    Agent.update(tracker, &%{&1 | failures_remaining: 0})
    send(session, {:start_provider, token})
    assert_receive {:flaky_start_attempt, 3}
    assert_receive {:flaky_provider_started, provider}
    await_provider_startup(session)
    assert Session.get_provider(session) == provider
  end

  test "held credential discovery leaves Session queries and prompt refusal responsive" do
    {session, _sequence} = start_held_discovery_session()
    assert_receive {:credential_probe_started, 1, worker}, 1_000

    assert Session.status(session) == :idle

    assert %{credential_readiness: :checking, credentials_configured: false} =
             Session.editor_snapshot(session)

    messages = Session.messages(session)

    assert {:error, :credential_discovery_pending} =
             Session.send_prompt(session, "draft must remain with caller")

    assert Session.messages(session) == messages

    assert :ok = Session.subscribe(session, self())
    assert_receive {:agent_event, ^session, {:credentials_status, :checking}}

    send(worker, {:credential_probe_result, {:unavailable, :held_open}})
    assert_receive {:agent_event, ^session, {:credentials_status, :unconfigured}}, 1_000
  end

  test "model change invalidates a late discovery result and keeps only the newest worker" do
    {session, _sequence} = start_held_discovery_session()
    assert_receive {:credential_probe_started, 1, first_worker}, 1_000
    first_monitor = Process.monitor(first_worker)

    first_state = :sys.get_state(session)
    {:running, first_request, first_task, _timer_ref} = first_state.credential_availability.phase

    assert {:pending, :credential_discovery} =
             Session.set_model(session, "ollama:llama3")

    assert_receive {:DOWN, ^first_monitor, :process, ^first_worker, :killed}, 1_000
    assert_receive {:credential_probe_started, 2, second_worker}, 1_000

    send(session, {first_task.ref, {first_request.token, :available}})
    assert Session.editor_snapshot(session).credential_readiness == :checking
    assert Session.get_provider(session) == nil

    assert :ok = Session.subscribe(session, self())
    assert_receive {:agent_event, ^session, {:credentials_status, :checking}}

    send(second_worker, {:credential_probe_result, {:unavailable, :newest_result}})
    assert_receive {:agent_event, ^session, {:credentials_status, :unconfigured}}, 1_000
    assert Session.get_provider(session) == nil
  end

  test "new_session stops and replaces a held probe with the new logical session identity" do
    {session, _sequence} = start_held_discovery_session()
    assert_receive {:credential_probe_started, 1, first_worker}, 1_000
    first_monitor = Process.monitor(first_worker)
    old_state = :sys.get_state(session)
    {:running, old_request, old_task, _timer_ref} = old_state.credential_availability.phase
    old_session_id = old_state.session_id

    assert :ok = Session.new_session(session)
    assert_receive {:DOWN, ^first_monitor, :process, ^first_worker, :killed}, 1_000
    assert_receive {:credential_probe_started, 2, second_worker}, 1_000

    new_state = :sys.get_state(session)
    {:running, new_request, _new_task, _new_timer_ref} = new_state.credential_availability.phase
    refute new_state.session_id == old_session_id
    assert new_request.session_id == new_state.session_id

    send(session, {old_task.ref, {old_request.token, :available}})
    assert Session.editor_snapshot(session).credential_readiness == :checking
    send(second_worker, {:credential_probe_result, {:unavailable, :current_session}})
  end

  @tag :tmp_dir
  test "load_session validates a saved local route before replacing the active session", %{
    tmp_dir: dir
  } do
    assert :ok =
             SessionStore.save(
               %{
                 id: "loaded-logical-session",
                 timestamp: "2026-09-16T00:00:00Z",
                 model_name: "ollama:loaded",
                 provider_name: "ollama",
                 messages: [{:system, "Loaded", :info}],
                 continuation: MingaAgent.Session.Continuation.new(),
                 usage: %TurnUsage{}
               },
               dir
             )

    {session, _sequence} =
      start_held_discovery_session(session_store_dir: dir, persist?: false)

    assert_receive {:credential_probe_started, 1, active_worker}, 1_000
    active_monitor = Process.monitor(active_worker)
    active_session_id = Session.session_id(session)

    restore = Task.async(fn -> Session.load_session(session, "loaded-logical-session") end)
    assert_receive {:credential_probe_started, 2, restore_worker}, 1_000

    assert Session.session_id(session) == active_session_id
    refute_receive {:DOWN, ^active_monitor, :process, ^active_worker, _reason}, 50

    send(restore_worker, {:credential_probe_result, :available})
    assert Task.await(restore, 5_000) == :ok
    assert_receive {:DOWN, ^active_monitor, :process, ^active_worker, :killed}, 1_000

    assert Session.session_id(session) == "loaded-logical-session"
    assert Session.editor_snapshot(session).credential_readiness == :configured
    refute AvailabilityCheck.checking?(:sys.get_state(session).credential_availability)
  end

  @tag :tmp_dir
  test "failed saved local validation keeps the current session and route", %{tmp_dir: dir} do
    assert :ok =
             SessionStore.save(
               %{
                 id: "unavailable-local-session",
                 timestamp: "2026-09-16T00:00:00Z",
                 model_name: "ollama:loaded",
                 provider_name: "ollama",
                 messages: [{:system, "Must not replace current", :info}],
                 continuation: MingaAgent.Session.Continuation.new(),
                 usage: %TurnUsage{}
               },
               dir
             )

    {session, provider} =
      start_running_held_model_session(false, session_store_dir: dir, persist?: false)

    current_session_id = Session.session_id(session)
    assert {:ok, current_provider} = Native.get_state(provider)

    restore = Task.async(fn -> Session.load_session(session, "unavailable-local-session") end)
    assert_receive {:credential_probe_started, 1, restore_worker}, 1_000
    send(restore_worker, {:credential_probe_result, {:unavailable, :offline}})

    assert {:error, {:model_selection_correction_required, message}} =
             Task.await(restore, 5_000)

    assert message =~ "Start Ollama"
    assert Session.session_id(session) == current_session_id
    assert {:ok, after_rejection} = Native.get_state(provider)
    assert after_rejection.model_selection == current_provider.model_selection
  end

  test "repeated refreshes retain only one active discovery worker" do
    {session, _sequence} = start_held_discovery_session()
    assert_receive {:credential_probe_started, 1, first_worker}, 1_000
    first_monitor = Process.monitor(first_worker)

    assert :ok = Session.refresh_credentials(session)
    assert_receive {:DOWN, ^first_monitor, :process, ^first_worker, :killed}, 1_000
    assert_receive {:credential_probe_started, 2, second_worker}, 1_000
    second_monitor = Process.monitor(second_worker)

    assert :ok = Session.refresh_credentials(session)
    assert_receive {:DOWN, ^second_monitor, :process, ^second_worker, :killed}, 1_000
    assert_receive {:credential_probe_started, 3, third_worker}, 1_000

    state = :sys.get_state(session)
    {:running, _request, task, _timer_ref} = state.credential_availability.phase
    assert task.pid == third_worker
    refute Process.alive?(first_worker)
    refute Process.alive?(second_worker)
    assert Process.alive?(third_worker)

    send(third_worker, {:credential_probe_result, {:unavailable, :done}})
  end

  test "selecting a newly available exact profile invalidates held discovery before its late result" do
    {checker, credentials_configured_fn} = start_credential_checker(false)

    credentials_snapshot_fn = fn ->
      sources =
        if credentials_configured_fn.(),
          do: %{"anthropic" => :env},
          else: %{}

      CredentialSnapshot.new(sources, nil, "http://ollama.test")
    end

    {session, _sequence} =
      start_held_discovery_session(credentials_snapshot_fn: credentials_snapshot_fn)

    assert_receive {:credential_probe_started, 1, worker}, 1_000
    worker_monitor = Process.monitor(worker)
    first_state = :sys.get_state(session)
    {:running, first_request, first_task, _timer_ref} = first_state.credential_availability.phase

    Agent.update(checker, fn _configured? -> true end)
    assert :ok = Session.set_model(session, "anthropic:claude-sonnet-4-20250514")
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    assert :configured = Session.editor_snapshot(session).credential_readiness

    send(session, {first_task.ref, {first_request.token, {:unavailable, :late_result}}})
    assert :configured = Session.editor_snapshot(session).credential_readiness
  end

  test "credential discovery timeout kills the worker and settles readiness" do
    {session, _sequence} = start_held_discovery_session()
    assert_receive {:credential_probe_started, 1, worker}, 1_000
    worker_monitor = Process.monitor(worker)

    assert :ok = Session.subscribe(session, self())
    assert_receive {:agent_event, ^session, {:credentials_status, :checking}}

    state = :sys.get_state(session)
    {:running, request, _task, _timer_ref} = state.credential_availability.phase
    send(session, {:credential_probe_timeout, request.token})

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
    assert_receive {:agent_event, ^session, {:credentials_status, :unconfigured}}, 1_000
    refute AvailabilityCheck.checking?(:sys.get_state(session).credential_availability)
  end

  test "credential discovery worker crash settles readiness" do
    {session, _sequence} = start_held_discovery_session()
    assert_receive {:credential_probe_started, 1, worker}, 1_000

    assert :ok = Session.subscribe(session, self())
    assert_receive {:agent_event, ^session, {:credentials_status, :checking}}

    send(worker, :crash_credential_probe)
    assert_receive {:agent_event, ^session, {:credentials_status, :unconfigured}}, 1_000
    refute AvailabilityCheck.checking?(:sys.get_state(session).credential_availability)
  end

  test "Session shutdown reclaims its credential discovery worker" do
    {session, _sequence} = start_held_discovery_session()
    assert_receive {:credential_probe_started, 1, worker}, 1_000
    worker_monitor = Process.monitor(worker)

    :ok = GenServer.stop(session)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
  end

  test "abrupt Session death reclaims its credential discovery worker" do
    {session, _sequence} = start_held_discovery_session()
    assert_receive {:credential_probe_started, 1, worker}, 1_000
    session_monitor = Process.monitor(session)
    worker_monitor = Process.monitor(worker)

    Process.exit(session, :kill)

    assert_receive {:DOWN, ^session_monitor, :process, ^session, :killed}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000
  end

  test "current local discovery activates the declared exact route" do
    {session, _sequence} =
      start_held_discovery_session(
        provider_opts: [
          model: "ollama:llama3",
          skip_api_key_env: true,
          model_resolver_opts: recovery_model_opts()
        ]
      )

    assert_receive {:credential_probe_started, 1, worker}, 1_000
    assert :ok = Session.subscribe(session, self())
    assert_receive {:agent_event, ^session, {:credentials_status, :checking}}

    send(worker, {:credential_probe_result, :available})
    await_provider_startup(session)
    assert_receive {:agent_event, ^session, {:credentials_status, :configured}}
    assert {:ok, provider_state} = Native.get_state(Session.get_provider(session))
    assert provider_state.model_selection.route.execution.provider_model_id == "llama3"
    assert provider_state.model_selection.route.execution.base_url == "http://ollama.test"
  end

  test "failed credential worker startup settles instead of leaving checking state" do
    session =
      start_supervised!(
        {Session,
         provider: Native,
         provider_opts: [model: AgentConfig.unconfigured_model(), skip_api_key_env: true],
         credentials_snapshot_fn: &empty_credential_snapshot/0,
         credential_task_supervisor: :missing_credential_task_supervisor}
      )

    assert %{credential_readiness: :unconfigured, credentials_configured: false} =
             Session.editor_snapshot(session)
  end

  test "an exact API profile must become available before its route can activate" do
    {session, checker} =
      start_session(
        [provider: Native, provider_opts: [model: AgentConfig.unconfigured_model()]],
        false
      )

    assert Session.get_provider(session) == nil
    assert {:error, :credentials_not_configured} = Session.send_prompt(session, "draft prompt")

    assert {:error, message} =
             Session.set_model(session, "anthropic:claude-sonnet-4-20250514")

    assert message =~ "Credential profile"
    assert Session.get_provider(session) == nil

    Agent.update(checker, fn _configured? -> true end)
    assert :ok = Session.set_model(session, "anthropic:claude-sonnet-4-20250514")
    assert Session.editor_snapshot(session).credential_readiness == :configured
    assert {:ok, selected} = Native.get_state(Session.get_provider(session))
    assert selected.model_selection.credential.provider == "anthropic"
    assert selected.model_selection.credential.source == :env
  end

  test "an invalid initial model can be corrected with an exact legacy selection" do
    {session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: "anthropic:missing-model"]],
        true
      )

    assert Session.get_provider(session) == nil
    # set_model/2 starts the provider synchronously in handle_call, so pass a
    # generous timeout rather than racing the default 5s under suite load.
    assert :ok = Session.set_model(session, "claude-opus-4-20250514@anthropic", @startup_timeout)
    assert is_pid(Session.get_provider(session))

    {:ok, provider_state} = Native.get_state(Session.get_provider(session))

    assert provider_state.model_selection.route.execution.provider_model_id ==
             "claude-opus-4-20250514"

    assert provider_state.model_selection.credential.provider == "anthropic"
    assert Session.subagent_context(session).provider_name == "anthropic"
  end

  @tag :tmp_dir
  test "current discovery emits and saves the accepted exact route only after activation", %{
    tmp_dir: dir
  } do
    {session, provider} =
      start_running_held_model_session(false, session_store_dir: dir)

    assert {:ok, initial} = Native.get_state(provider)
    assert :ok = Session.subscribe(session, self())
    assert_receive {:agent_event, ^session, {:credentials_status, :configured}}

    assert {:pending, :credential_discovery} = Session.set_model(session, "ollama:model-b")
    assert_receive {:credential_probe_started, 1, worker}, 1_000
    assert_receive {:agent_event, ^session, {:credentials_status, :configured}}
    assert {:ok, current} = Native.get_state(provider)
    assert current.model_selection == initial.model_selection

    send(worker, {:credential_probe_result, :available})
    assert_receive {:agent_event, ^session, {:credentials_status, :configured}}, 1_000

    assert_receive {:agent_event, ^session, {:model_selection_changed, selection}}, 1_000
    assert selection.route.model_provider == "ollama"
    assert selection.route.execution.provider_model_id == "model-b"

    assert {:ok, selected} = Native.get_state(provider)
    assert selected.model_selection == selection

    saved =
      await_saved_selection(
        Session.session_id(session),
        dir,
        MingaAgent.ModelSelection.id(selection)
      )

    assert MingaAgent.ModelSelection.id(saved.model_selection) ==
             MingaAgent.ModelSelection.id(selection)
  end

  test "a stale successful discovery never replaces the active route with an obsolete pending route" do
    {session, provider} = start_running_held_model_session()
    assert {:ok, initial} = Native.get_state(provider)
    assert {:pending, :credential_discovery} = Session.set_model(session, "ollama:model-b")
    assert_receive {:credential_probe_started, 1, first_worker}, 1_000
    first_monitor = Process.monitor(first_worker)
    first_state = :sys.get_state(session)
    {:running, first_request, first_task, _timer_ref} = first_state.credential_availability.phase

    assert {:pending, :credential_discovery} = Session.set_model(session, "ollama:model-c")
    assert_receive {:credential_probe_started, 2, second_worker}, 1_000
    assert_receive {:DOWN, ^first_monitor, :process, ^first_worker, :killed}, 1_000

    send(session, {first_task.ref, {first_request.token, :available}})
    assert Session.editor_snapshot(session).credential_readiness == :configured
    assert {:ok, current} = Native.get_state(provider)
    assert current.model_selection == initial.model_selection
    send(second_worker, {:credential_probe_result, {:unavailable, :newest}})
  end

  test "an unavailable current discovery rejects the candidate and preserves the active route" do
    {session, provider} = start_running_held_model_session()
    assert {:ok, initial} = Native.get_state(provider)
    assert :ok = Session.subscribe(session, self())
    assert_receive {:agent_event, ^session, {:credentials_status, :configured}}

    assert {:pending, :credential_discovery} = Session.set_model(session, "ollama:model-b")
    assert_receive {:credential_probe_started, 1, worker}, 1_000
    assert_receive {:agent_event, ^session, {:credentials_status, :configured}}

    send(worker, {:credential_probe_result, {:unavailable, :offline}})
    assert_receive {:agent_event, ^session, {:credentials_status, :configured}}, 1_000

    assert_receive {:agent_event, ^session, {:model_selection_rejected, candidate, message}},
                   1_000

    assert candidate.route.execution.provider_model_id == "model-b"
    assert message =~ "Start Ollama"
    assert {:ok, current} = Native.get_state(provider)
    assert current.model_selection == initial.model_selection
  end

  test "an unavailable candidate does not disable a still-configured active profile" do
    {session, provider} = start_running_held_model_session(true)
    assert {:ok, initial} = Native.get_state(provider)
    assert {:pending, :credential_discovery} = Session.set_model(session, "ollama:model-b")
    assert_receive {:credential_probe_started, 1, worker}, 1_000
    assert :ok = Session.subscribe(session, self())
    assert_receive {:agent_event, ^session, {:credentials_status, :configured}}

    send(worker, {:credential_probe_result, {:unavailable, :offline}})
    assert_receive {:agent_event, ^session, {:credentials_status, :configured}}, 1_000
    assert {:ok, current} = Native.get_state(provider)
    assert current.model_selection == initial.model_selection
  end

  test "set_model/2 reports pending discovery even when a provider is already running" do
    {session, checker} =
      start_session(
        [provider: Native, provider_opts: [model: "anthropic:claude-sonnet-4-20250514"]],
        true
      )

    assert is_pid(Session.get_provider(session))
    Agent.update(checker, fn _configured? -> false end)

    assert {:pending, :credential_discovery} =
             Session.set_model(session, "ollama:llama3")

    assert_receive {:credential_probe_started, worker}, 1_000
    monitor = Process.monitor(worker)
    send(worker, {:release_credential_probe, self()})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
  end

  test "subagent_context uses session provider metadata for native providers" do
    {session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: "claude-opus-4-20250514@anthropic"]],
        true
      )

    assert is_pid(Session.get_provider(session))
    assert Session.subagent_context(session).provider_name == "anthropic"
  end

  test "set_model/2 returns startup errors when refresh triggers a failing provider" do
    {checker, credentials_configured_fn} = start_credential_checker(false)

    {:ok, session} =
      Session.start_link(
        provider: FailingProvider,
        provider_opts: [model: AgentConfig.unconfigured_model(), skip_api_key_env: true],
        credentials_configured_fn: credentials_configured_fn
      )

    Agent.update(checker, fn _ -> true end)

    assert {:error, message} = Session.set_model(session, "anthropic:claude-sonnet-4-20250514")
    assert message =~ "Failed to start agent: boom"
    assert message =~ "Press Ctrl-C to retry now"

    assert Session.get_provider(session) == nil
  end

  test "provider start failures retry with backoff and recover" do
    {:ok, tracker} = Agent.start_link(fn -> %{attempts: 0, failures_remaining: 1} end)

    {:ok, session} =
      Session.start_link(
        provider: FlakyStartProvider,
        provider_opts: [test_pid: self(), tracker: tracker],
        provider_restart_backoff_base_ms: 1,
        provider_restart_backoff_max_ms: 1,
        provider_restart_max_attempts: 3
      )

    on_exit(fn ->
      Process.exit(session, :kill)
      Process.exit(tracker, :kill)
    end)

    assert_receive {:flaky_start_attempt, 1}, 1_000
    assert_receive {:flaky_start_attempt, 2}, 1_000
    assert_receive {:flaky_provider_started, provider}, 1_000
    await_provider_startup(session)
    assert Session.get_provider(session) == provider
    assert Session.status(session) == :idle
  end

  test "starting early cancels the installed provider retry timer" do
    {:ok, tracker} = Agent.start_link(fn -> %{attempts: 0, failures_remaining: :always} end)

    {:ok, session} =
      Session.start_link(
        provider: FlakyStartProvider,
        provider_opts: [test_pid: self(), tracker: tracker],
        provider_restart_backoff_base_ms: 30_000,
        provider_restart_backoff_max_ms: 30_000,
        provider_restart_max_attempts: 3
      )

    on_exit(fn ->
      Process.exit(session, :kill)
      Process.exit(tracker, :kill)
    end)

    assert_receive {:flaky_start_attempt, 1}, 1_000
    state = await_provider_startup(session)
    assert {timer_ref, _token} = ProviderLifecycle.retry_timer(state.provider)
    assert is_integer(Process.read_timer(timer_ref))

    assert {:error, _reason} =
             Session.set_model(session, "anthropic:test", @startup_timeout)

    assert_receive {:flaky_start_attempt, 2}, 1_000
    assert Process.read_timer(timer_ref) == false
  end

  test "repeated provider crashes back off and stop after the configured cap" do
    {:ok, session} =
      Session.start_link(
        provider: CrashableProvider,
        provider_opts: [test_pid: self()],
        provider_restart_backoff_base_ms: 1,
        provider_restart_backoff_max_ms: 1,
        provider_restart_max_attempts: 2
      )

    on_exit(fn -> Process.exit(session, :kill) end)

    assert :ok = Session.subscribe(session)

    assert_receive {:crashable_provider_started, provider1}, 1_000
    Process.exit(provider1, :kill)
    assert_receive {:crashable_provider_started, provider2}, 1_000
    Process.exit(provider2, :kill)
    assert_receive {:crashable_provider_started, provider3}, 1_000
    Process.exit(provider3, :kill)

    assert_snapshot_error(session, "Automatic restart stopped")

    refute_receive {:crashable_provider_started, _provider4}, 50
  end

  test "the running lifecycle owns the provider's only Session monitor" do
    {:ok, session} =
      Session.start_link(
        provider: CrashableProvider,
        provider_opts: [test_pid: self()],
        provider_restart_backoff_base_ms: 30_000,
        provider_restart_backoff_max_ms: 30_000
      )

    on_exit(fn -> Process.exit(session, :kill) end)

    assert_receive {:crashable_provider_started, provider}, 1_000
    state = await_provider_startup(session)
    monitor_ref = ProviderLifecycle.monitor_ref(state.provider)

    assert is_reference(monitor_ref)
    assert ProviderLifecycle.pid(state.provider) == provider
    assert {:monitors, monitors} = Process.info(session, :monitors)
    assert Enum.count(monitors, &(&1 == {:process, provider})) == 1
  end

  test "a provider PID with the wrong monitor reference cannot change provider or subscriber ownership" do
    {:ok, session} =
      Session.start_link(
        provider: CrashableProvider,
        provider_opts: [test_pid: self()],
        provider_restart_backoff_base_ms: 30_000,
        provider_restart_backoff_max_ms: 30_000
      )

    on_exit(fn -> Process.exit(session, :kill) end)

    assert :ok = Session.subscribe(session)
    assert_receive {:crashable_provider_started, provider}, 1_000
    original = await_provider_startup(session).provider
    original_ref = ProviderLifecycle.monitor_ref(original)

    send(session, {:DOWN, make_ref(), :process, provider, :forged})
    assert Session.get_provider(session) == provider

    settled = await_provider_startup(session).provider
    assert ProviderLifecycle.monitor_ref(settled) == original_ref
    assert ProviderLifecycle.retry_attempts(settled) == 0
    assert Session.subscriber_role(session, self()) == :driver
  end

  test "a stale provider notification cannot stop its replacement or spend another retry" do
    {:ok, session} =
      Session.start_link(
        provider: CrashableProvider,
        provider_opts: [test_pid: self()],
        provider_restart_backoff_base_ms: 1,
        provider_restart_backoff_max_ms: 1
      )

    on_exit(fn -> Process.exit(session, :kill) end)

    assert :ok = Session.subscribe(session)
    assert_receive {:crashable_provider_started, old_provider}, 1_000
    old_lifecycle = await_provider_startup(session).provider
    old_ref = ProviderLifecycle.monitor_ref(old_lifecycle)

    Process.exit(old_provider, :kill)
    assert_receive {:crashable_provider_started, replacement}, 1_000
    replacement_lifecycle = await_provider_startup(session).provider
    replacement_ref = ProviderLifecycle.monitor_ref(replacement_lifecycle)

    send(session, {:DOWN, old_ref, :process, old_provider, :late})
    assert Session.get_provider(session) == replacement

    settled = await_provider_startup(session).provider
    assert ProviderLifecycle.monitor_ref(settled) == replacement_ref
    assert ProviderLifecycle.retry_attempts(settled) == 1
    assert Session.subscriber_role(session, self()) == :driver
  end

  for notification_order <- [:exit_first, :down_first] do
    test "linked startup notifications are handled once when #{notification_order}", %{} do
      order = unquote(notification_order)

      {:ok, session} =
        Session.start_link(
          provider: CrashableProvider,
          provider_opts: [test_pid: self()],
          provider_restart_backoff_base_ms: 30_000,
          provider_restart_backoff_max_ms: 30_000
        )

      on_exit(fn -> Process.exit(session, :kill) end)

      assert_receive {:crashable_provider_started, provider}, 1_000
      lifecycle = await_provider_startup(session).provider
      provider_ref = ProviderLifecycle.monitor_ref(lifecycle)
      test_ref = Process.monitor(provider)

      :ok = :sys.suspend(session)
      queue_provider_death_notifications(order, session, provider, test_ref)

      :ok = :sys.resume(session)
      assert Session.get_provider(session) == nil

      state = await_provider_startup(session)
      assert ProviderLifecycle.phase(state.provider) == :retrying
      assert ProviderLifecycle.retry_attempts(state.provider) == 1

      assert {:messages, messages} = Process.info(session, :messages)

      refute Enum.any?(messages, fn
               {:DOWN, ^provider_ref, :process, ^provider, _reason} -> true
               {:EXIT, ^provider, _reason} -> true
               _message -> false
             end)
    end
  end

  defp queue_provider_death_notifications(:exit_first, session, provider, test_ref) do
    send(session, {:EXIT, provider, :startup_crash})
    Process.exit(provider, :kill)
    assert_receive {:DOWN, ^test_ref, :process, ^provider, :killed}
    :ok
  end

  defp queue_provider_death_notifications(:down_first, session, provider, test_ref) do
    Process.exit(provider, :kill)
    assert_receive {:DOWN, ^test_ref, :process, ^provider, :killed}
    send(session, {:EXIT, provider, :startup_crash})
    :ok
  end

  test "restart_provider/1 recovers manually after automatic start retries are exhausted" do
    {:ok, tracker} = Agent.start_link(fn -> %{attempts: 0, failures_remaining: :always} end)

    {:ok, session} =
      Session.start_link(
        provider: FlakyStartProvider,
        provider_opts: [test_pid: self(), tracker: tracker],
        provider_restart_backoff_base_ms: 1,
        provider_restart_backoff_max_ms: 1,
        provider_restart_max_attempts: 1
      )

    on_exit(fn ->
      Process.exit(session, :kill)
      Process.exit(tracker, :kill)
    end)

    assert :ok = Session.subscribe(session)
    assert_receive {:flaky_start_attempt, 1}, 1_000
    assert_receive {:flaky_start_attempt, 2}, 1_000

    assert_snapshot_error(session, "Automatic restart stopped")

    Agent.update(tracker, &%{&1 | failures_remaining: 0})

    assert :ok = Session.restart_provider(session)
    assert_receive {:flaky_start_attempt, 3}, 1_000
    assert_receive {:flaky_provider_started, provider}, 1_000
    assert Session.get_provider(session) == provider
    assert Session.status(session) == :idle
  end

  test "custom providers still start when the top-level model name is unknown" do
    {session, _checker} =
      start_session(
        [provider: StubProvider, provider_opts: [model: AgentConfig.unconfigured_model()]],
        false
      )

    assert is_pid(Session.get_provider(session))
  end

  test "subscribe/2 sends the current credentials status to new subscribers" do
    {unconfigured_session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: AgentConfig.unconfigured_model()]],
        false
      )

    assert :ok = Session.subscribe(unconfigured_session, self())
    assert_receive {:agent_event, ^unconfigured_session, {:credentials_status, :unconfigured}}

    {configured_session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: "anthropic:claude-sonnet-4-20250514"]],
        true
      )

    assert :ok = Session.subscribe(configured_session, self())
    assert_receive {:agent_event, ^configured_session, {:credentials_status, :configured}}
  end

  test "missing explicit remote credentials do not fall back to Ollama discovery" do
    test_pid = self()

    session =
      start_supervised!(
        {Session,
         provider: Native,
         provider_opts: [
           model: "anthropic:claude-sonnet-4-20250514",
           skip_api_key_env: true,
           model_resolver_opts: recovery_model_opts()
         ],
         credentials_snapshot_fn: &empty_credential_snapshot/0,
         credential_probe_fn: fn _snapshot ->
           send(test_pid, :unexpected_ollama_discovery)
           :available
         end}
      )

    :sys.get_state(session)
    refute_receive :unexpected_ollama_discovery, 50
    assert :ok = Session.refresh_credentials(session)
    :sys.get_state(session)
    refute_receive :unexpected_ollama_discovery, 50
    assert Session.get_provider(session) == nil
    assert Session.editor_snapshot(session).credential_readiness == :unconfigured

    assert Enum.any?(Session.messages(session), fn
             {:system, message, :error} ->
               message =~ "Model selection needs correction" and
                 message =~ "Credential profile"

             _other ->
               false
           end)
  end

  @tag :tmp_dir
  test "validated remote restore starts a detached native provider", %{tmp_dir: dir} do
    ready_snapshot =
      CredentialSnapshot.new(%{"anthropic" => :env}, nil, "http://ollama.test")

    resolver_opts =
      recovery_model_opts()
      |> Keyword.put(:credential_snapshot, ready_snapshot)

    assert {:ok, selection} =
             ModelResolver.resolve("anthropic:claude-sonnet-4-20250514", resolver_opts)

    assert :ok =
             SessionStore.save(
               %{
                 id: "remote-restore",
                 timestamp: "2026-09-16T00:00:00Z",
                 model_name: MingaAgent.ModelSelection.id(selection),
                 provider_name: "anthropic",
                 model_selection: selection,
                 messages: [{:system, "Remote restored", :info}],
                 continuation: MingaAgent.Session.Continuation.new(),
                 usage: %TurnUsage{}
               },
               dir
             )

    snapshot =
      {Agent, fn -> empty_credential_snapshot() end}
      |> Supervisor.child_spec(id: {:restore_snapshot, make_ref()})
      |> start_supervised!()

    session =
      start_supervised!(
        {Session,
         provider: Native,
         provider_opts: [
           model: "anthropic:claude-sonnet-4-20250514",
           skip_api_key_env: true,
           model_resolver_opts: recovery_model_opts()
         ],
         session_store_dir: dir,
         persist?: false,
         credentials_snapshot_fn: fn -> Agent.get(snapshot, & &1) end}
      )

    :sys.get_state(session)
    assert Session.get_provider(session) == nil
    Agent.update(snapshot, fn _old -> ready_snapshot end)

    assert :ok = Session.load_session(session, "remote-restore")
    assert is_pid(Session.get_provider(session))
    assert Session.model_selection(session) == selection
    assert Session.editor_snapshot(session).credential_readiness == :configured
  end

  test "a missing exact profile cannot replace the current local route or held discovery" do
    {session, _sequence} = start_held_discovery_session()
    assert_receive {:credential_probe_started, 1, worker}, 1_000
    initial_model = Session.metadata(session).model_name
    assert :ok = Session.subscribe(session, self())
    assert_receive {:agent_event, ^session, {:credentials_status, :checking}}

    assert {:error, message} =
             Session.set_model(session, "anthropic:claude-sonnet-4-20250514")

    assert message =~ "Credential profile"
    assert Session.metadata(session).model_name == initial_model
    assert Session.editor_snapshot(session).credential_readiness == :checking

    send(worker, {:credential_probe_result, {:unavailable, :selected_route_unavailable}})
    assert_receive {:agent_event, ^session, {:credentials_status, :unconfigured}}, 1_000
  end

  test "legacy provider options select the exact model and profile when top-level intent is absent or unconfigured" do
    for top_level_intent <- [nil, AgentConfig.unconfigured_model()] do
      opts = [
        provider: Native,
        provider_opts: [model: "anthropic:claude-sonnet-4-20250514"]
      ]

      opts =
        case top_level_intent do
          nil -> opts
          intent -> Keyword.put(opts, :model_name, intent)
        end

      {session, _checker} = start_session(opts, true)
      {:ok, provider_state} = Native.get_state(Session.get_provider(session))
      selection = provider_state.model_selection
      assert selection.route.execution.provider_model_id == "claude-sonnet-4-20250514"
      assert selection.credential.provider == "anthropic"
      assert selection.credential.source == :env
      assert Session.metadata(session).provider_name == "anthropic"
    end
  end

  defp await_saved_selection(session_id, dir, selection_id, attempts \\ 80)

  defp await_saved_selection(session_id, dir, selection_id, attempts) when attempts > 0 do
    case SessionStore.load(session_id, dir) do
      {:ok, %{model_selection: selection} = saved} ->
        if not is_nil(selection) and MingaAgent.ModelSelection.id(selection) == selection_id do
          saved
        else
          Process.sleep(25)
          await_saved_selection(session_id, dir, selection_id, attempts - 1)
        end

      {:error, _reason} ->
        Process.sleep(25)
        await_saved_selection(session_id, dir, selection_id, attempts - 1)
    end
  end

  defp await_saved_selection(session_id, dir, selection_id, 0) do
    flunk(
      "session #{session_id} did not persist accepted model selection #{selection_id}: " <>
        inspect(SessionStore.load(session_id, dir))
    )
  end

  defp assert_snapshot_error(session, expected_text, attempts \\ 20)

  defp assert_snapshot_error(session, expected_text, attempts) when attempts > 0 do
    snapshot = Session.editor_snapshot(session)

    if is_binary(snapshot.error) and String.contains?(snapshot.error, expected_text) do
      :ok
    else
      assert_receive {:agent_event, ^session, _event}, 1_000
      assert_snapshot_error(session, expected_text, attempts - 1)
    end
  end

  defp assert_snapshot_error(session, expected_text, 0) do
    snapshot = Session.editor_snapshot(session)
    assert is_binary(snapshot.error) and String.contains?(snapshot.error, expected_text)
  end
end
