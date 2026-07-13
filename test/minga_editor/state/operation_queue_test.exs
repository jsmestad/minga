defmodule MingaEditor.State.OperationQueueTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.OperationQueue

  test "accepts a positive position within the wire-safe queue total" do
    assert {:ok, %OperationQueue{position: 2, total: 3}} = OperationQueue.new(2, 3)

    assert {:ok, %OperationQueue{position: 0xFFFF, total: 0xFFFF}} =
             OperationQueue.new(0xFFFF, 0xFFFF)
  end

  test "rejects impossible queue ranges" do
    for {position, total} <- [{0, 1}, {1, 0}, {-1, 2}, {3, 2}, {1, 0x10000}] do
      assert {:error, :invalid_queue_range} = OperationQueue.new(position, total)
    end

    assert_raise ArgumentError, fn -> OperationQueue.new!(2, 1) end
  end
end
