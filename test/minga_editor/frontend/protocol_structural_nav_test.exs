defmodule MingaEditor.Frontend.ProtocolStructuralNavTest do
  use ExUnit.Case, async: true

  alias Minga.Parser.StructuralNavResult
  alias MingaEditor.Frontend.Protocol

  test "decode_event accepts found node_info responses" do
    payload = <<0x3D, 42::32, 1, 1::32, 2::32, 3::32, 4::32, 15::16, "call_expression">>

    assert {:ok, {:node_info, 42, %StructuralNavResult{} = result}} =
             Protocol.decode_event(payload)

    assert result == %StructuralNavResult{
             start_row: 1,
             start_col: 2,
             end_row: 3,
             end_col: 4,
             type_name: "call_expression"
           }
  end

  test "decode_event accepts empty node_info responses" do
    payload = <<0x3D, 42::32, 0>>

    assert {:ok, {:node_info, 42, nil}} = Protocol.decode_event(payload)
  end

  test "encode_request_structural_nav encodes the structural nav request payload" do
    assert Protocol.encode_request_structural_nav(7, 42, 3, 11, 2) ==
             <<0x2F, 7::32, 42::32, 3::32, 11::32, 2::8>>
  end
end
