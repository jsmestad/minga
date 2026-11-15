defmodule Minga.RenderModel.Window.RowSlotAllocatorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Minga.RenderModel.Window.RowSlotAllocator

  test "retiring one scope preserves live identities and never recycles a retired slot" do
    scope = {1, 0, :normal}
    other_scope = {1, 1, :normal}
    {:ok, retired, allocator} = RowSlotAllocator.allocate(RowSlotAllocator.new(), scope, :retired)
    {:ok, live, allocator} = RowSlotAllocator.allocate(allocator, scope, :live)
    {:ok, other, allocator} = RowSlotAllocator.allocate(allocator, other_scope, :other)

    allocator = RowSlotAllocator.retain(allocator, scope, MapSet.new([:live]))
    assert {:ok, ^live, allocator} = RowSlotAllocator.allocate(allocator, scope, :live)
    assert {:ok, ^other, allocator} = RowSlotAllocator.allocate(allocator, other_scope, :other)
    assert {:ok, replacement, _allocator} = RowSlotAllocator.allocate(allocator, scope, :retired)
    assert replacement > max(retired, live)
  end

  property "constant-size hunk churn retains bounded metadata and monotonic identity" do
    check all(refreshes <- integer(1..150)) do
      scope = {1, 0, :normal}

      {:ok, baseline, initial} =
        RowSlotAllocator.allocate(RowSlotAllocator.new(), scope, :baseline)

      Enum.reduce(1..refreshes, {initial, baseline}, fn revision, {allocator, previous} ->
        key = {:hunk, revision}
        {:ok, current, allocator} = RowSlotAllocator.allocate(allocator, scope, key)
        allocator = RowSlotAllocator.retain(allocator, scope, MapSet.new([:baseline, key]))

        assert current > previous

        assert {:ok, ^baseline, _unchanged} =
                 RowSlotAllocator.allocate(allocator, scope, :baseline)

        assert map_size(allocator.slots) == 2
        assert map_size(allocator.next) == 1
        {allocator, current}
      end)
    end
  end

  test "retirement does not reopen exhausted capacity" do
    scope = {1, 0, :normal}
    allocator = %RowSlotAllocator{next: %{scope => 0x0FFF_FFFF}}
    assert {:ok, 0x0FFF_FFFF, allocator} = RowSlotAllocator.allocate(allocator, scope, :last)
    allocator = RowSlotAllocator.retain(allocator, scope, MapSet.new())
    assert RowSlotAllocator.allocate(allocator, scope, :last) == :reset_required
    assert RowSlotAllocator.allocate(allocator, scope, :new) == :reset_required
  end
end
