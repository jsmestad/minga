defmodule Minga.Config.HooksRegistryTest do
  use ExUnit.Case, async: true

  alias Minga.Config.Hooks
  alias Minga.Events

  defp start_registry(label) do
    name = :"#{label}_#{System.unique_integer([:positive])}"
    start_supervised!({Events, name: name})
    name
  end

  defp fake_buffer do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)

    on_exit(fn ->
      if Process.alive?(pid), do: send(pid, :stop)
    end)

    pid
  end

  test "hooks receive events from their configured registry only" do
    registry_a = start_registry(:hooks_events_a)
    registry_b = start_registry(:hooks_events_b)
    hooks_name = :"hooks_#{System.unique_integer([:positive])}"
    {:ok, hooks} = start_supervised({Hooks, name: hooks_name, events_registry: registry_a})
    test_pid = self()
    buf = fake_buffer()

    Hooks.register(hooks_name, :after_save, fn buf_arg, path ->
      send(test_pid, {:hook_fired, buf_arg, path})
    end)

    Events.broadcast(
      :buffer_saved,
      %Events.BufferEvent{buffer: buf, path: "/wrong.ex"},
      registry_b
    )

    _ = :sys.get_state(hooks)
    refute_receive {:hook_fired, ^buf, "/wrong.ex"}, 50

    Events.broadcast(
      :buffer_saved,
      %Events.BufferEvent{buffer: buf, path: "/right.ex"},
      registry_a
    )

    assert_receive {:hook_fired, ^buf, "/right.ex"}, 500
  end
end
