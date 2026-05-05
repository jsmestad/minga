defmodule Minga.EventsPrivateRegistryTest do
  use ExUnit.Case, async: true

  alias Minga.Events

  test "subscribes and broadcasts through a private registry", context do
    registry = Module.concat([context.module, context.test, Events])
    start_supervised!({Events, name: registry})

    Events.subscribe(:buffer_saved, registry: registry)

    Events.broadcast(:buffer_saved, %Events.BufferEvent{buffer: self(), path: "/private.ex"},
      registry: registry
    )

    assert_receive {:minga_event, :buffer_saved,
                    %Events.BufferEvent{buffer: pid, path: "/private.ex"}},
                   500

    assert pid == self()
  end
end
