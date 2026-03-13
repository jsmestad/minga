defmodule Minga.Port.ProtocolTextobjectPositionsTest do
  @moduledoc """
  Tests for decoding the `TEXTOBJECT_POSITIONS` (0x39) opcode.
  """
  use ExUnit.Case, async: true

  alias Minga.Port.Protocol

  @op_textobject_positions 0x39

  # Type IDs matching Zig constants
  @textobj_function 0
  @textobj_class 1
  @textobj_parameter 2
  @textobj_block 3
  @textobj_comment 4
  @textobj_test 5

  defp encode_entry(type_id, row, col) do
    <<type_id::8, row::32, col::32>>
  end

  describe "decode_event/1 — textobject_positions (0x39)" do
    test "decodes empty positions" do
      payload = <<@op_textobject_positions, 1::32, 0::32>>

      assert {:ok, {:textobject_positions, 1, positions}} = Protocol.decode_event(payload)
      assert positions == %{}
    end

    test "decodes single function entry" do
      entry = encode_entry(@textobj_function, 5, 0)
      payload = <<@op_textobject_positions, 42::32, 1::32, entry::binary>>

      assert {:ok, {:textobject_positions, 42, positions}} = Protocol.decode_event(payload)
      assert positions == %{function: [{5, 0}]}
    end

    test "decodes multiple entries of the same type" do
      entries =
        encode_entry(@textobj_function, 0, 0) <>
          encode_entry(@textobj_function, 5, 0) <>
          encode_entry(@textobj_function, 10, 4)

      payload = <<@op_textobject_positions, 1::32, 3::32, entries::binary>>

      assert {:ok, {:textobject_positions, 1, positions}} = Protocol.decode_event(payload)
      assert positions == %{function: [{0, 0}, {5, 0}, {10, 4}]}
    end

    test "decodes entries of different types" do
      entries =
        encode_entry(@textobj_function, 1, 0) <>
          encode_entry(@textobj_class, 5, 2) <>
          encode_entry(@textobj_parameter, 3, 10)

      payload = <<@op_textobject_positions, 7::32, 3::32, entries::binary>>

      assert {:ok, {:textobject_positions, 7, positions}} = Protocol.decode_event(payload)
      assert positions == %{function: [{1, 0}], class: [{5, 2}], parameter: [{3, 10}]}
    end

    test "decodes all six known type IDs" do
      entries =
        encode_entry(@textobj_function, 0, 0) <>
          encode_entry(@textobj_class, 1, 0) <>
          encode_entry(@textobj_parameter, 2, 0) <>
          encode_entry(@textobj_block, 3, 0) <>
          encode_entry(@textobj_comment, 4, 0) <>
          encode_entry(@textobj_test, 5, 0)

      payload = <<@op_textobject_positions, 1::32, 6::32, entries::binary>>

      assert {:ok, {:textobject_positions, 1, positions}} = Protocol.decode_event(payload)
      assert Map.has_key?(positions, :function)
      assert Map.has_key?(positions, :class)
      assert Map.has_key?(positions, :parameter)
      assert Map.has_key?(positions, :block)
      assert Map.has_key?(positions, :comment)
      assert Map.has_key?(positions, :test)
    end

    test "unknown type ID decodes as :unknown" do
      entry = encode_entry(255, 0, 0)
      payload = <<@op_textobject_positions, 1::32, 1::32, entry::binary>>

      assert {:ok, {:textobject_positions, 1, positions}} = Protocol.decode_event(payload)
      assert Map.has_key?(positions, :unknown)
    end

    test "preserves entry order (Zig sends sorted by row, col)" do
      entries =
        encode_entry(@textobj_function, 0, 5) <>
          encode_entry(@textobj_function, 0, 15) <>
          encode_entry(@textobj_function, 3, 0) <>
          encode_entry(@textobj_function, 10, 2)

      payload = <<@op_textobject_positions, 1::32, 4::32, entries::binary>>

      assert {:ok, {:textobject_positions, 1, positions}} = Protocol.decode_event(payload)
      assert positions[:function] == [{0, 5}, {0, 15}, {3, 0}, {10, 2}]
    end

    test "version counter is preserved" do
      payload = <<@op_textobject_positions, 999::32, 0::32>>

      assert {:ok, {:textobject_positions, 999, _positions}} = Protocol.decode_event(payload)
    end
  end
end
