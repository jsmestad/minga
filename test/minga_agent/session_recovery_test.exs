defmodule MingaAgent.SessionRecoveryTest do
  use ExUnit.Case, async: true

  alias Minga.Test.StubProvider
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.Providers.Native
  alias MingaAgent.Session
  alias MingaAgent.Session.ProviderLifecycle

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

    provider_opts =
      Keyword.get(opts, :provider_opts, [])
      |> Keyword.merge(skip_api_key_env: true)

    {:ok, session} =
      Session.start_link(
        opts
        |> Keyword.put(:provider_opts, provider_opts)
        |> Keyword.put(:credentials_configured_fn, credentials_configured_fn)
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
    def seed_messages(_pid, _messages), do: :ok

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
    def seed_messages(_pid, _messages), do: :ok

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
    def seed_messages(_pid, _messages), do: :ok

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: nil}}

    @impl GenServer
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:crashable_provider_started, self()})
      {:ok, %{test_pid: test_pid}}
    end
  end

  test "refresh_credentials/1 starts a provider only after credentials flip true and model is concrete" do
    {session, checker} =
      start_session(
        [provider: Native, provider_opts: [model: AgentConfig.unconfigured_model()]],
        false
      )

    assert Session.get_provider(session) == nil
    assert Session.editor_snapshot(session).credentials_configured == false
    assert {:error, :credentials_not_configured} = Session.send_prompt(session, "draft prompt")

    assert :ok = Session.set_model(session, "anthropic:claude-sonnet-4-20250514")
    assert Session.get_provider(session) == nil

    Agent.update(checker, fn _ -> true end)
    assert :ok = Session.refresh_credentials(session)
    # refresh_credentials/1 is a cast that starts the provider synchronously in
    # handle_cast; wait for that before reading provider-dependent state.
    await_provider_startup(session)
    assert Session.editor_snapshot(session).credentials_configured == true
    assert is_pid(Session.get_provider(session))
  end

  test "set_model/2 can recover a provider-less session when credentials already exist" do
    {session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: AgentConfig.unconfigured_model()]],
        true
      )

    assert Session.get_provider(session) == nil
    # set_model/2 starts the provider synchronously in handle_call, so pass a
    # generous timeout rather than racing the default 5s under suite load.
    assert :ok = Session.set_model(session, "claude-opus-4-20250514@anthropic", @startup_timeout)
    assert is_pid(Session.get_provider(session))

    metadata = Session.metadata(session)
    assert metadata.model_name == "claude-opus-4-20250514@anthropic"
    assert metadata.provider_name == "anthropic"
    assert Session.subagent_context(session).provider_name == "anthropic"
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
    assert_receive {:agent_event, ^unconfigured_session, {:credentials_status, false}}

    {configured_session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: "anthropic:claude-sonnet-4-20250514"]],
        true
      )

    assert :ok = Session.subscribe(configured_session, self())
    assert_receive {:agent_event, ^configured_session, {:credentials_status, true}}
  end

  test "set_model/2 updates provider metadata for provider-qualified models" do
    {session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: AgentConfig.unconfigured_model()]],
        false
      )

    assert :ok = Session.set_model(session, "anthropic:claude-sonnet-4-20250514")
    metadata = Session.metadata(session)

    assert metadata.model_name == "anthropic:claude-sonnet-4-20250514"
    assert metadata.provider_name == "anthropic"
    assert Session.subagent_context(session).provider_name == "anthropic"
  end

  test "provider opts seed the stored model name when top-level model_name is absent" do
    {session, _checker} =
      start_session(
        [provider: Native, provider_opts: [model: "anthropic:claude-sonnet-4-20250514"]],
        true
      )

    assert is_pid(Session.get_provider(session))
    assert Session.metadata(session).model_name == "anthropic:claude-sonnet-4-20250514"
    assert Session.metadata(session).provider_name == "anthropic"
  end

  test "provider opts still start when top-level model_name is unknown" do
    {session, _checker} =
      start_session(
        [
          provider: Native,
          model_name: AgentConfig.unconfigured_model(),
          provider_opts: [model: "anthropic:claude-sonnet-4-20250514"]
        ],
        true
      )

    assert is_pid(Session.get_provider(session))
    assert Session.metadata(session).model_name == "anthropic:claude-sonnet-4-20250514"
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
