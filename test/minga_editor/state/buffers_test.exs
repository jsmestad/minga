defmodule MingaEditor.State.BuffersTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Buffers

  describe "remove/2" do
    test "removes pid from list and selects neighbor" do
      bs = %Buffers{list: [:a, :b, :c], active: :b, active_index: 1}
      result = Buffers.remove(bs, :b)

      assert result.list == [:a, :c]
      assert result.active == :c
      assert result.active_index == 1
    end

    test "removes only buffer leaving empty state" do
      bs = %Buffers{list: [:a], active: :a, active_index: 0}
      result = Buffers.remove(bs, :a)

      assert result.list == []
      assert result.active == nil
      assert result.active_index == 0
    end

    test "clears help slot when it matches" do
      bs = %Buffers{list: [:a, :h], active: :a, active_index: 0, help: :h}
      result = Buffers.remove(bs, :h)

      assert result.help == nil
      refute :h in result.list
    end

    test "no-op when pid is not present" do
      bs = %Buffers{list: [:a, :b], active: :a, active_index: 0}
      result = Buffers.remove(bs, :z)

      assert result == bs
    end

    test "clamps active_index when last element is removed" do
      bs = %Buffers{list: [:a, :b, :c], active: :c, active_index: 2}
      result = Buffers.remove(bs, :c)

      assert result.list == [:a, :b]
      assert result.active == :b
      assert result.active_index == 1
    end
  end

  describe "add_background/2" do
    test "appends pid without changing active or active_index" do
      bs = %Buffers{list: [:existing], active: :existing, active_index: 0}
      result = Buffers.add_background(bs, :new_pid)

      assert result.list == [:existing, :new_pid]
      assert result.active == :existing
      assert result.active_index == 0
    end

    test "on empty list appends pid with active still nil" do
      bs = %Buffers{}
      result = Buffers.add_background(bs, :new_pid)

      assert result.list == [:new_pid]
      assert result.active == nil
      assert result.active_index == 0
    end

    test "contrast with add which switches active" do
      bs = %Buffers{list: [:existing], active: :existing, active_index: 0}

      bg_result = Buffers.add_background(bs, :bg_pid)
      assert bg_result.active == :existing

      add_result = Buffers.add(bs, :add_pid)
      assert add_result.active == :add_pid
    end
  end
end
