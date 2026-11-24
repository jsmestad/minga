defmodule MingaAgent.Providers.Native.ExecutionStateTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Providers.Native.ExecutionState
  alias MingaAgent.Session.Request

  defp make_task do
    Task.async(fn -> :ok end)
  end

  defp make_request do
    %Request{
      request_id: "req_#{:erlang.unique_integer([:positive])}",
      turn_id: "turn_1",
      conversation_revision: make_ref(),
      messages: [],
      epoch_id: "epoch_1",
      prefix: nil
    }
  end

  describe "idle/0" do
    test "returns an idle state at generation 0" do
      state = ExecutionState.idle()
      assert state.tag == :idle
      assert state.generation == 0
      assert state.task == nil
      assert state.request == nil
      assert state.workers == MapSet.new()
    end
  end

  describe "start/3" do
    test "transitions from idle to active with incremented generation" do
      idle = ExecutionState.idle()
      task = make_task()
      request = make_request()
      active = ExecutionState.start(idle, task, request)

      assert active.tag == :active
      assert active.generation == 1
      assert active.task == task
      assert active.request == request
      assert active.workers == MapSet.new()
      Task.await(task)
    end

    test "transitions from interrupted to active with incremented generation" do
      idle = ExecutionState.idle()
      task1 = make_task()
      request1 = make_request()
      active = ExecutionState.start(idle, task1, request1)
      Task.await(task1)
      interrupted = ExecutionState.interrupt(active)
      assert interrupted.tag == :interrupted
      assert interrupted.generation == 1

      task2 = make_task()
      request2 = make_request()
      restarted = ExecutionState.start(interrupted, task2, request2)

      assert restarted.tag == :active
      assert restarted.generation == 2
      assert restarted.task == task2
      assert restarted.request == request2
      Task.await(task2)
    end
  end

  describe "complete/1" do
    test "transitions from active to idle, preserving generation" do
      task = make_task()
      active = ExecutionState.start(ExecutionState.idle(), task, make_request())
      Task.await(task)

      completed = ExecutionState.complete(active)
      assert completed.tag == :idle
      assert completed.generation == 1
      assert completed.task == nil
      assert completed.request == nil
    end
  end

  describe "interrupt/1" do
    test "transitions from active to interrupted, preserving generation" do
      task = make_task()
      active = ExecutionState.start(ExecutionState.idle(), task, make_request())
      Task.await(task)

      interrupted = ExecutionState.interrupt(active)
      assert interrupted.tag == :interrupted
      assert interrupted.generation == 1
    end
  end

  describe "abort/1" do
    test "from idle returns state unchanged with empty cleanup" do
      idle = ExecutionState.idle()
      {new_state, task, workers} = ExecutionState.abort(idle)

      assert new_state.tag == :idle
      assert task == nil
      assert workers == MapSet.new()
    end

    test "from active returns idle with the task and workers to clean up" do
      task = make_task()
      active = ExecutionState.start(ExecutionState.idle(), task, make_request())
      Task.await(task)
      {:ok, active} = ExecutionState.register_workers(active, 1, [self()])

      {new_state, cleanup_task, cleanup_workers} = ExecutionState.abort(active)

      assert new_state.tag == :idle
      assert new_state.generation == 1
      assert cleanup_task == task
      assert cleanup_workers == MapSet.new([self()])
    end

    test "from interrupted returns idle with empty cleanup" do
      task = make_task()
      active = ExecutionState.start(ExecutionState.idle(), task, make_request())
      Task.await(task)
      interrupted = ExecutionState.interrupt(active)

      {new_state, cleanup_task, cleanup_workers} = ExecutionState.abort(interrupted)
      assert new_state.tag == :idle
      assert cleanup_task == nil
      assert cleanup_workers == MapSet.new()
    end
  end

  describe "rejected source tags" do
    test "start, complete, interrupt and next_generation refuse every invalid source tag" do
      task = make_task()
      active = ExecutionState.start(ExecutionState.idle(), task, make_request())
      Task.await(task)
      interrupted = ExecutionState.interrupt(active)
      other_task = make_task()
      Task.await(other_task)

      rejected = [
        {:start, active, fn state -> ExecutionState.start(state, other_task, make_request()) end},
        {:next_generation, active, &ExecutionState.next_generation/1},
        {:complete, ExecutionState.idle(), &ExecutionState.complete/1},
        {:complete, interrupted, &ExecutionState.complete/1},
        {:interrupt, ExecutionState.idle(), &ExecutionState.interrupt/1},
        {:interrupt, interrupted, &ExecutionState.interrupt/1}
      ]

      for {transition, source, apply} <- rejected do
        result =
          try do
            {:accepted, apply.(source)}
          rescue
            FunctionClauseError -> :rejected
          end

        assert {transition, source.tag, result} == {transition, source.tag, :rejected}
      end
    end
  end

  describe "next_generation/1" do
    test "names the generation the next start admits from every startable tag" do
      task = make_task()
      active = ExecutionState.start(ExecutionState.idle(), task, make_request())
      Task.await(task)
      interrupted = ExecutionState.interrupt(active)
      completed = ExecutionState.complete(active)

      for {source, expected} <- [{ExecutionState.idle(), 1}, {interrupted, 2}, {completed, 2}] do
        assert ExecutionState.next_generation(source) == expected
        next_task = make_task()
        started = ExecutionState.start(source, next_task, make_request())
        Task.await(next_task)
        assert ExecutionState.generation(started) == expected
      end
    end
  end

  describe "cancel/2" do
    test "cancels only active work admitted for the named request, from every tag" do
      task = make_task()
      request = make_request()
      active = ExecutionState.start(ExecutionState.idle(), task, request)
      Task.await(task)
      worker = spawn(fn -> :ok end)
      {:ok, active} = ExecutionState.register_workers(active, 1, [worker])

      assert {:cancelled, idle, ^task, workers} =
               ExecutionState.cancel(active, request.request_id)

      assert idle.tag == :idle
      assert idle.generation == 1
      assert workers == MapSet.new([worker])

      interrupted = ExecutionState.interrupt(active)

      for source <- [ExecutionState.idle(), interrupted, idle] do
        assert ExecutionState.cancel(source, request.request_id) == :stale
      end

      assert ExecutionState.cancel(active, make_request().request_id) == :stale
    end

    test "a cancellation for a replaced request cannot stop its replacement" do
      first_task = make_task()
      first = make_request()
      active = ExecutionState.start(ExecutionState.idle(), first_task, first)
      Task.await(first_task)

      second_task = make_task()
      second = make_request()

      replacement =
        active |> ExecutionState.complete() |> ExecutionState.start(second_task, second)

      Task.await(second_task)

      assert ExecutionState.cancel(replacement, first.request_id) == :stale

      assert {:cancelled, _idle, ^second_task, _workers} =
               ExecutionState.cancel(replacement, second.request_id)
    end
  end

  describe "register_workers/3" do
    test "adds PIDs only to the active generation that admitted them" do
      task = make_task()
      active = ExecutionState.start(ExecutionState.idle(), task, make_request())
      Task.await(task)

      pid1 = spawn(fn -> :ok end)
      pid2 = spawn(fn -> :ok end)
      assert {:ok, updated} = ExecutionState.register_workers(active, 1, [pid1, pid2])

      assert MapSet.member?(updated.workers, pid1)
      assert MapSet.member?(updated.workers, pid2)
    end

    test "refuses workers from a stale generation and from every non-active tag" do
      task = make_task()
      active = ExecutionState.start(ExecutionState.idle(), task, make_request())
      Task.await(task)
      pid = spawn(fn -> :ok end)

      assert ExecutionState.register_workers(active, 0, [pid]) == {:error, :stale_generation}

      for source <- [
            ExecutionState.idle(),
            ExecutionState.interrupt(active),
            ExecutionState.complete(active)
          ] do
        assert ExecutionState.register_workers(source, ExecutionState.generation(source), [pid]) ==
                 {:error, :stale_generation}
      end
    end
  end

  describe "unregister_workers/2" do
    test "removes PIDs from the worker set in active state" do
      task = make_task()
      active = ExecutionState.start(ExecutionState.idle(), task, make_request())
      Task.await(task)

      pid = spawn(fn -> :ok end)
      {:ok, active} = ExecutionState.register_workers(active, 1, [pid])
      updated = ExecutionState.unregister_workers(active, [pid])

      refute MapSet.member?(updated.workers, pid)
    end

    test "is a no-op in idle state" do
      idle = ExecutionState.idle()
      result = ExecutionState.unregister_workers(idle, [self()])
      assert result == idle
    end
  end

  describe "remove_worker/2" do
    test "removes a single worker from active state" do
      task = make_task()
      active = ExecutionState.start(ExecutionState.idle(), task, make_request())
      Task.await(task)

      pid = spawn(fn -> :ok end)
      {:ok, active} = ExecutionState.register_workers(active, 1, [pid])
      updated = ExecutionState.remove_worker(active, pid)

      refute MapSet.member?(updated.workers, pid)
    end

    test "is a no-op in idle state" do
      idle = ExecutionState.idle()
      result = ExecutionState.remove_worker(idle, self())
      assert result == idle
    end
  end

  describe "predicates" do
    test "active?/1 returns true only for active state" do
      idle = ExecutionState.idle()
      task = make_task()
      active = ExecutionState.start(idle, task, make_request())
      Task.await(task)
      interrupted = ExecutionState.interrupt(active)

      refute ExecutionState.active?(idle)
      assert ExecutionState.active?(active)
      refute ExecutionState.active?(interrupted)
    end

    test "interrupted?/1 returns true only for interrupted state" do
      idle = ExecutionState.idle()
      task = make_task()
      active = ExecutionState.start(idle, task, make_request())
      Task.await(task)
      interrupted = ExecutionState.interrupt(active)

      refute ExecutionState.interrupted?(idle)
      refute ExecutionState.interrupted?(active)
      assert ExecutionState.interrupted?(interrupted)
    end

    test "idle?/1 returns true only for idle state" do
      idle = ExecutionState.idle()
      task = make_task()
      active = ExecutionState.start(idle, task, make_request())
      Task.await(task)
      interrupted = ExecutionState.interrupt(active)

      assert ExecutionState.idle?(idle)
      refute ExecutionState.idle?(active)
      refute ExecutionState.idle?(interrupted)
    end

    test "request_active?/1 returns true only when active" do
      idle = ExecutionState.idle()
      task = make_task()
      active = ExecutionState.start(idle, task, make_request())
      Task.await(task)

      refute ExecutionState.request_active?(idle)
      assert ExecutionState.request_active?(active)
    end

    test "task_ref/1 and task_pid/1 return values only in active state" do
      idle = ExecutionState.idle()
      task = make_task()
      active = ExecutionState.start(idle, task, make_request())

      assert ExecutionState.task_ref(idle) == nil
      assert ExecutionState.task_pid(idle) == nil
      assert ExecutionState.task_ref(active) == task.ref
      assert ExecutionState.task_pid(active) == task.pid
      Task.await(task)
    end

    test "generation/1 tracks transition count" do
      idle = ExecutionState.idle()
      assert ExecutionState.generation(idle) == 0

      task1 = make_task()
      active1 = ExecutionState.start(idle, task1, make_request())
      Task.await(task1)
      assert ExecutionState.generation(active1) == 1

      completed = ExecutionState.complete(active1)
      assert ExecutionState.generation(completed) == 1

      task2 = make_task()
      active2 = ExecutionState.start(completed, task2, make_request())
      Task.await(task2)
      assert ExecutionState.generation(active2) == 2
    end
  end
end
