defmodule Minga.FontRegistryTest do
  use ExUnit.Case, async: true

  alias Minga.FontRegistry

  describe "new/0" do
    test "creates empty registry with next_id 1" do
      reg = FontRegistry.new()
      assert reg.families == %{}
      assert reg.next_id == 1
    end
  end

  describe "get_or_register/2" do
    test "assigns incrementing IDs to new families" do
      reg = FontRegistry.new()
      {id1, reg, true} = FontRegistry.get_or_register(reg, "Fira Code")
      {id2, reg, true} = FontRegistry.get_or_register(reg, "Source Code Pro")
      assert id1 == 1
      assert id2 == 2
      assert reg.next_id == 3
    end

    test "returns existing ID for already-registered family" do
      reg = FontRegistry.new()
      {id1, reg, true} = FontRegistry.get_or_register(reg, "Fira Code")
      {id2, _reg, false} = FontRegistry.get_or_register(reg, "Fira Code")
      assert id1 == id2
      assert id1 == 1
    end

    test "caps at 255 and falls back to 0" do
      reg = %FontRegistry{families: %{}, next_id: 256}
      {id, _reg, false} = FontRegistry.get_or_register(reg, "Overflow Font")
      assert id == 0
    end
  end

  describe "lookup/2" do
    test "returns 0 for unknown family" do
      reg = FontRegistry.new()
      assert FontRegistry.lookup(reg, "Unknown") == 0
    end

    test "returns registered ID" do
      reg = FontRegistry.new()
      {_id, reg, _} = FontRegistry.get_or_register(reg, "Fira Code")
      assert FontRegistry.lookup(reg, "Fira Code") == 1
    end
  end
end
