defmodule Minga.EventsRegistryTest do
  use ExUnit.Case, async: true

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

  test "broadcast only reaches subscribers registered with the same registry" do
    registry_a = start_registry(:events_a)
    registry_b = start_registry(:events_b)
    buf = fake_buffer()

    Events.subscribe(:buffer_saved, registry_a)

    Events.broadcast(
      :buffer_saved,
      %Events.BufferEvent{buffer: buf, path: "/wrong.ex"},
      registry_b
    )

    refute_receive {:minga_event, :buffer_saved, _}, 50

    Events.broadcast(
      :buffer_saved,
      %Events.BufferEvent{buffer: buf, path: "/right.ex"},
      registry_a
    )

    assert_receive {:minga_event, :buffer_saved,
                    %Events.BufferEvent{buffer: ^buf, path: "/right.ex"}}
  end

  test "subscribers are scoped by registry" do
    registry_a = start_registry(:events_a)
    registry_b = start_registry(:events_b)

    Events.subscribe(:buffer_saved, registry_a)

    assert self() in Events.subscribers(:buffer_saved, registry_a)
    refute self() in Events.subscribers(:buffer_saved, registry_b)
  end

  test "metadata de-duplication still works on a custom registry" do
    registry = start_registry(:events_metadata)

    Events.subscribe(:mode_changed, :my_component, registry)
    Events.subscribe(:mode_changed, :my_component, registry)

    Events.broadcast(
      :mode_changed,
      %Events.ModeEvent{old: :normal, new: :insert},
      registry
    )

    assert_receive {:minga_event, :mode_changed, %Events.ModeEvent{old: :normal, new: :insert}}
    refute_receive {:minga_event, :mode_changed, _}, 50
  end
end
