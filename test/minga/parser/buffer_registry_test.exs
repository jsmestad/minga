defmodule Minga.Parser.BufferRegistryTest do
  use ExUnit.Case, async: true

  alias Minga.Parser.BufferConfig
  alias Minga.Parser.BufferRegistration
  alias Minga.Parser.BufferRegistry

  test "a stale synchronization update cannot replace current identity or remove its monitor" do
    buffer = self()
    monitor = make_ref()
    config = %BufferConfig{language: "elixir"}
    {first_id, :new, registry} = BufferRegistry.register(BufferRegistry.new(), buffer, config, 0)
    {:ok, stale} = BufferRegistry.fetch(registry, buffer)
    registry = BufferRegistry.put_monitor(registry, buffer, monitor)
    replacement = %{config | highlight_query: "(identifier) @variable"}

    {new_id, {:replaced, ^first_id}, registry} =
      BufferRegistry.register(registry, buffer, replacement, 1)

    {:ok, current} = BufferRegistry.fetch(registry, buffer)
    updated = BufferRegistration.mark_dirty(current, 7)

    registry = BufferRegistry.put(registry, buffer, updated)

    for mismatched <- [
          stale,
          %{updated | id: first_id},
          %{updated | generation: stale.generation},
          %{updated | config: config}
        ] do
      result = registry |> BufferRegistry.put(buffer, mismatched) |> BufferRegistry.fetch(buffer)
      assert {:ok, ^updated} = result
    end

    assert BufferRegistry.buffer_id(registry, buffer) == new_id
    assert BufferRegistry.resolve(registry, first_id) == nil
    assert BufferRegistry.resolve(registry, new_id) == buffer
    assert {^new_id, ^monitor, registry} = BufferRegistry.unregister(registry, buffer)
    assert BufferRegistry.resolve(registry, new_id) == nil
  end
end
