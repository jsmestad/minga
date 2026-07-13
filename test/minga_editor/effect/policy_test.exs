defmodule MingaEditor.Effect.PolicyTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Effect.Policy

  test "FIFO queue bounds fit the operation feedback wire contract" do
    assert %Policy{mode: :fifo, max_queued: 0} = Policy.fifo(0)
    assert %Policy{mode: :fifo, max_queued: 0xFFFF} = Policy.fifo(0xFFFF)

    assert_raise ArgumentError, fn -> Policy.fifo(-1) end
    assert_raise ArgumentError, fn -> Policy.fifo(0x10000) end
  end

  test "coalescing queue bounds fit the operation feedback wire contract" do
    assert %Policy{mode: :coalescing, max_queued: 1} = Policy.coalescing(1)

    assert %Policy{mode: :coalescing, max_queued: 0xFFFF} =
             Policy.coalescing(0xFFFF)

    assert_raise ArgumentError, fn -> Policy.coalescing(0) end
    assert_raise ArgumentError, fn -> Policy.coalescing(0x10000) end
  end
end
