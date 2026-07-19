defmodule MingaEditor.EffectSchedulerTest do
  @moduledoc "Deterministic lifecycle and resource-policy tests for generation-owned effects."

  use ExUnit.Case, async: true

  alias Minga.Project.Root
  alias Minga.Project.WorkspaceSnapshot
  alias Minga.Test.EffectOwner
  alias Minga.Test.EffectProbe
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.Effect.Request
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Effects.TodoSearch
  alias MingaEditor.GenerationSupervisor

  @effect_timeout 15_000

  test "TODO requests retain their typed Root through scheduler failure outcomes" do
    root = %Root{kind: :directory, path: "/missing/todo-search-root"}
    snapshot = WorkspaceSnapshot.activate(root)
    request = TodoSearch.request(snapshot, make_ref())
    scheduler = start_scheduler()

    assert request.resource == {:todo_search, root}
    assert request.effect.root == root
    assert request.effect.activation_id == snapshot.activation_id
    assert EffectScheduler.schedule(scheduler, request) == {:ok, request.id, :running}

    outcome = receive_candidate(scheduler, request.id, :failed)

    assert outcome.request.resource == {:todo_search, root}
    assert outcome.request.effect.root == root
    assert outcome.reason == "TODO search root rejected: not_a_directory"
    finalize_once(scheduler, outcome)
  end

  test "normal completion produces exactly one completed terminal outcome" do
    scheduler = start_scheduler()

    request =
      EffectProbe.request(self(), :normal, :resource, Policy.fifo(1), {:return, :done})
      |> with_timeout()

    assert EffectScheduler.schedule(scheduler, request) == {:ok, request.id, :running}
    assert_receive {:effect_started, :normal, _worker, [:normal]}
    outcome = receive_candidate(scheduler, request.id, :completed)
    assert outcome.result == :done
    assert :sys.get_state(scheduler).timers == %{}

    send(scheduler, {:effect_timeout, request.id})
    finalize_once(scheduler, outcome)
    assert EffectScheduler.cancel(scheduler, request.id) == {:error, :not_found}
  end

  test "duplicate request identity is rejected while its first admission is pending" do
    scheduler = start_scheduler()

    request =
      EffectProbe.request(self(), :duplicate, :resource, Policy.latest_wins(), {
        :return,
        :done
      })

    assert EffectScheduler.schedule(scheduler, request) == {:ok, request.id, :running}
    assert_receive {:effect_started, :duplicate, _worker, [:duplicate]}
    outcome = receive_candidate(scheduler, request.id, :completed)

    assert EffectScheduler.schedule(scheduler, request) == {:error, :already_admitted}
    assert EffectScheduler.stats(scheduler) == stats(1, 0, 0, 1, 1)

    finalize_once(scheduler, outcome)
    refute_received {:effect_started, :duplicate, _worker, _payloads}
  end

  test "raised and killed workers each produce one failed terminal outcome" do
    scheduler = start_scheduler()

    raised =
      EffectProbe.request(self(), :raised, :raised_resource, Policy.fifo(0), {:raise, "boom"})
      |> with_timeout()

    assert EffectScheduler.schedule(scheduler, raised) == {:ok, raised.id, :running}
    assert_receive {:effect_started, :raised, _raised_worker, [:raised]}
    raised_outcome = receive_candidate(scheduler, raised.id, :failed)
    assert match?({:worker_exit, {%RuntimeError{message: "boom"}, _stack}}, raised_outcome.reason)
    assert :sys.get_state(scheduler).timers == %{}
    finalize_once(scheduler, raised_outcome)

    killed =
      EffectProbe.request(self(), :killed, :killed_resource, Policy.fifo(0)) |> with_timeout()

    assert EffectScheduler.schedule(scheduler, killed) == {:ok, killed.id, :running}
    assert_receive {:effect_started, :killed, killed_worker, [:killed]}
    Process.exit(killed_worker, :kill)

    killed_outcome = receive_candidate(scheduler, killed.id, :failed)
    assert killed_outcome.reason == {:worker_exit, :killed}
    assert :sys.get_state(scheduler).timers == %{}
    finalize_once(scheduler, killed_outcome)
  end

  test "request timeout terminates the worker, cleans timer, and releases admission" do
    scheduler = start_scheduler()

    request = %{
      EffectProbe.request(self(), :timeout, :timeout_resource, Policy.fifo(0))
      | timeout_ms: 10
    }

    assert EffectScheduler.schedule(scheduler, request) == {:ok, request.id, :running}
    assert_receive {:effect_started, :timeout, worker, [:timeout]}, 1_000
    worker_monitor = Process.monitor(worker)

    outcome = receive_candidate(scheduler, request.id, :failed)
    assert outcome.reason == :timeout
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000

    finalize_once(scheduler, outcome)
    assert EffectScheduler.stats(scheduler) == stats(0, 0, 0, 0, 0)
  end

  test "timeout holds admission until apply, then advances the lane and cannot affect its successor" do
    scheduler = start_scheduler()
    policy = Policy.fifo(1)
    first = EffectProbe.request(self(), :timed_out, :shared_timeout, policy) |> with_timeout()
    second = EffectProbe.request(self(), :successor, :shared_timeout, policy) |> with_timeout()

    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, first)
    assert_receive {:effect_started, :timed_out, _worker, [:timed_out]}

    [%{running: %{task: first_task}}] =
      scheduler |> :sys.get_state() |> Map.fetch!(:lanes) |> Map.values()

    assert {:ok, _, :queued} = EffectScheduler.schedule(scheduler, second)
    send(scheduler, {:effect_timeout, first.id})

    outcome = receive_candidate(scheduler, first.id, :failed)
    assert outcome.reason == :timeout
    assert EffectScheduler.stats(scheduler) == stats(1, 0, 1, 1, 2)
    refute_received {:effect_started, :successor, _worker, _payloads}

    finalize_once(scheduler, outcome)
    assert_receive {:effect_started, :successor, second_worker, [:successor]}

    send(scheduler, {first_task.ref, {:ok, :late_first_reply}})
    send(scheduler, {:effect_timeout, first.id})
    _barrier = EffectScheduler.stats(scheduler)
    first_id = first.id
    second_id = second.id
    refute_received {:effect_result, ^scheduler, %Outcome{request: %{id: ^first_id}}}
    refute_received {:effect_result, ^scheduler, %Outcome{request: %{id: ^second_id}}}

    send(second_worker, {:release_effect, :successor})
    finalize_once(scheduler, receive_candidate(scheduler, second.id, :completed))
    assert EffectScheduler.stats(scheduler) == stats(0, 0, 0, 0, 0)
  end

  test "failed task start produces one failed outcome and does not wedge the resource" do
    missing_supervisor = {:global, {__MODULE__, make_ref(), :missing_task_supervisor}}

    scheduler =
      start_supervised!(
        Supervisor.child_spec(
          {EffectScheduler, task_supervisor: missing_supervisor, observer: self()},
          id: make_ref()
        )
      )

    :ok = EffectScheduler.attach(scheduler, self())
    request = EffectProbe.request(self(), :start_failure, :resource, Policy.fifo(0))

    assert EffectScheduler.schedule(scheduler, request) == {:ok, request.id, :running}
    outcome = receive_candidate(scheduler, request.id, :failed)
    assert match?({:start_failed, _reason}, outcome.reason)
    finalize_once(scheduler, outcome)
    assert EffectScheduler.stats(scheduler) == stats(0, 0, 0, 0, 0)
  end

  test "explicit cancellation wins before completion and ignores the later task exit" do
    scheduler = start_scheduler()
    request = EffectProbe.request(self(), :cancel, :resource, Policy.fifo(0)) |> with_timeout()

    assert EffectScheduler.schedule(scheduler, request) == {:ok, request.id, :running}
    assert_receive {:effect_started, :cancel, worker, [:cancel]}
    worker_monitor = Process.monitor(worker)

    assert :ok = EffectScheduler.cancel(scheduler, request.id)
    outcome = receive_candidate(scheduler, request.id, :canceled)
    assert outcome.reason == :requested
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}
    assert :sys.get_state(scheduler).timers == %{}
    finalize_once(scheduler, outcome)

    send(scheduler, {:effect_timeout, request.id})
    assert EffectScheduler.stats(scheduler) == stats(0, 0, 0, 0, 0)

    request_id = request.id
    refute_received {:effect_result, ^scheduler, %Outcome{request: %{id: ^request_id}}}
  end

  test "source cancellation kills running work, removes queued work, and advances the lane" do
    scheduler = start_scheduler()
    policy = Policy.fifo(2)
    source = {:extension, :source_alpha}
    other_source = {:extension, :source_beta}

    running =
      EffectProbe.source_request(self(), :source_running, :shared, policy, source)
      |> with_timeout()

    queued = EffectProbe.source_request(self(), :source_queued, :shared, policy, source)
    retained = EffectProbe.source_request(self(), :retained, :shared, policy, other_source)
    core = EffectProbe.request(self(), :core, :core_resource, Policy.fifo(0))

    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, running)
    assert_receive {:effect_started, :source_running, worker, [:source_running]}
    worker_monitor = Process.monitor(worker)
    assert {:ok, _, :queued} = EffectScheduler.schedule(scheduler, queued)
    assert {:ok, _, :queued} = EffectScheduler.schedule(scheduler, retained)
    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, core)
    assert_receive {:effect_started, :core, core_worker, [:core]}
    assert EffectScheduler.active_source?(scheduler, source)

    assert :ok = EffectScheduler.cancel_source(scheduler, source)
    refute EffectScheduler.active_source?(scheduler, source)
    assert EffectScheduler.active_source?(scheduler, other_source)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}
    refute Enum.any?(:sys.get_state(scheduler).timers, fn {_timer, id} -> id == running.id end)
    assert_terminal_direct(running.id, :canceled, :source_canceled)
    assert_terminal_direct(queued.id, :canceled, :source_canceled)
    assert_receive {:effect_started, :retained, retained_worker, [:retained]}
    assert EffectScheduler.stats(scheduler) == stats(2, 2, 0, 0, 2)

    send(retained_worker, {:release_effect, :retained})
    send(core_worker, {:release_effect, :core})
    finalize_once(scheduler, receive_candidate(scheduler, retained.id, :completed))
    finalize_once(scheduler, receive_candidate(scheduler, core.id, :completed))
  end

  test "source cancellation terminalizes unclaimed and claimed pending outcomes" do
    scheduler = start_scheduler()
    source = {:extension, :pending_source}

    unclaimed =
      EffectProbe.source_request(
        self(),
        :unclaimed,
        :unclaimed_resource,
        Policy.fifo(0),
        source,
        {:return, :done}
      )

    claimed =
      EffectProbe.source_request(
        self(),
        :claimed,
        :claimed_resource,
        Policy.fifo(0),
        source,
        {:return, :done}
      )

    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, unclaimed)
    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, claimed)
    unclaimed_outcome = receive_candidate(scheduler, unclaimed.id, :completed)
    claimed_outcome = receive_candidate(scheduler, claimed.id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, claimed_outcome)
    assert EffectScheduler.active_source?(scheduler, source)

    assert :ok = EffectScheduler.cancel_source(scheduler, source)
    assert_terminal_direct(unclaimed.id, :canceled, :source_canceled)
    assert_terminal_direct(claimed.id, :canceled, :source_canceled)
    refute EffectScheduler.active_source?(scheduler, source)
    assert EffectScheduler.claim(scheduler, unclaimed_outcome) == {:error, :not_pending}
    assert EffectScheduler.claim(scheduler, claimed_outcome) == {:error, :not_pending}

    EffectScheduler.finalize(scheduler, unclaimed_outcome)
    EffectScheduler.finalize(scheduler, claimed_outcome)
    assert EffectScheduler.stats(scheduler) == stats(0, 0, 0, 0, 0)
  end

  test "picker resource close terminalizes queued and claimed candidates" do
    scheduler = start_scheduler()
    resource = {:picker_fetch, :close_candidates}
    policy = Policy.fifo(1)

    claimed =
      EffectProbe.request(self(), :claimed_picker, resource, policy, {:return, :ready})

    queued = EffectProbe.request(self(), :queued_picker, resource, policy)

    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, claimed)
    assert {:ok, _, :queued} = EffectScheduler.schedule(scheduler, queued)
    claimed_outcome = receive_candidate(scheduler, claimed.id, :completed)
    assert :ok = EffectScheduler.claim(scheduler, claimed_outcome)

    assert :ok = EffectScheduler.cancel_resource(scheduler, resource)
    assert_terminal_direct(claimed.id, :canceled, :resource_canceled)
    assert_terminal_direct(queued.id, :canceled, :resource_canceled)
    assert EffectScheduler.claim(scheduler, claimed_outcome) == {:error, :not_pending}
    refute_received {:effect_started, :queued_picker, _worker, _payloads}
    assert EffectScheduler.stats(scheduler) == stats(0, 0, 0, 0, 0)
  end

  test "source cancellation is idempotent and rejects delayed worker delivery" do
    scheduler = start_scheduler()
    source = {:extension, :delayed_source}
    request = EffectProbe.source_request(self(), :delayed, :resource, Policy.fifo(0), source)

    assert {:ok, _, :running} = EffectScheduler.schedule(scheduler, request)
    assert_receive {:effect_started, :delayed, _worker, [:delayed]}

    [%{running: %{task: task}}] =
      scheduler |> :sys.get_state() |> Map.fetch!(:lanes) |> Map.values()

    assert :ok = EffectScheduler.cancel_source(scheduler, source)
    assert :ok = EffectScheduler.cancel_source(scheduler, source)
    assert_terminal_direct(request.id, :canceled, :source_canceled)

    send(scheduler, {task.ref, {:ok, :late}})
    _state = :sys.get_state(scheduler)
    request_id = request.id
    refute_received {:effect_result, ^scheduler, %Outcome{request: %{id: ^request_id}}}
    refute_received {:effect_terminal, %Outcome{request: %{id: ^request_id}}}
    assert EffectScheduler.stats(scheduler) == stats(0, 0, 0, 0, 0)
  end

  test "operation cancellation distinguishes an unavailable scheduler" do
    assert EffectScheduler.cancel_operation(nil, 1) == {:error, :scheduler_unavailable}
  end

  test "semantic operation identity cancels its correlated request" do
    scheduler = start_scheduler()
    request = EffectProbe.request(self(), :cancel_operation, :resource, Policy.fifo(0))

    assert EffectScheduler.schedule(scheduler, request) == {:ok, request.id, :running}
    assert_receive {:effect_started, :cancel_operation, _worker, [:cancel_operation]}

    assert :ok = EffectScheduler.cancel_operation(scheduler, request.operation_id)
    outcome = receive_candidate(scheduler, request.id, :canceled)
    assert outcome.reason == :requested
    finalize_once(scheduler, outcome)

    assert EffectScheduler.cancel_operation(scheduler, request.operation_id) ==
             {:error, :not_found}
  end

  test "semantic operation identity cancels a queued request" do
    scheduler = start_scheduler()
    first = EffectProbe.request(self(), :running_operation, :resource, Policy.fifo(1))
    queued = EffectProbe.request(self(), :queued_operation, :resource, Policy.fifo(1))

    assert {:ok, first_id, :running} = EffectScheduler.schedule(scheduler, first)
    assert {:ok, queued_id, :queued} = EffectScheduler.schedule(scheduler, queued)
    assert_receive {:effect_started, :running_operation, _worker, [:running_operation]}

    assert :ok = EffectScheduler.cancel_operation(scheduler, queued.operation_id)
    queued_outcome = receive_candidate(scheduler, queued_id, :canceled)
    assert queued_outcome.reason == :requested
    finalize_once(scheduler, queued_outcome)

    assert :ok = EffectScheduler.cancel_operation(scheduler, first.operation_id)
    finalize_once(scheduler, receive_candidate(scheduler, first_id, :canceled))
  end

  test "completion wins a cancellation race without a second terminal outcome" do
    scheduler = start_scheduler()
    request = EffectProbe.request(self(), :complete_first, :resource, Policy.fifo(0))

    assert EffectScheduler.schedule(scheduler, request) == {:ok, request.id, :running}
    assert_receive {:effect_started, :complete_first, worker, [:complete_first]}
    send(worker, {:release_effect, :complete_first})

    outcome = receive_candidate(scheduler, request.id, :completed)
    assert EffectScheduler.cancel(scheduler, request.id) == {:error, :not_found}
    finalize_once(scheduler, outcome)
  end

  test "latest-wins supersession terminalizes completed candidates before replacement starts" do
    scheduler = start_scheduler()
    policy = Policy.latest_wins()

    old =
      EffectProbe.request(self(), :old, {:buffer, self()}, policy, {:return, :old_result})

    new = EffectProbe.request(self(), :new, {:buffer, self()}, policy)

    assert EffectScheduler.schedule(scheduler, old) == {:ok, old.id, :running}
    assert_receive {:effect_started, :old, _old_worker, [:old]}
    old_candidate = receive_candidate(scheduler, old.id, :completed)

    assert EffectScheduler.schedule(scheduler, new) == {:ok, new.id, :running}
    assert_terminal_direct(old.id, :canceled, :superseded)
    assert_receive {:effect_started, :new, new_worker, [:new]}

    EffectScheduler.finalize(scheduler, old_candidate)
    _stats = EffectScheduler.stats(scheduler)
    old_id = old.id
    refute_received {:effect_terminal, %Outcome{request: %{id: ^old_id}}}

    send(new_worker, {:release_effect, :new})
    new_outcome = receive_candidate(scheduler, new.id, :completed)
    finalize_once(scheduler, new_outcome)
  end

  test "direct terminal outcomes reach the owner when no observer is configured" do
    scheduler = start_scheduler(attach?: false, observer: nil)
    owner = start_owner_proxy()
    :ok = EffectScheduler.attach(scheduler, owner)
    policy = Policy.latest_wins()
    old = EffectProbe.request(self(), :old_direct, :resource, policy)
    new = EffectProbe.request(self(), :new_direct, :resource, policy, {:return, :done})

    assert EffectScheduler.schedule(scheduler, old) == {:ok, old.id, :running}
    assert_owner_lifecycle(old.id, :running)
    assert_receive {:effect_started, :old_direct, _worker, [:old_direct]}

    assert EffectScheduler.schedule(scheduler, new) == {:ok, new.id, :running}
    assert_owner_lifecycle(old.id, :canceled, :superseded)
    assert_owner_lifecycle(new.id, :running)
    old_id = old.id
    refute_received {:effect_terminal, %Outcome{request: %{id: ^old_id}}}

    outcome = receive_owner_candidate(scheduler, new.id, :completed)
    :ok = EffectScheduler.claim(scheduler, outcome)
    EffectScheduler.finalize(scheduler, outcome)
    _stats = EffectScheduler.stats(scheduler)
    new_id = new.id
    refute_received {:effect_terminal, %Outcome{request: %{id: ^new_id}}}
  end

  test "follow-up admission precedes advancement of the source lane" do
    scheduler = start_scheduler(attach?: false)
    owner = start_owner_proxy()
    :ok = EffectScheduler.attach(scheduler, owner)
    source_policy = Policy.fifo(1)

    first =
      EffectProbe.request(self(), :first_source, :source, source_policy, {:return, :resolved})

    second =
      EffectProbe.request(self(), :second_source, :source, source_policy, {:return, :resolved})

    follow_up =
      EffectProbe.request(self(), :follow_up, :target, Policy.fifo(0), {:return, :done})

    assert EffectScheduler.schedule(scheduler, first) == {:ok, first.id, :running}
    assert_owner_lifecycle(first.id, :running)
    assert_receive {:effect_started, :first_source, _worker, [:first_source]}

    assert EffectScheduler.schedule(scheduler, second) == {:ok, second.id, :queued}
    assert_owner_lifecycle(second.id, :queued)
    first_outcome = receive_owner_candidate(scheduler, first.id, :completed)
    :ok = EffectScheduler.claim(scheduler, first_outcome)

    assert EffectScheduler.finalize_and_schedule(scheduler, first_outcome, follow_up) ==
             {:ok, follow_up.id, :running}

    assert_owner_lifecycle(follow_up.id, :running)
    assert_owner_lifecycle(second.id, :running)
    assert_terminal_direct(first.id, :completed, nil)

    follow_up_outcome = receive_owner_candidate(scheduler, follow_up.id, :completed)
    second_outcome = receive_owner_candidate(scheduler, second.id, :completed)
    :ok = EffectScheduler.claim(scheduler, follow_up_outcome)
    EffectScheduler.finalize(scheduler, follow_up_outcome)
    :ok = EffectScheduler.claim(scheduler, second_outcome)
    EffectScheduler.finalize(scheduler, second_outcome)
    assert_terminal_direct(follow_up.id, :completed, nil)
    assert_terminal_direct(second.id, :completed, nil)
  end

  test "same-resource follow-up starts immediately on a zero-queue FIFO lane" do
    scheduler = start_scheduler(attach?: false)
    owner = start_owner_proxy()
    :ok = EffectScheduler.attach(scheduler, owner)
    policy = Policy.fifo(0)
    first = EffectProbe.request(self(), :first_same, :resource, policy, {:return, :resolved})
    follow_up = EffectProbe.request(self(), :follow_up_same, :resource, policy, {:return, :done})

    assert EffectScheduler.schedule(scheduler, first) == {:ok, first.id, :running}
    assert_owner_lifecycle(first.id, :running)
    assert_receive {:effect_started, :first_same, _worker, [:first_same]}
    first_outcome = receive_owner_candidate(scheduler, first.id, :completed)
    :ok = EffectScheduler.claim(scheduler, first_outcome)

    assert EffectScheduler.finalize_and_schedule(scheduler, first_outcome, follow_up) ==
             {:ok, follow_up.id, :running}

    assert_owner_lifecycle(follow_up.id, :running)
    assert_terminal_direct(first.id, :completed, nil)
    follow_up_outcome = receive_owner_candidate(scheduler, follow_up.id, :completed)
    :ok = EffectScheduler.claim(scheduler, follow_up_outcome)
    EffectScheduler.finalize(scheduler, follow_up_outcome)
    assert_terminal_direct(follow_up.id, :completed, nil)
  end

  test "bounded FIFO rejects overflow without admitting the request" do
    scheduler = start_scheduler()
    policy = Policy.fifo(1)
    first = EffectProbe.request(self(), :first, :resource, policy)
    second = EffectProbe.request(self(), :second, :resource, policy)
    overflow = EffectProbe.request(self(), :overflow, :resource, policy)

    assert EffectScheduler.schedule(scheduler, first) == {:ok, first.id, :running}
    assert_receive {:effect_started, :first, _worker, [:first]}
    assert EffectScheduler.schedule(scheduler, second) == {:ok, second.id, :queued}

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{id: second_id},
                      status: :queued,
                      queue_position: 1,
                      queue_total: 1
                    }}

    assert second_id == second.id
    assert {:error, :queue_full} = EffectScheduler.schedule(scheduler, overflow)
    assert EffectScheduler.stats(scheduler) == stats(1, 1, 1, 0, 2)

    assert :ok = EffectScheduler.cancel(scheduler, second.id)
    canceled = receive_candidate(scheduler, second.id, :canceled)
    assert canceled.queue_position == nil
    assert canceled.queue_total == nil
    finalize_once(scheduler, canceled)
    assert :ok = EffectScheduler.cancel(scheduler, first.id)
    finalize_once(scheduler, receive_candidate(scheduler, first.id, :canceled))
    refute_received {:effect_started, :overflow, _worker, _payloads}
  end

  test "bounded coalescing replaces the tail and reports the replaced request stale" do
    scheduler = start_scheduler()
    policy = Policy.coalescing(1)
    first = EffectProbe.request(self(), 1, :resource, policy)
    second = EffectProbe.request(self(), 2, :resource, policy)
    third = EffectProbe.request(self(), 3, :resource, policy)

    assert EffectScheduler.schedule(scheduler, first) == {:ok, first.id, :running}
    assert_receive {:effect_started, 1, first_worker, [1]}
    assert EffectScheduler.schedule(scheduler, second) == {:ok, second.id, :queued}
    assert EffectScheduler.schedule(scheduler, third) == {:ok, third.id, :queued}
    assert_receive {:effect_coalesced, 2, 3}

    assert_terminal_direct(second.id, :stale, :coalesced)

    send(first_worker, {:release_effect, 1})
    first_outcome = receive_candidate(scheduler, first.id, :completed)
    refute_received {:effect_started, 3, _worker, _payloads}
    finalize_once(scheduler, first_outcome)
    assert_receive {:effect_started, 3, third_worker, [2, 3]}
    send(third_worker, {:release_effect, 3})
    finalize_once(scheduler, receive_candidate(scheduler, third.id, :completed))
  end

  test "same-resource FIFO starts requests in admission order" do
    scheduler = start_scheduler()
    policy = Policy.fifo(2)
    first = EffectProbe.request(self(), :first, :repository, policy)
    second = EffectProbe.request(self(), :second, :repository, policy)

    assert EffectScheduler.schedule(scheduler, first) == {:ok, first.id, :running}
    assert EffectScheduler.schedule(scheduler, second) == {:ok, second.id, :queued}
    assert_receive {:effect_started, :first, first_worker, [:first]}
    refute_received {:effect_started, :second, _worker, _payloads}

    send(first_worker, {:release_effect, :first})
    first_outcome = receive_candidate(scheduler, first.id, :completed)
    refute_received {:effect_started, :second, _worker, _payloads}
    finalize_once(scheduler, first_outcome)
    assert_receive {:effect_started, :second, second_worker, [:second]}

    send(second_worker, {:release_effect, :second})
    finalize_once(scheduler, receive_candidate(scheduler, second.id, :completed))
  end

  test "FIFO advances the third request after the first of three completes" do
    scheduler = start_scheduler()
    policy = Policy.fifo(2)
    first = EffectProbe.request(self(), :first, :repository, policy)
    second = EffectProbe.request(self(), :second, :repository, policy)
    third = EffectProbe.request(self(), :third, :repository, policy)

    assert EffectScheduler.schedule(scheduler, first) == {:ok, first.id, :running}
    assert_receive {:effect_started, :first, first_worker, [:first]}
    assert EffectScheduler.schedule(scheduler, second) == {:ok, second.id, :queued}

    assert_receive {:effect_lifecycle,
                    %Outcome{request: %Request{id: second_id}, queue_position: 1, queue_total: 1}}

    assert second_id == second.id
    assert EffectScheduler.schedule(scheduler, third) == {:ok, third.id, :queued}

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{id: refreshed_second_id},
                      queue_position: 1,
                      queue_total: 2
                    }}

    assert refreshed_second_id == second.id

    assert_receive {:effect_lifecycle,
                    %Outcome{request: %Request{id: third_id}, queue_position: 2, queue_total: 2}}

    assert third_id == third.id
    send(first_worker, {:release_effect, :first})
    finalize_once(scheduler, receive_candidate(scheduler, first.id, :completed))

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{id: advanced_third_id},
                      status: :queued,
                      queue_position: 1,
                      queue_total: 1
                    }}

    assert advanced_third_id == third.id
    assert_receive {:effect_started, :second, second_worker, [:second]}

    send(second_worker, {:release_effect, :second})
    finalize_once(scheduler, receive_candidate(scheduler, second.id, :completed))
    assert_receive {:effect_started, :third, third_worker, [:third]}
    send(third_worker, {:release_effect, :third})
    finalize_once(scheduler, receive_candidate(scheduler, third.id, :completed))
  end

  test "FIFO refreshes queue positions after admission and cancellation" do
    scheduler = start_scheduler()
    policy = Policy.fifo(3)
    first = EffectProbe.request(self(), :first, :repository, policy)
    second = EffectProbe.request(self(), :second, :repository, policy)
    third = EffectProbe.request(self(), :third, :repository, policy)

    assert EffectScheduler.schedule(scheduler, first) == {:ok, first.id, :running}
    assert_receive {:effect_started, :first, _worker, [:first]}

    assert EffectScheduler.schedule(scheduler, second) == {:ok, second.id, :queued}

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{id: second_id},
                      status: :queued,
                      queue_position: 1,
                      queue_total: 1
                    }}

    assert second_id == second.id
    assert EffectScheduler.schedule(scheduler, third) == {:ok, third.id, :queued}

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{id: refreshed_second_id},
                      status: :queued,
                      queue_position: 1,
                      queue_total: 2
                    }}

    assert refreshed_second_id == second.id

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{id: third_id},
                      status: :queued,
                      queue_position: 2,
                      queue_total: 2
                    }}

    assert third_id == third.id
    assert :ok = EffectScheduler.cancel(scheduler, second.id)

    assert_receive {:effect_lifecycle,
                    %Outcome{
                      request: %Request{id: refreshed_third_id},
                      status: :queued,
                      queue_position: 1,
                      queue_total: 1
                    }}

    assert refreshed_third_id == third.id
    finalize_once(scheduler, receive_candidate(scheduler, second.id, :canceled))
    assert :ok = EffectScheduler.cancel(scheduler, first.id)
    finalize_once(scheduler, receive_candidate(scheduler, first.id, :canceled))
    assert_receive {:effect_started, :third, _worker, [:third]}
    assert :ok = EffectScheduler.cancel(scheduler, third.id)
    finalize_once(scheduler, receive_candidate(scheduler, third.id, :canceled))
  end

  test "different resources run concurrently" do
    scheduler = start_scheduler()
    policy = Policy.fifo(1)
    left = EffectProbe.request(self(), :left, :left_repository, policy)
    right = EffectProbe.request(self(), :right, :right_repository, policy)

    assert EffectScheduler.schedule(scheduler, left) == {:ok, left.id, :running}
    assert EffectScheduler.schedule(scheduler, right) == {:ok, right.id, :running}
    assert_receive {:effect_started, :left, left_worker, [:left]}
    assert_receive {:effect_started, :right, right_worker, [:right]}
    assert EffectScheduler.stats(scheduler) == stats(2, 2, 0, 0, 2)

    send(left_worker, {:release_effect, :left})
    send(right_worker, {:release_effect, :right})
    finalize_once(scheduler, receive_candidate(scheduler, left.id, :completed))
    finalize_once(scheduler, receive_candidate(scheduler, right.id, :completed))
  end

  test "scheduler-wide capacity bounds concurrent resources" do
    scheduler = start_scheduler(max_admitted: 2)
    policy = Policy.fifo(0)
    left = EffectProbe.request(self(), :left, :left, policy)
    right = EffectProbe.request(self(), :right, :right, policy)
    overflow = EffectProbe.request(self(), :overflow, :overflow, policy)

    assert EffectScheduler.schedule(scheduler, left) == {:ok, left.id, :running}
    assert EffectScheduler.schedule(scheduler, right) == {:ok, right.id, :running}
    assert_receive {:effect_started, :left, left_worker, [:left]}
    assert_receive {:effect_started, :right, right_worker, [:right]}
    assert EffectScheduler.schedule(scheduler, overflow) == {:error, :scheduler_full}
    assert EffectScheduler.stats(scheduler) == stats(2, 2, 0, 0, 2, 2)

    send(left_worker, {:release_effect, :left})
    left_outcome = receive_candidate(scheduler, left.id, :completed)
    assert EffectScheduler.stats(scheduler) == stats(2, 1, 0, 1, 2, 2)
    assert EffectScheduler.schedule(scheduler, overflow) == {:error, :scheduler_full}

    finalize_once(scheduler, left_outcome)
    assert EffectScheduler.schedule(scheduler, overflow) == {:ok, overflow.id, :running}
    assert_receive {:effect_started, :overflow, overflow_worker, [:overflow]}

    send(right_worker, {:release_effect, :right})
    send(overflow_worker, {:release_effect, :overflow})
    finalize_once(scheduler, receive_candidate(scheduler, right.id, :completed))
    finalize_once(scheduler, receive_candidate(scheduler, overflow.id, :completed))
  end

  test "completed but unfinalized requests remain globally bounded" do
    scheduler = start_scheduler(max_admitted: 3)
    policy = Policy.fifo(0)

    requests =
      Enum.map(1..3, fn index ->
        EffectProbe.request(self(), index, {:resource, index}, policy, {:return, index})
      end)

    Enum.each(requests, fn request ->
      assert EffectScheduler.schedule(scheduler, request) == {:ok, request.id, :running}
      assert_receive {:effect_started, index, _worker, [index]} when index == request.effect.label
    end)

    outcomes = Enum.map(requests, &receive_candidate(scheduler, &1.id, :completed))
    assert EffectScheduler.stats(scheduler) == stats(3, 0, 0, 3, 3, 3)

    overflow = EffectProbe.request(self(), :overflow, :fourth_resource, policy)
    assert EffectScheduler.schedule(scheduler, overflow) == {:error, :scheduler_full}

    Enum.each(outcomes, &finalize_once(scheduler, &1))
  end

  test "owner death cancels active and queued work exactly once" do
    scheduler = start_scheduler(attach?: false)
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    owner_monitor = Process.monitor(owner)
    :ok = EffectScheduler.attach(scheduler, owner)

    policy = Policy.fifo(1)
    running = EffectProbe.request(self(), :running, :resource, policy) |> with_timeout()
    queued = EffectProbe.request(self(), :queued, :resource, policy)
    assert EffectScheduler.schedule(scheduler, running) == {:ok, running.id, :running}
    assert_receive {:effect_started, :running, worker, [:running]}
    worker_monitor = Process.monitor(worker)
    assert EffectScheduler.schedule(scheduler, queued) == {:ok, queued.id, :queued}

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}
    assert_terminal_direct(running.id, :canceled, :owner_shutdown)
    assert_terminal_direct(queued.id, :canceled, :owner_shutdown)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}
    assert :sys.get_state(scheduler).timers == %{}
    assert EffectScheduler.stats(scheduler) == stats(0, 0, 0, 0, 0)
    assert {:error, :owner_unavailable} = EffectScheduler.schedule(scheduler, running)

    running_id = running.id
    queued_id = queued.id
    refute_received {:effect_terminal, %Outcome{request: %{id: ^running_id}}}
    refute_received {:effect_terminal, %Outcome{request: %{id: ^queued_id}}}
  end

  test "manual headless Editor generation provisions a generation-owned scheduler" do
    editor_name = {:global, {__MODULE__, make_ref(), :editor}}

    assert {:ok, generation} =
             GenerationSupervisor.start_editor_generation_link(
               name: editor_name,
               backend: :headless,
               rendering: :disabled,
               port_manager: nil,
               suppress_tool_prompts: true
             )

    assert {:ok, editor} = GenerationSupervisor.editor_owner(generation)
    assert GenServer.whereis(editor_name) == editor
    scheduler = :sys.get_state(editor).effect_scheduler
    assert is_pid(GenServer.whereis(scheduler))
    assert EffectScheduler.stats(scheduler).capacity == 64
    assert :ok = Supervisor.stop(generation)
  end

  test "supervised Editor tracks and tears down the whole generation" do
    editor_name = {:global, {__MODULE__, make_ref(), :supervised_editor}}

    generation =
      start_supervised!(
        {MingaEditor,
         name: editor_name,
         backend: :headless,
         rendering: :disabled,
         port_manager: nil,
         suppress_tool_prompts: true},
        restart: :temporary
      )

    assert {:ok, editor} = GenerationSupervisor.editor_owner(generation)
    refute editor == generation
    assert GenServer.whereis(editor_name) == editor

    task_supervisor = generation_child!(generation, :effect_task_supervisor)
    scheduler = generation_child!(generation, :effect_scheduler)
    generation_monitor = Process.monitor(generation)
    editor_monitor = Process.monitor(editor)
    scheduler_monitor = Process.monitor(scheduler)
    task_supervisor_monitor = Process.monitor(task_supervisor)

    request = EffectProbe.request(self(), :supervised_generation, :resource, Policy.fifo(0))
    assert EffectScheduler.schedule(scheduler, request) == {:ok, request.id, :running}

    assert_receive {:effect_started, :supervised_generation, worker, [:supervised_generation]},
                   @effect_timeout

    worker_monitor = Process.monitor(worker)

    assert :ok = stop_supervised(MingaEditor)
    assert_receive {:DOWN, ^generation_monitor, :process, ^generation, :shutdown}, @effect_timeout
    assert_receive {:DOWN, ^editor_monitor, :process, ^editor, :shutdown}, @effect_timeout
    assert_receive {:DOWN, ^scheduler_monitor, :process, ^scheduler, :shutdown}, @effect_timeout

    assert_receive {:DOWN, ^task_supervisor_monitor, :process, ^task_supervisor, :shutdown},
                   @effect_timeout

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, @effect_timeout
    assert GenServer.whereis(editor_name) == nil
  end

  test "generation restart kills old work before a replacement owner attaches" do
    generation_name = {:global, {__MODULE__, make_ref(), :generation}}
    task_name = {:global, {__MODULE__, make_ref(), :tasks}}
    scheduler_name = {:global, {__MODULE__, make_ref(), :scheduler}}

    generation =
      start_supervised!(
        {GenerationSupervisor,
         name: generation_name,
         task_supervisor_name: task_name,
         scheduler_name: scheduler_name,
         observer: self(),
         editor: {EffectOwner, observer: self()}},
        restart: :temporary
      )

    assert_receive {:effect_owner_started, first_owner, ^scheduler_name}
    first_scheduler = GenServer.whereis(scheduler_name)
    request = EffectProbe.request(self(), :old_generation, :resource, Policy.fifo(0))
    assert EffectScheduler.schedule(first_scheduler, request) == {:ok, request.id, :running}
    assert_receive {:effect_started, :old_generation, worker, [:old_generation]}

    worker_monitor = Process.monitor(worker)
    scheduler_monitor = Process.monitor(first_scheduler)
    :sys.get_state(first_scheduler)
    Process.exit(first_owner, :kill)

    request_id = request.id

    assert_receive {:effect_terminal,
                    %Outcome{
                      request: %{id: ^request_id},
                      status: :canceled,
                      reason: :owner_shutdown
                    }}

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}
    assert_receive {:DOWN, ^scheduler_monitor, :process, ^first_scheduler, :shutdown}
    assert_receive {:effect_owner_started, second_owner, ^scheduler_name}
    refute second_owner == first_owner

    second_scheduler = GenServer.whereis(scheduler_name)
    refute second_scheduler == first_scheduler

    replacement =
      EffectProbe.request(self(), :new_generation, :resource, Policy.fifo(0), {:return, :ok})

    assert EffectScheduler.schedule(second_scheduler, replacement) ==
             {:ok, replacement.id, :running}

    replacement_id = replacement.id

    assert_receive {:owner_result, ^second_owner,
                    %Outcome{request: %{id: ^replacement_id}, status: :completed}}

    assert_receive {:effect_terminal,
                    %Outcome{request: %{id: ^replacement_id}, status: :completed}}

    assert Supervisor.count_children(generation).active == 3
    refute_received {:effect_terminal, %Outcome{request: %{id: ^request_id}}}
  end

  @spec with_timeout(Request.t()) :: Request.t()
  defp with_timeout(%Request{} = request), do: %{request | timeout_ms: 60_000}

  @spec generation_child!(Supervisor.supervisor(), term()) :: pid()
  defp generation_child!(generation, child_id) do
    case List.keyfind(Supervisor.which_children(generation), child_id, 0) do
      {^child_id, child, _type, _modules} when is_pid(child) -> child
      _missing -> raise "missing generation child #{inspect(child_id)}"
    end
  end

  @spec start_scheduler(keyword()) :: pid()
  defp start_scheduler(opts \\ []) do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler_opts =
      [task_supervisor: task_supervisor, observer: Keyword.get(opts, :observer, self())]
      |> Keyword.put(:max_admitted, Keyword.get(opts, :max_admitted, 64))

    scheduler =
      start_supervised!(Supervisor.child_spec({EffectScheduler, scheduler_opts}, id: make_ref()))

    if Keyword.get(opts, :attach?, true), do: :ok = EffectScheduler.attach(scheduler, self())
    scheduler
  end

  @spec start_owner_proxy() :: pid()
  defp start_owner_proxy do
    test_pid = self()

    start_supervised!(
      Supervisor.child_spec({Task, fn -> forward_owner_messages(test_pid) end}, id: make_ref())
    )
  end

  @spec forward_owner_messages(pid()) :: no_return()
  defp forward_owner_messages(test_pid) do
    receive do
      message ->
        send(test_pid, {:owner_message, message})
        forward_owner_messages(test_pid)
    end
  end

  @spec assert_owner_lifecycle(reference(), Outcome.status(), term() | nil) :: :ok
  defp assert_owner_lifecycle(request_id, status, reason \\ nil) do
    assert_receive {:owner_message,
                    {:effect_lifecycle,
                     %Outcome{request: %{id: ^request_id}, status: ^status, reason: ^reason}}},
                   @effect_timeout

    :ok
  end

  @spec receive_owner_candidate(pid(), reference(), Outcome.terminal_status()) :: Outcome.t()
  defp receive_owner_candidate(scheduler, request_id, status) do
    assert_receive {:owner_message,
                    {:effect_result, ^scheduler,
                     %Outcome{request: %{id: ^request_id}, status: ^status} = outcome}},
                   @effect_timeout

    outcome
  end

  @spec receive_candidate(pid(), reference(), Outcome.terminal_status()) :: Outcome.t()
  defp receive_candidate(scheduler, request_id, status) do
    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %{id: id}, status: ^status} = outcome}
                   when id == request_id,
                   @effect_timeout

    outcome
  end

  @spec finalize_once(pid(), Outcome.t()) :: :ok
  defp finalize_once(scheduler, %Outcome{} = outcome) do
    request_id = outcome.request.id
    status = outcome.status
    EffectScheduler.finalize(scheduler, outcome)

    assert_receive {:effect_terminal, %Outcome{request: %{id: ^request_id}, status: ^status}},
                   @effect_timeout

    _stats = EffectScheduler.stats(scheduler)
    refute_received {:effect_terminal, %Outcome{request: %{id: ^request_id}}}
    :ok
  end

  @spec stats(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer()
        ) :: map()
  defp stats(resources, running, queued, pending, admitted, capacity \\ 64) do
    %{
      resources: resources,
      running: running,
      queued: queued,
      pending: pending,
      admitted: admitted,
      capacity: capacity
    }
  end

  @spec assert_terminal_direct(reference(), Outcome.terminal_status(), term()) :: :ok
  defp assert_terminal_direct(request_id, status, reason) do
    assert_receive {:effect_terminal,
                    %Outcome{request: %{id: id}, status: ^status, reason: ^reason}}
                   when id == request_id,
                   @effect_timeout

    :ok
  end
end
