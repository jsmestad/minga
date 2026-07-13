defmodule MingaEditor.EffectSchedulerTest do
  @moduledoc "Deterministic lifecycle and resource-policy tests for generation-owned effects."

  use ExUnit.Case, async: true

  alias Minga.Test.EffectOwner
  alias Minga.Test.EffectProbe
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.EffectScheduler
  alias MingaEditor.GenerationSupervisor

  @effect_timeout 2_000

  test "normal completion produces exactly one completed terminal outcome" do
    scheduler = start_scheduler()
    request = EffectProbe.request(self(), :normal, :resource, Policy.fifo(1), {:return, :done})

    assert EffectScheduler.schedule(scheduler, request) == {:ok, request.id, :running}
    assert_receive {:effect_started, :normal, _worker, [:normal]}
    outcome = receive_candidate(scheduler, request.id, :completed)
    assert outcome.result == :done

    finalize_once(scheduler, outcome)
    assert EffectScheduler.cancel(scheduler, request.id) == {:error, :not_found}
  end

  test "raised and killed workers each produce one failed terminal outcome" do
    scheduler = start_scheduler()

    raised =
      EffectProbe.request(self(), :raised, :raised_resource, Policy.fifo(0), {:raise, "boom"})

    assert EffectScheduler.schedule(scheduler, raised) == {:ok, raised.id, :running}
    assert_receive {:effect_started, :raised, _raised_worker, [:raised]}
    raised_outcome = receive_candidate(scheduler, raised.id, :failed)
    assert match?({:worker_exit, {%RuntimeError{message: "boom"}, _stack}}, raised_outcome.reason)
    finalize_once(scheduler, raised_outcome)

    killed = EffectProbe.request(self(), :killed, :killed_resource, Policy.fifo(0))
    assert EffectScheduler.schedule(scheduler, killed) == {:ok, killed.id, :running}
    assert_receive {:effect_started, :killed, killed_worker, [:killed]}
    Process.exit(killed_worker, :kill)

    killed_outcome = receive_candidate(scheduler, killed.id, :failed)
    assert killed_outcome.reason == {:worker_exit, :killed}
    finalize_once(scheduler, killed_outcome)
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
    request = EffectProbe.request(self(), :cancel, :resource, Policy.fifo(0))

    assert EffectScheduler.schedule(scheduler, request) == {:ok, request.id, :running}
    assert_receive {:effect_started, :cancel, worker, [:cancel]}
    worker_monitor = Process.monitor(worker)

    assert :ok = EffectScheduler.cancel(scheduler, request.id)
    outcome = receive_candidate(scheduler, request.id, :canceled)
    assert outcome.reason == :requested
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}
    finalize_once(scheduler, outcome)

    assert EffectScheduler.stats(scheduler) == stats(0, 0, 0, 0, 0)

    request_id = request.id
    refute_received {:effect_result, ^scheduler, %Outcome{request: %{id: ^request_id}}}
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

  test "bounded FIFO rejects overflow without admitting the request" do
    scheduler = start_scheduler()
    policy = Policy.fifo(1)
    first = EffectProbe.request(self(), :first, :resource, policy)
    second = EffectProbe.request(self(), :second, :resource, policy)
    overflow = EffectProbe.request(self(), :overflow, :resource, policy)

    assert EffectScheduler.schedule(scheduler, first) == {:ok, first.id, :running}
    assert_receive {:effect_started, :first, _worker, [:first]}
    assert EffectScheduler.schedule(scheduler, second) == {:ok, second.id, :queued}
    assert {:error, :queue_full} = EffectScheduler.schedule(scheduler, overflow)
    assert EffectScheduler.stats(scheduler) == stats(1, 1, 1, 0, 2)

    assert :ok = EffectScheduler.cancel(scheduler, second.id)
    finalize_once(scheduler, receive_candidate(scheduler, second.id, :canceled))
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
    running = EffectProbe.request(self(), :running, :resource, policy)
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
    assert EffectScheduler.stats(scheduler) == stats(0, 0, 0, 0, 0)
    assert {:error, :owner_unavailable} = EffectScheduler.schedule(scheduler, running)

    running_id = running.id
    queued_id = queued.id
    refute_received {:effect_terminal, %Outcome{request: %{id: ^running_id}}}
    refute_received {:effect_terminal, %Outcome{request: %{id: ^queued_id}}}
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

  @spec start_scheduler(keyword()) :: pid()
  defp start_scheduler(opts \\ []) do
    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler_opts =
      [task_supervisor: task_supervisor, observer: self()]
      |> Keyword.put(:max_admitted, Keyword.get(opts, :max_admitted, 64))

    scheduler =
      start_supervised!(Supervisor.child_spec({EffectScheduler, scheduler_opts}, id: make_ref()))

    if Keyword.get(opts, :attach?, true), do: :ok = EffectScheduler.attach(scheduler, self())
    scheduler
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
