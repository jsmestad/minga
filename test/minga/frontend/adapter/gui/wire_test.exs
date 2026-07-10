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
end
