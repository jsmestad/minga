defmodule MingaEditor.State.BuffersTest do
  use ExUnit.Case, async: true

  alias MingaEditor.State.Buffers

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
