defmodule Minga.Frontend.Adapter.GUI.WireTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Adapter.GUI.EncodingError
  alias Minga.Frontend.Adapter.GUI.Wire

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
end
