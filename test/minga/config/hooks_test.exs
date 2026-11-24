defmodule Minga.Config.HooksTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Hooks
  alias Minga.Events

  setup context do
    registry = Module.concat([context.module, context.test, Events])
    hooks = Module.concat([context.module, context.test, Hooks])
    task_sup = Module.concat([context.module, context.test, TaskSupervisor])

    start_supervised!({Events, name: registry})
    start_supervised!({Task.Supervisor, name: task_sup})

    start_supervised!({Hooks, name: hooks, events_registry: registry, task_supervisor: task_sup})

    {:ok, registry: registry, hooks: hooks, task_sup: task_sup}
  end

  describe "register/3" do
    test "registers a hook for a valid event", %{hooks: hooks} do
      assert :ok = Hooks.register(hooks, :after_save, fn _buf, _path -> :ok end)
    end

    test "returns error for unknown event", %{hooks: hooks} do
      assert {:error, msg} = Hooks.register(hooks, :nonexistent, fn -> :ok end)
      assert msg =~ "unknown event"
    end
  end

  describe "run/3" do
    test "fires registered hooks with arguments", %{hooks: hooks} do
      test_pid = self()
      ref = make_ref()

      Hooks.register(hooks, :after_save, fn buf, path ->
        send(test_pid, {ref, :hook_fired, buf, path})
      end)

      Hooks.run(hooks, :after_save, [:fake_buf, "/tmp/test.ex"])

      assert_receive {^ref, :hook_fired, :fake_buf, "/tmp/test.ex"}, 500
    end

    test "fires every registered hook", %{hooks: hooks} do
      test_pid = self()
      ref = make_ref()
      Hooks.register(hooks, :after_save, fn _, _ -> send(test_pid, {ref, :first}) end)
      Hooks.register(hooks, :after_save, fn _, _ -> send(test_pid, {ref, :second}) end)

      Hooks.run(hooks, :after_save, [:buf, "/path"])

      assert_receive {^ref, :first}, 500
      assert_receive {^ref, :second}, 500
    end

    test "crashing hook does not prevent other hooks from running", %{hooks: hooks} do
      test_pid = self()
      ref = make_ref()
      Hooks.register(hooks, :after_save, fn _, _ -> raise "boom" end)
      Hooks.register(hooks, :after_save, fn _, _ -> send(test_pid, {ref, :second_ran}) end)

      Hooks.run(hooks, :after_save, [:buf, "/path"])

      assert_receive {^ref, :second_ran}, 500
    end

    test "no-op when no hooks registered", %{hooks: hooks} do
      assert :ok = Hooks.run(hooks, :after_open, [:buf, "/path"])
    end

    test "on_mode_change hooks receive mode atoms", %{hooks: hooks} do
      test_pid = self()
      ref = make_ref()

      Hooks.register(hooks, :on_mode_change, fn old, new ->
        send(test_pid, {ref, :mode_change, old, new})
      end)

      Hooks.run(hooks, :on_mode_change, [:normal, :insert])

      assert_receive {^ref, :mode_change, :normal, :insert}, 500
    end
  end

  describe "sequential effect ordering" do
    test "hooks produce effects in registration order", %{hooks: hooks} do
      test_pid = self()
      ref = make_ref()

      for i <- 1..5 do
        Hooks.register(hooks, :after_save, fn _, _ ->
          send(test_pid, {ref, :effect, i})
        end)
      end

      Hooks.run(hooks, :after_save, [:buf, "/path"])

      for i <- 1..5 do
        assert_receive {^ref, :effect, ^i}, 500
      end
    end

    test "blocking hook delays later hooks in the same event", %{hooks: hooks} do
      test_pid = self()
      gate = make_ref()

      Hooks.register(hooks, :after_save, fn _, _ ->
        send(test_pid, {gate, :started, 1, self()})

        receive do
          {^gate, :release, 1} -> :ok
        end

        send(test_pid, {gate, :completed, 1})
      end)

      Hooks.register(hooks, :after_save, fn _, _ ->
        send(test_pid, {gate, :started, 2, self()})
        send(test_pid, {gate, :completed, 2})
      end)

      Hooks.run(hooks, :after_save, [:buf, "/path"])

      # Hook 1 starts; hook 2 has not started yet.
      assert_receive {^gate, :started, 1, runner_pid}, 500
      refute_receive {^gate, :started, 2, _}, 50

      # Release hook 1; both complete in order.
      send(runner_pid, {gate, :release, 1})
      assert_receive {^gate, :completed, 1}, 500
      assert_receive {^gate, :started, 2, _}, 500
      assert_receive {^gate, :completed, 2}, 500
    end

    test "queued event firings execute in FIFO order", %{hooks: hooks} do
      test_pid = self()
      gate = make_ref()
      counter = :counters.new(1, [])

      Hooks.register(hooks, :after_save, fn _buf, path ->
        invocation = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if invocation == 0 do
          send(test_pid, {gate, :first_started, self()})

          receive do
            {^gate, :release} -> :ok
          end
        end

        send(test_pid, {gate, :completed, path})
      end)

      # First invocation starts the runner and blocks.
      Hooks.run(hooks, :after_save, [:buf, "/path/1"])
      assert_receive {^gate, :first_started, runner_pid}, 500

      # Queue two more while the runner is blocked.
      Hooks.run(hooks, :after_save, [:buf, "/path/2"])
      Hooks.run(hooks, :after_save, [:buf, "/path/3"])
      :sys.get_state(hooks)

      # Release the first runner.
      send(runner_pid, {gate, :release})

      # All three complete in FIFO order.
      assert_receive {^gate, :completed, "/path/1"}, 500
      assert_receive {^gate, :completed, "/path/2"}, 500
      assert_receive {^gate, :completed, "/path/3"}, 500
    end
  end

  describe "failure isolation with ordering" do
    test "hook failure is isolated and later hooks still run in order", %{hooks: hooks} do
      test_pid = self()
      ref = make_ref()

      Hooks.register(hooks, :after_save, fn _, _ -> send(test_pid, {ref, :effect, 1}) end)
      Hooks.register(hooks, :after_save, fn _, _ -> raise "hook 2 explodes" end)
      Hooks.register(hooks, :after_save, fn _, _ -> send(test_pid, {ref, :effect, 3}) end)

      Hooks.run(hooks, :after_save, [:buf, "/path"])

      assert_receive {^ref, :effect, 1}, 500
      assert_receive {^ref, :effect, 3}, 500
    end

    test "throw in a hook is isolated", %{hooks: hooks} do
      test_pid = self()
      ref = make_ref()

      Hooks.register(hooks, :after_save, fn _, _ -> throw(:kaboom) end)
      Hooks.register(hooks, :after_save, fn _, _ -> send(test_pid, {ref, :survived}) end)

      Hooks.run(hooks, :after_save, [:buf, "/path"])

      assert_receive {^ref, :survived}, 500
    end

    test "exit in a hook is isolated", %{hooks: hooks} do
      test_pid = self()
      ref = make_ref()

      Hooks.register(hooks, :after_save, fn _, _ -> exit(:deliberate) end)
      Hooks.register(hooks, :after_save, fn _, _ -> send(test_pid, {ref, :survived}) end)

      Hooks.run(hooks, :after_save, [:buf, "/path"])

      assert_receive {^ref, :survived}, 500
    end
  end

  describe "admission bounds" do
    setup context do
      registry = Module.concat([context.module, context.test, :Bounded, Events])
      hooks = Module.concat([context.module, context.test, :Bounded, Hooks])
      task_sup = Module.concat([context.module, context.test, :Bounded, TaskSupervisor])

      start_supervised!({Events, name: registry}, id: :bounded_events)
      start_supervised!({Task.Supervisor, name: task_sup}, id: :bounded_task_sup)

      start_supervised!(
        {Hooks,
         name: hooks, events_registry: registry, task_supervisor: task_sup, max_pending: 2},
        id: :bounded_hooks
      )

      {:ok, bounded_hooks: hooks}
    end

    test "drops events when queue is full", %{bounded_hooks: hooks} do
      test_pid = self()
      gate = make_ref()
      counter = :counters.new(1, [])

      Hooks.register(hooks, :after_save, fn _buf, path ->
        invocation = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if invocation == 0 do
          send(test_pid, {gate, :first_started, self()})

          receive do
            {^gate, :release} -> :ok
          end
        end

        send(test_pid, {gate, :completed, path})
      end)

      # Invocation 1: starts runner, blocks.
      Hooks.run(hooks, :after_save, [:buf, "/path/1"])
      assert_receive {^gate, :first_started, runner_pid}, 500

      # Invocations 2 and 3: queued (max_pending = 2).
      # Invocation 4: dropped.
      Hooks.run(hooks, :after_save, [:buf, "/path/2"])
      Hooks.run(hooks, :after_save, [:buf, "/path/3"])
      Hooks.run(hooks, :after_save, [:buf, "/path/4"])
      :sys.get_state(hooks)

      send(runner_pid, {gate, :release})

      assert_receive {^gate, :completed, "/path/1"}, 500
      assert_receive {^gate, :completed, "/path/2"}, 500
      assert_receive {^gate, :completed, "/path/3"}, 500
      refute_receive {^gate, :completed, "/path/4"}, 200
    end
  end

  describe "cross-event concurrency" do
    test "different event types run concurrently", %{hooks: hooks} do
      test_pid = self()
      gate = make_ref()

      Hooks.register(hooks, :after_save, fn _, _ ->
        send(test_pid, {gate, :save_started, self()})

        receive do
          {^gate, :release_save} -> :ok
        end

        send(test_pid, {gate, :save_done})
      end)

      Hooks.register(hooks, :after_open, fn _, _ ->
        send(test_pid, {gate, :open_started, self()})

        receive do
          {^gate, :release_open} -> :ok
        end

        send(test_pid, {gate, :open_done})
      end)

      Hooks.run(hooks, :after_save, [:buf, "/path"])
      Hooks.run(hooks, :after_open, [:buf, "/path"])

      # Both event types start their runners concurrently.
      assert_receive {^gate, :save_started, save_pid}, 500
      assert_receive {^gate, :open_started, open_pid}, 500
      assert save_pid != open_pid

      send(open_pid, {gate, :release_open})
      assert_receive {^gate, :open_done}, 500

      send(save_pid, {gate, :release_save})
      assert_receive {^gate, :save_done}, 500
    end
  end

  describe "reset/1" do
    test "removes all hooks", %{hooks: hooks} do
      test_pid = self()
      ref = make_ref()

      Hooks.register(hooks, :after_save, fn _, _ ->
        send(test_pid, {ref, :should_not_fire})
      end)

      Hooks.reset(hooks)

      Hooks.run(hooks, :after_save, [:buf, "/path"])
      :sys.get_state(hooks)

      refute_receive {^ref, :should_not_fire}, 100
    end

    test "an event after reset waits for the runner that was in flight before reset", %{
      hooks: hooks,
      task_sup: task_sup
    } do
      test_pid = self()
      gate = make_ref()

      Hooks.register(hooks, :after_save, fn _buf, path ->
        send(test_pid, {gate, :old_started, path, self()})

        receive do
          {^gate, :release} -> :ok
        end

        send(test_pid, {gate, :effect, {:old, path}})
      end)

      Hooks.run(hooks, :after_save, [:buf, "/before-reload"])
      assert_receive {^gate, :old_started, "/before-reload", old_runner}, 500

      Hooks.reset(hooks)

      Hooks.register(hooks, :after_save, fn _buf, path ->
        send(test_pid, {gate, :effect, {:new, path}})
      end)

      Hooks.run(hooks, :after_save, [:buf, "/after-reload"])
      :sys.get_state(hooks)

      assert [^old_runner] = Task.Supervisor.children(task_sup)
      refute_received {^gate, :effect, _}

      send(old_runner, {gate, :release})
      assert_receive {^gate, :effect, first}, 500
      assert_receive {^gate, :effect, second}, 500
      assert [first, second] == [{:old, "/before-reload"}, {:new, "/after-reload"}]
    end

    test "reset discards invocations queued before reset", %{hooks: hooks} do
      test_pid = self()
      gate = make_ref()

      Hooks.register(hooks, :after_save, fn _buf, path ->
        send(test_pid, {gate, :old_started, path, self()})

        receive do
          {^gate, :release} -> :ok
        end
      end)

      Hooks.run(hooks, :after_save, [:buf, "/running"])
      assert_receive {^gate, :old_started, "/running", old_runner}, 500
      Hooks.run(hooks, :after_save, [:buf, "/queued-before-reset"])

      Hooks.reset(hooks)

      Hooks.register(hooks, :after_save, fn _buf, path ->
        send(test_pid, {gate, :new_started, path})
      end)

      Hooks.run(hooks, :after_save, [:buf, "/after-reload"])
      :sys.get_state(hooks)

      send(old_runner, {gate, :release})
      assert_receive {^gate, :new_started, "/after-reload"}, 500
      :sys.get_state(hooks)
      refute_received {^gate, :new_started, "/queued-before-reset"}
    end
  end

  describe "events registry integration" do
    test "buffer_saved event triggers after_save hooks through the configured registry", %{
      registry: registry,
      hooks: hooks
    } do
      buf = self()
      test_pid = self()
      ref = make_ref()

      Hooks.register(hooks, :after_save, fn buf_arg, path ->
        send(test_pid, {ref, :hook_via_bus, buf_arg, path})
      end)

      Events.broadcast(:buffer_saved, %Events.BufferEvent{buffer: buf, path: "/via/bus.ex"},
        registry: registry
      )

      assert_receive {^ref, :hook_via_bus, ^buf, "/via/bus.ex"}, 500
    end

    test "buffer_opened event triggers after_open hooks through the configured registry", %{
      registry: registry,
      hooks: hooks
    } do
      buf = self()
      test_pid = self()
      ref = make_ref()

      Hooks.register(hooks, :after_open, fn buf_arg, path ->
        send(test_pid, {ref, :open_hook, buf_arg, path})
      end)

      Events.broadcast(:buffer_opened, %Events.BufferEvent{buffer: buf, path: "/opened.ex"},
        registry: registry
      )

      assert_receive {^ref, :open_hook, ^buf, "/opened.ex"}, 500
    end

    test "mode_changed event triggers on_mode_change hooks through the configured registry", %{
      registry: registry,
      hooks: hooks
    } do
      test_pid = self()
      ref = make_ref()

      Hooks.register(hooks, :on_mode_change, fn old, new ->
        send(test_pid, {ref, :mode_hook, old, new})
      end)

      Events.broadcast(:mode_changed, %Events.ModeEvent{old: :normal, new: :visual},
        registry: registry
      )

      assert_receive {^ref, :mode_hook, :normal, :visual}, 500
    end
  end
end
