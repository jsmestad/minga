defmodule Minga.Parser.ProtocolStructuralNavTest do
  use ExUnit.Case, async: true

  alias Minga.Parser.Protocol
  alias Minga.Parser.StructuralNavResult

  @op_request_structural_nav 0x2F
  @op_node_info 0x3D

  describe "request_structural_nav" do
    test "encodes buffer id, request id, row, column, and action" do
      assert <<@op_request_structural_nav, 7::32, 42::32, 3::32, 11::32, 2>> =
               Protocol.encode_request_structural_nav(7, 42, 3, 11, 2)
    end

    test "decodes a found node_info response" do
      payload =
        <<@op_node_info, 42::32, 1, 1::32, 2::32, 3::32, 4::32, 15::16, "call_expression">>

      assert {:ok, {:node_info, 42, result}} = Protocol.decode_event(payload)
      assert %StructuralNavResult{} = result
      assert result.start_row == 1
      assert result.start_col == 2
      assert result.end_row == 3
      assert result.end_col == 4
      assert result.type_name == "call_expression"
    end

    test "decodes an empty node_info response" do
      payload = <<@op_node_info, 42::32, 0>>
      assert {:ok, {:node_info, 42, nil}} = Protocol.decode_event(payload)
    end
  end
end
