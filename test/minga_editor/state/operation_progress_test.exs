defmodule MingaEditor.State.OperationProgressTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.OperationProgress

  test "accepts zero through the wire-safe total" do
    assert {:ok, %OperationProgress{current: 0, total: 4}} = OperationProgress.new(0, 4)
    assert {:ok, %OperationProgress{current: 4, total: 4}} = OperationProgress.new(4, 4)

    assert {:ok, %OperationProgress{current: 0xFFFFFFFF, total: 0xFFFFFFFF}} =
             OperationProgress.new(0xFFFFFFFF, 0xFFFFFFFF)
  end

  test "rejects impossible progress ranges" do
    for {current, total} <- [{-1, 1}, {0, 0}, {2, 1}, {1, 0x100000000}] do
      assert {:error, :invalid_progress_range} = OperationProgress.new(current, total)
    end

    assert_raise ArgumentError, fn -> OperationProgress.new!(3, 2) end
  end
end
