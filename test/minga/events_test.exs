defmodule Minga.EventsTest do
  use ExUnit.Case, async: true

  alias Minga.Events

  setup do
    registry = :"events_test_#{System.unique_integer([:positive])}"
    start_supervised!({Events, name: registry})
    %{registry: registry}
  end

  test "subscribers receive typed broadcasts and can unsubscribe", %{registry: registry} do
    assert :ok = Events.subscribe(:buffer_opened, registry)
    payload = %Events.BufferEvent{buffer: self(), path: "/tmp/test.ex"}

    assert payload.history_attribution == :active_workspace
    assert :ok = Events.broadcast(:buffer_opened, payload, registry)
    assert_receive {:minga_event, :buffer_opened, ^payload}
    assert self() in Events.subscribers(:buffer_opened, registry)

    assert :ok = Events.unsubscribe(:buffer_opened, registry)
    assert :ok = Events.broadcast(:buffer_opened, payload, registry)
    refute_receive {:minga_event, :buffer_opened, _payload}
  end

  test "duplicate subscriptions with metadata deliver once", %{registry: registry} do
    assert :ok = Events.subscribe(:mode_changed, :editor, registry)
    assert :ok = Events.subscribe(:mode_changed, :editor, registry)
    payload = %Events.ModeEvent{old: :normal, new: :insert}

    assert :ok = Events.broadcast(:mode_changed, payload, registry)
    assert_receive {:minga_event, :mode_changed, ^payload}
    refute_receive {:minga_event, :mode_changed, _payload}
  end
end
