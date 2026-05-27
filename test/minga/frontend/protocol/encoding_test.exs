defmodule Minga.Frontend.Protocol.EncodingTest do
  use ExUnit.Case, async: true

  alias Minga.Frontend.Protocol.Encoding

  describe "encode_section/2" do
    test "encodes section_id and length-prefixed payload" do
      result = Encoding.encode_section(0x01, <<0xAA, 0xBB>>)
      assert <<0x01, 0x00, 0x02, 0xAA, 0xBB>> = result
    end

    test "encodes section_id with known payload" do
      payload = "hello"
      result = Encoding.encode_section(0x05, payload)
      assert <<0x05, len::16, body::binary>> = result
      assert len == 5
      assert body == "hello"
    end

    test "handles empty payload" do
      result = Encoding.encode_section(0xFF, <<>>)
      assert <<0xFF, 0::16>> = result
    end
  end

  describe "encode_string16/1" do
    test "encodes a string with 16-bit length prefix" do
      result = Encoding.encode_string16("hi")
      assert <<2::16, "hi">> = result
    end

    test "handles empty string" do
      result = Encoding.encode_string16("")
      assert <<0::16>> = result
    end
  end

  describe "utf8_prefix_bytes/2" do
    test "returns full string when within limit" do
      assert Encoding.utf8_prefix_bytes("hello", 10) == "hello"
    end

    test "returns full string when exactly at limit" do
      assert Encoding.utf8_prefix_bytes("hello", 5) == "hello"
    end

    test "truncates string over limit with suffix" do
      long = String.duplicate("a", 100)
      result = Encoding.utf8_prefix_bytes(long, 20)
      assert byte_size(result) <= 20
      assert String.valid?(result)
      assert String.ends_with?(result, "[truncated]")
    end

    test "handles empty string" do
      assert Encoding.utf8_prefix_bytes("", 10) == ""
    end

    test "preserves UTF-8 boundary on multibyte characters" do
      # Each emoji is 4 bytes. "🎉🎉🎉" is 12 bytes.
      text = "🎉🎉🎉"
      result = Encoding.utf8_prefix_bytes(text, 5)
      assert String.valid?(result)
      # Should keep only the first emoji (4 bytes) since 5 bytes isn't enough
      # for the truncation suffix, it falls into the valid_utf8_prefix path
      assert byte_size(result) <= 5
    end

    test "handles very small max_bytes" do
      result = Encoding.utf8_prefix_bytes("hello world", 1)
      assert byte_size(result) <= 1
      assert String.valid?(result)
    end
  end

  describe "bool_to_byte/1" do
    test "true returns 1" do
      assert Encoding.bool_to_byte(true) == 1
    end

    test "false returns 0" do
      assert Encoding.bool_to_byte(false) == 0
    end

    test "nil returns 0" do
      assert Encoding.bool_to_byte(nil) == 0
    end
  end
end
