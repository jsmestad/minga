defmodule MingaAgent.Session.ProviderLifecycleTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.CodeLease
  alias MingaAgent.Session.ProviderLifecycle

  test "normal lifecycle keeps provider identity, monitor, lease, and retry state together" do
    lease = lease()
    monitor_ref = make_ref()
    lifecycle = lifecycle(lease: lease)

    assert {:start, starting, nil} = ProviderLifecycle.start(lifecycle)
    assert {:ok, running} = ProviderLifecycle.attach(starting, self(), monitor_ref)

    assert ProviderLifecycle.phase(running) == :running
    assert ProviderLifecycle.pid(running) == self()
    assert ProviderLifecycle.monitor_ref(running) == monitor_ref
    assert ProviderLifecycle.lease(running) == lease

    replaced =
      ProviderLifecycle.replace(
        running,
        "openai:gpt-5",
        "openai",
        model: "openai:gpt-5",
        provider: "openai"
      )

    assert ProviderLifecycle.pid(replaced) == self()
    assert ProviderLifecycle.monitor_ref(replaced) == monitor_ref
    assert ProviderLifecycle.lease(replaced) == lease
    assert replaced.model_name == "openai:gpt-5"
    assert replaced.provider_name == "openai"
    assert replaced.opts[:model] == "openai:gpt-5"

    assert {:stop_provider, stopped, pid, ^monitor_ref, ^lease} =
             ProviderLifecycle.stop(replaced)

    assert pid == self()
    assert_stopped(stopped)
  end

  test "start is exhaustive and returns only a retry timer that must be cancelled" do
    phases = lifecycle_phases()
    running = phases.running
    retrying = phases.retrying

    assert {:active, ^running} = ProviderLifecycle.start(running)
    assert {:start, _starting, {timer_ref, token}} = ProviderLifecycle.start(retrying)
    assert {timer_ref, token} == ProviderLifecycle.retry_timer(retrying)

    for {_name, lifecycle} <- Map.drop(phases, [:running, :retrying]) do
      assert {:start, starting, nil} = ProviderLifecycle.start(lifecycle)
      assert ProviderLifecycle.phase(starting) == :starting
    end
  end

  test "lease installation and provider attachment accept only the starting phase" do
    phases = lifecycle_phases()
    lease = lease()

    assert {:ok, leased} = ProviderLifecycle.install_lease(phases.starting, lease)
    assert ProviderLifecycle.lease(leased) == lease

    monitor_ref = make_ref()
    assert {:ok, running} = ProviderLifecycle.attach(leased, self(), monitor_ref)
    assert ProviderLifecycle.monitor_ref(running) == monitor_ref

    for {_name, lifecycle} <- Map.drop(phases, [:starting]) do
      assert {:invalid_phase, ^lifecycle} = ProviderLifecycle.install_lease(lifecycle, lease)

      assert {:invalid_phase, ^lifecycle} =
               ProviderLifecycle.attach(lifecycle, self(), make_ref())
    end
  end

  test "failure accepts startup and running phases and rejects every detached phase" do
    phases = lifecycle_phases()

    for name <- [:starting, :running] do
      lifecycle = Map.fetch!(phases, name)
      expected_lease = ProviderLifecycle.lease(lifecycle)

      assert {:failed, failed, ^expected_lease} = ProviderLifecycle.failure(lifecycle, :crashed)
      assert ProviderLifecycle.phase(failed) == :stopped
      assert ProviderLifecycle.failure_reason(failed) == :crashed
      assert ProviderLifecycle.lease(failed) == nil
    end

    for name <- [:stopped, :retrying, :terminal_failure] do
      lifecycle = Map.fetch!(phases, name)
      assert {:invalid_phase, ^lifecycle} = ProviderLifecycle.failure(lifecycle, :crashed)
    end
  end

  test "retry backoff advances only from stopped and exhausts at the configured cap" do
    phases = lifecycle_phases()
    stopped = failed_starting(phases.starting, :first)

    assert {:retry, first_retry, 10} = ProviderLifecycle.retry(stopped, :first, 1_000)
    assert ProviderLifecycle.retry_attempts(first_retry) == 1
    assert ProviderLifecycle.retry_window_started_at_ms(first_retry) == 1_000

    starting_again = retry_due(first_retry)
    stopped_again = failed_starting(starting_again, :second)
    assert {:retry, second_retry, 20} = ProviderLifecycle.retry(stopped_again, :second, 1_050)
    assert ProviderLifecycle.retry_attempts(second_retry) == 2

    starting_last = retry_due(second_retry)
    stopped_last = failed_starting(starting_last, :permanent)

    assert {:terminal_failure, terminal} =
             ProviderLifecycle.retry(stopped_last, :permanent, 1_075)

    assert ProviderLifecycle.terminal_failure?(terminal)
    assert ProviderLifecycle.failure_reason(terminal) == :permanent

    for name <- [:starting, :running, :retrying, :terminal_failure] do
      lifecycle = Map.fetch!(phases, name)
      assert {:invalid_phase, ^lifecycle} = ProviderLifecycle.retry(lifecycle, :failure, 1_000)
    end
  end

  test "retry count restarts when the backoff window expires" do
    {:start, starting, nil} = ProviderLifecycle.start(lifecycle())
    stopped = failed_starting(starting, :first)
    assert {:retry, first_retry, 10} = ProviderLifecycle.retry(stopped, :first, 1_000)

    stopped_later = first_retry |> retry_due() |> failed_starting(:later)

    assert {:retry, reset_retry, 10} =
             ProviderLifecycle.retry(stopped_later, :later, 2_001)

    assert ProviderLifecycle.retry_attempts(reset_retry) == 1
    assert ProviderLifecycle.retry_window_started_at_ms(reset_retry) == 2_001
  end

  test "retry timer installation and token consumption reject invalid and stale inputs" do
    phases = lifecycle_phases()
    timer_ref = make_ref()
    token = make_ref()

    assert {:ok, waiting} =
             ProviderLifecycle.install_retry_timer(phases.retrying, timer_ref, token)

    assert {:stale, ^waiting} = ProviderLifecycle.retry_due(waiting, make_ref())
    assert {:start, starting} = ProviderLifecycle.retry_due(waiting, token)
    assert ProviderLifecycle.phase(starting) == :starting
    assert ProviderLifecycle.retry_timer(starting) == nil

    for {_name, lifecycle} <- Map.drop(phases, [:retrying]) do
      assert {:invalid_phase, ^lifecycle} =
               ProviderLifecycle.install_retry_timer(lifecycle, make_ref(), make_ref())

      assert {:stale, ^lifecycle} = ProviderLifecycle.retry_due(lifecycle, make_ref())
    end
  end

  test "retry reset is exhaustive, preserves a running attachment, and exposes timer cancellation" do
    phases = lifecycle_phases()
    running = phases.running

    assert {:reset, reset_running, nil} = ProviderLifecycle.reset_retry(running)
    assert ProviderLifecycle.pid(reset_running) == ProviderLifecycle.pid(running)
    assert ProviderLifecycle.monitor_ref(reset_running) == ProviderLifecycle.monitor_ref(running)
    assert ProviderLifecycle.lease(reset_running) == ProviderLifecycle.lease(running)

    assert {:reset, reset_retrying, retry_timer} = ProviderLifecycle.reset_retry(phases.retrying)
    assert retry_timer == ProviderLifecycle.retry_timer(phases.retrying)
    assert_stopped(reset_retrying)

    for name <- [:stopped, :starting, :terminal_failure] do
      lifecycle = Map.fetch!(phases, name)
      expected_lease = ProviderLifecycle.lease(lifecycle)

      assert {:reset, reset, nil} = ProviderLifecycle.reset_retry(lifecycle)
      assert ProviderLifecycle.phase(reset) == :stopped
      assert ProviderLifecycle.lease(reset) == expected_lease
      assert ProviderLifecycle.retry_attempts(reset) == 0
      assert ProviderLifecycle.failure_reason(reset) == nil
    end
  end

  test "replace and stop are exhaustive across every phase" do
    for {name, lifecycle} <- lifecycle_phases() do
      replaced =
        ProviderLifecycle.replace(lifecycle, "new-model", "new-provider", model: "new-model")

      assert ProviderLifecycle.phase(replaced) == ProviderLifecycle.phase(lifecycle)
      assert replaced.model_name == "new-model"
      assert replaced.provider_name == "new-provider"

      case {name, ProviderLifecycle.stop(lifecycle)} do
        {:running, {:stop_provider, stopped, pid, monitor_ref, lease}} ->
          assert pid == ProviderLifecycle.pid(lifecycle)
          assert monitor_ref == ProviderLifecycle.monitor_ref(lifecycle)
          assert lease == ProviderLifecycle.lease(lifecycle)
          assert_stopped(stopped)

        {_detached, {:stop_detached, stopped, lease, retry_timer}} ->
          assert lease == ProviderLifecycle.lease(lifecycle)
          assert retry_timer == ProviderLifecycle.retry_timer(lifecycle)
          assert_stopped(stopped)
      end
    end
  end

  test "Session has one provider monitor path and no generic lifecycle effect interpreter" do
    session_source = File.read!("lib/minga_agent/session.ex")
    lifecycle_source = File.read!("lib/minga_agent/session/provider_lifecycle.ex")

    monitor_paths =
      Regex.scan(
        ~r/defp attach_provider\(state, pid\).*?Process\.monitor\(pid\)/s,
        session_source
      )

    assert [_provider_monitor_path] = monitor_paths

    assert session_source =~ "ProviderLifecycle.attach(state.provider, pid, monitor_ref)"
    refute session_source =~ ~r/defp await_provider_stop.*?Process\.monitor/s
    refute session_source =~ "perform_provider_effect"
    refute session_source =~ "install_provider_transition"
    refute lifecycle_source =~ "@type effect"
    refute lifecycle_source =~ "@type effects"
  end

  defp lifecycle(overrides \\ []) do
    [
      module: Minga.Test.StubProvider,
      id: "test",
      source: :config,
      provider_opts: [model: "anthropic:test"],
      model_name: "anthropic:test",
      provider_name: "anthropic",
      restart: [
        base_delay_ms: 10,
        max_delay_ms: 100,
        max_attempts: 2,
        window_ms: 1_000
      ]
    ]
    |> Keyword.merge(overrides)
    |> ProviderLifecycle.new()
  end

  defp lifecycle_phases do
    initial = lifecycle(lease: lease())
    {:start, starting, nil} = ProviderLifecycle.start(initial)
    {:ok, running} = ProviderLifecycle.attach(starting, self(), make_ref())
    stopped = failed_starting(starting, :failure)
    {:retry, retrying, _delay_ms} = ProviderLifecycle.retry(stopped, :failure, 1_000)
    {:ok, retrying} = ProviderLifecycle.install_retry_timer(retrying, make_ref(), make_ref())

    starting_again = retry_due(retrying)
    stopped_again = failed_starting(starting_again, :failure)
    {:retry, retrying_again, _delay_ms} = ProviderLifecycle.retry(stopped_again, :failure, 1_001)
    starting_last = retry_due(retrying_again)
    stopped_last = failed_starting(starting_last, :failure)
    {:terminal_failure, terminal} = ProviderLifecycle.retry(stopped_last, :failure, 1_002)

    %{
      stopped: initial,
      starting: starting,
      running: running,
      retrying: retrying,
      terminal_failure: terminal
    }
  end

  defp retry_due(retrying) do
    timer_ref = make_ref()
    token = make_ref()
    {:ok, waiting} = ProviderLifecycle.install_retry_timer(retrying, timer_ref, token)
    {:start, starting} = ProviderLifecycle.retry_due(waiting, token)
    starting
  end

  defp failed_starting(starting, reason) do
    {:failed, stopped, _lease} = ProviderLifecycle.failure(starting, reason)
    stopped
  end

  defp assert_stopped(lifecycle) do
    assert ProviderLifecycle.phase(lifecycle) == :stopped
    assert ProviderLifecycle.pid(lifecycle) == nil
    assert ProviderLifecycle.monitor_ref(lifecycle) == nil
    assert ProviderLifecycle.lease(lifecycle) == nil
    assert ProviderLifecycle.retry_attempts(lifecycle) == 0
    assert ProviderLifecycle.retry_timer(lifecycle) == nil
    assert ProviderLifecycle.failure_reason(lifecycle) == nil
  end

  defp lease do
    %CodeLease{
      id: make_ref(),
      server: self(),
      source: :config,
      module: Minga.Test.StubProvider,
      owner: self(),
      reason: :provider,
      started_at: 0
    }
  end
end
