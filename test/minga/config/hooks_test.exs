defmodule Minga.Config.HooksTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Hooks
  alias Minga.Events

  setup context do
    registry = Module.concat([context.module, context.test, Events])
    hooks = Module.concat([context.module, context.test, Hooks])

    start_supervised!({Events, name: registry})
    start_supervised!({Hooks, name: hooks, events_registry: registry})

    {:ok, registry: registry, hooks: hooks}
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

  describe "reset/1" do
    test "removes all hooks", %{hooks: hooks} do
      test_pid = self()
      ref = make_ref()
      Hooks.register(hooks, :after_save, fn _, _ -> send(test_pid, {ref, :should_not_fire}) end)
      Hooks.reset(hooks)

      Hooks.run(hooks, :after_save, [:buf, "/path"])
      :sys.get_state(hooks)

      refute_receive {^ref, :should_not_fire}, 100
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
