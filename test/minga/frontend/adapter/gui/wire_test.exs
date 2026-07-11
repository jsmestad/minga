defmodule Minga.Frontend.Adapter.GUI.WireTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Frontend.Adapter.GUI.Wire.Writer

  test "section carrier rejects an oversized payload with structured metadata" do
    error =
      assert_raise EncodingError, fn ->
        Wire.encode_section(1, String.duplicate("x", Wire.max_u16() + 1))
      end

    assert %{command: :gui_section, field: :payload_length, actual: 65_536, min: 0, max: 65_535} =
             error
  end

  test "string carriers reject oversized values with their wire limit" do
    error = assert_raise EncodingError, fn -> Wire.encode_string8(String.duplicate("x", 256)) end
    assert %{command: :gui_string, field: :byte_length, actual: 256, max: 255} = error

    error =
      assert_raise EncodingError, fn -> Wire.encode_string16(String.duplicate("x", 65_536)) end

    assert %{command: :gui_string, field: :byte_length, actual: 65_536, max: 65_535} = error
  end

  test "formerly lossy helpers reject values instead of changing wire content" do
    assert %{command: :gui_wire, field: :u8_value, actual: 256, min: 0, max: 255} =
             assert_raise(EncodingError, fn -> Wire.clamp_u8(256) end)

    assert %{command: :gui_wire, field: :utf8_byte_length, actual: 256, min: 0, max: 255} =
             assert_raise(EncodingError, fn ->
               Wire.utf8_prefix_bytes(String.duplicate("x", 256), 255)
             end)

    assert %{command: :gui_wire, field: :entry_count, actual: 2, min: 0, max: 1} =
             assert_raise(EncodingError, fn ->
               Wire.bounded_entries(["one", "two"], & &1, 1, 10)
             end)

    assert %{command: :gui_wire, field: :entry_bytes, actual: 4, min: 0, max: 3} =
             assert_raise(EncodingError, fn -> Wire.bounded_entries(["four"], & &1, 1, 3) end)
  end

  test "command-scoped writer carries field metadata through checked packing" do
    assert <<1::8, 2::16, 3::32, 2::8, "ok">> ==
             :gui_test
             |> Writer.new()
             |> Writer.uint8(:small, 1)
             |> Writer.uint16(:medium, 2)
             |> Writer.uint32(:large, 3)
             |> Writer.string8(:label, "ok")
             |> Writer.finish()

    assert %{command: :gui_test, field: :medium, actual: 65_536, min: 0, max: 65_535} =
             assert_raise(EncodingError, fn ->
               :gui_test |> Writer.new() |> Writer.uint16(:medium, 65_536)
             end)
  end

  test "writer packs signed, wide, color, and nested payload fields" do
    assert <<-1::signed-32, 4::64, 0x112233::24, 7::8, 2::16, "ok">> ==
             :gui_test
             |> Writer.new()
             |> Writer.int32(:offset, -1)
             |> Writer.uint64(:row_id, 4)
             |> Writer.rgb24(:foreground, 0x112233)
             |> Writer.section16(:payload, 7, "ok")
             |> Writer.finish()

    assert %{
             command: :gui_test,
             field: :offset,
             actual: 2_147_483_648,
             min: -2_147_483_648,
             max: 2_147_483_647
           } =
             assert_raise(EncodingError, fn ->
               :gui_test |> Writer.new() |> Writer.int32(:offset, 2_147_483_648)
             end)

    assert %{command: :gui_test, field: :foreground, actual: 16_777_216, min: 0, max: 16_777_215} =
             assert_raise(EncodingError, fn ->
               :gui_test |> Writer.new() |> Writer.rgb24(:foreground, 16_777_216)
             end)
  end

  test "writer validation-only checks preserve the output" do
    assert "payload" ==
             :gui_test
             |> Writer.new()
             |> Writer.check_uint8(:small, 1)
             |> Writer.check_uint16(:medium, 2)
             |> Writer.check_uint32(:large, 3)
             |> Writer.check_uint64(:row_id, 4)
             |> Writer.append("payload")
             |> Writer.finish()

    assert %{
             command: :gui_test,
             field: :row_id,
             actual: -1,
             min: 0,
             max: 18_446_744_073_709_551_615
           } =
             assert_raise(EncodingError, fn ->
               :gui_test |> Writer.new() |> Writer.check_uint64(:row_id, -1)
             end)
  end
end
