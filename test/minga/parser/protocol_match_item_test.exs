defmodule Minga.Parser.ProtocolMatchItemTest do
  use ExUnit.Case, async: true

  alias Minga.Parser.Protocol

  @op_request_match_item 0x2E
  @op_match_item_result 0x3C

  describe "request_match_item" do
    test "encodes buffer id, request id, row, and column" do
      assert <<@op_request_match_item, 7::32, 42::32, 3::32, 11::32>> =
               Protocol.encode_request_match_item(7, 42, 3, 11)
    end

    test "decodes a found match_item_result" do
      payload = <<@op_match_item_result, 42::32, 1, 9::32, 4::32>>
      assert {:ok, {:match_item_result, 42, {9, 4}}} = Protocol.decode_event(payload)
    end

    test "decodes an empty match_item_result" do
      payload = <<@op_match_item_result, 42::32, 0>>
      assert {:ok, {:match_item_result, 42, nil}} = Protocol.decode_event(payload)
    end
  end
end
