defmodule MingaAgent.Session.ProviderLifecycleTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.CodeLease
  alias MingaAgent.Session.ProviderLifecycle

  test "normal lifecycle starts, attaches, replaces configuration, and stops" do
    lease = lease()
    lifecycle = lifecycle(lease: lease)

    assert {:start, starting, []} = ProviderLifecycle.start(lifecycle)
    assert ProviderLifecycle.phase(starting) == :starting
    assert ProviderLifecycle.pid(starting) == nil

    {running, []} = ProviderLifecycle.attach(starting, self())

    assert ProviderLifecycle.phase(running) == :running
    assert ProviderLifecycle.pid(running) == self()
    assert ProviderLifecycle.lease(running) == lease

    replaced =
      ProviderLifecycle.replace(
        running,
        "openai:gpt-5",
        "openai",
        model: "openai:gpt-5",
        provider: "openai"
      )

    assert ProviderLifecycle.phase(replaced) == :running
    assert ProviderLifecycle.pid(replaced) == self()
    assert ProviderLifecycle.lease(replaced) == lease
    assert replaced.model_name == "openai:gpt-5"
    assert replaced.provider_name == "openai"
    assert replaced.opts[:model] == "openai:gpt-5"

    {stopped, effects} = ProviderLifecycle.stop(replaced)
    assert effects == [{:stop_provider, self()}, {:release_lease, lease}]

    assert ProviderLifecycle.phase(stopped) == :stopped
    assert ProviderLifecycle.pid(stopped) == nil
    assert ProviderLifecycle.lease(stopped) == nil
    assert ProviderLifecycle.retry_attempts(stopped) == 0
    assert ProviderLifecycle.retry_timer(stopped) == nil
    assert ProviderLifecycle.failure_reason(stopped) == nil
  end

  test "start returns the active lifecycle when a provider is already attached" do
    {running, []} = ProviderLifecycle.attach(lifecycle(), self())

    assert {:active, ^running, []} = ProviderLifecycle.start(running)
  end

  test "a lease acquired during startup becomes lifecycle-owned before attachment" do
    assert {:start, starting, []} = ProviderLifecycle.start(lifecycle())
    lease = lease()

    assert {:ok, leased} = ProviderLifecycle.install_lease(starting, lease)
    assert ProviderLifecycle.lease(leased) == lease

    assert {running, []} = ProviderLifecycle.attach(leased, self())
    assert ProviderLifecycle.lease(running) == lease
  end

  test "failure and retry transitions back off until terminal exhaustion" do
    {failed, []} = ProviderLifecycle.failure(lifecycle(), :crashed)

    assert ProviderLifecycle.phase(failed) == :stopped
    assert ProviderLifecycle.pid(failed) == nil
    assert ProviderLifecycle.lease(failed) == nil
    assert ProviderLifecycle.failure_reason(failed) == :crashed

    assert {:retry, first_retry, 10, []} = ProviderLifecycle.retry(failed, :crashed, 1_000)
    assert ProviderLifecycle.phase(first_retry) == :retrying
    assert ProviderLifecycle.retry_attempts(first_retry) == 1
    assert ProviderLifecycle.retry_window_started_at_ms(first_retry) == 1_000

    timer_ref = make_ref()
    token = make_ref()
    {:ok, waiting} = ProviderLifecycle.install_retry_timer(first_retry, timer_ref, token)

    assert {:start, _early_start, [{:cancel_timer, ^timer_ref}]} =
             ProviderLifecycle.start(waiting)

    assert {:stale, ^waiting} = ProviderLifecycle.retry_due(waiting, make_ref())
    assert {:start, retrying_start} = ProviderLifecycle.retry_due(waiting, token)
    assert ProviderLifecycle.phase(retrying_start) == :starting
    assert ProviderLifecycle.retry_timer(retrying_start) == nil

    {failed_again, []} = ProviderLifecycle.failure(retrying_start, :still_crashed)

    assert {:retry, second_retry, 20, []} =
             ProviderLifecycle.retry(failed_again, :still_crashed, 1_050)

    assert ProviderLifecycle.retry_attempts(second_retry) == 2

    {failed_last, []} = ProviderLifecycle.failure(second_retry, :permanent)

    assert {:terminal_failure, terminal, []} =
             ProviderLifecycle.retry(failed_last, :permanent, 1_075)

    assert ProviderLifecycle.terminal_failure?(terminal)
    assert ProviderLifecycle.failure_reason(terminal) == :permanent
    assert ProviderLifecycle.retry_timer(terminal) == nil

    {reset, []} = ProviderLifecycle.reset_retry(terminal)

    refute ProviderLifecycle.terminal_failure?(reset)
    assert ProviderLifecycle.phase(reset) == :stopped
    assert ProviderLifecycle.retry_attempts(reset) == 0
    assert ProviderLifecycle.retry_window_started_at_ms(reset) == nil
    assert ProviderLifecycle.failure_reason(reset) == nil
  end

  test "retry reset preserves a lease acquired before provider startup" do
    lease = lease()
    lifecycle = lifecycle(lease: lease)

    {reset, []} = ProviderLifecycle.reset_retry(lifecycle)

    assert ProviderLifecycle.phase(reset) == :stopped
    assert ProviderLifecycle.pid(reset) == nil
    assert ProviderLifecycle.lease(reset) == lease

    assert {:start, starting, []} = ProviderLifecycle.start(reset)
    assert ProviderLifecycle.lease(starting) == lease
  end

  test "retry count restarts when the backoff window expires" do
    {failed, []} = ProviderLifecycle.failure(lifecycle(), :first)
    assert {:retry, first_retry, 10, []} = ProviderLifecycle.retry(failed, :first, 1_000)

    {failed_after_window, []} = ProviderLifecycle.failure(first_retry, :later)

    assert {:retry, reset_retry, 10, []} =
             ProviderLifecycle.retry(failed_after_window, :later, 2_001)

    assert ProviderLifecycle.retry_attempts(reset_retry) == 1
    assert ProviderLifecycle.retry_window_started_at_ms(reset_retry) == 2_001
  end

  test "failure, replacement, and stop are exhaustive across lifecycle phases" do
    phases = lifecycle_phases()

    Enum.each(phases, fn lifecycle ->
      {failed, _effects} = ProviderLifecycle.failure(lifecycle, :failure)
      assert ProviderLifecycle.phase(failed) == :stopped
      assert ProviderLifecycle.failure_reason(failed) == :failure

      replaced =
        ProviderLifecycle.replace(lifecycle, "new-model", "new-provider", model: "new-model")

      assert ProviderLifecycle.phase(replaced) == ProviderLifecycle.phase(lifecycle)
      assert replaced.model_name == "new-model"
      assert replaced.provider_name == "new-provider"

      {stopped, _effects} = ProviderLifecycle.stop(lifecycle)
      assert ProviderLifecycle.phase(stopped) == :stopped
      assert ProviderLifecycle.pid(stopped) == nil
      assert ProviderLifecycle.lease(stopped) == nil
      assert ProviderLifecycle.retry_timer(stopped) == nil
      assert ProviderLifecycle.failure_reason(stopped) == nil
    end)
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
    {:start, starting, []} = ProviderLifecycle.start(initial)
    {running, []} = ProviderLifecycle.attach(starting, self())
    {failed, _effects} = ProviderLifecycle.failure(running, :failure)
    {:retry, retrying, _delay_ms, []} = ProviderLifecycle.retry(failed, :failure, 1_000)
    timer_ref = make_ref()
    {:ok, retrying} = ProviderLifecycle.install_retry_timer(retrying, timer_ref, make_ref())

    {failed_again, [{:cancel_timer, ^timer_ref}]} =
      ProviderLifecycle.failure(retrying, :failure)

    {:retry, retrying_again, _delay_ms, []} =
      ProviderLifecycle.retry(failed_again, :failure, 1_001)

    {failed_last, []} = ProviderLifecycle.failure(retrying_again, :failure)

    {:terminal_failure, terminal, []} =
      ProviderLifecycle.retry(failed_last, :failure, 1_002)

    [initial, starting, running, retrying, terminal]
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
