defmodule Minga.LSP.JsonRpcTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Minga.LSP.JsonRpc

  describe "encode_request/3" do
    test "produces valid Content-Length framed JSON-RPC request" do
      msg = JsonRpc.encode_request(1, "initialize", %{"rootUri" => "file:///tmp"})
      binary = IO.iodata_to_binary(msg)

      assert binary =~ "Content-Length: "
      assert binary =~ "\r\n\r\n"

      [_headers, json] = String.split(binary, "\r\n\r\n", parts: 2)
      decoded = JSON.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "initialize"
      assert decoded["params"]["rootUri"] == "file:///tmp"
    end

    test "content length matches actual JSON body size" do
      msg = JsonRpc.encode_request(42, "textDocument/didOpen", %{"uri" => "file:///foo.ex"})
      binary = IO.iodata_to_binary(msg)

      [headers, json] = String.split(binary, "\r\n\r\n", parts: 2)
      [length_header] = String.split(headers, "\r\n")
      "Content-Length: " <> length_str = length_header
      {declared_length, ""} = Integer.parse(length_str)

      assert declared_length == byte_size(json)
    end
  end

  describe "encode_notification/2" do
    test "produces JSON-RPC notification without id" do
      msg = JsonRpc.encode_notification("initialized", %{})
      binary = IO.iodata_to_binary(msg)

      [_headers, json] = String.split(binary, "\r\n\r\n", parts: 2)
      decoded = JSON.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["method"] == "initialized"
      refute Map.has_key?(decoded, "id")
    end
  end

  describe "encode_response/2" do
    test "produces JSON-RPC success response" do
      msg = JsonRpc.encode_response(1, %{"capabilities" => %{}})
      binary = IO.iodata_to_binary(msg)

      [_headers, json] = String.split(binary, "\r\n\r\n", parts: 2)
      decoded = JSON.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["result"] == %{"capabilities" => %{}}
      refute Map.has_key?(decoded, "error")
    end

    test "accepts list results" do
      msg = JsonRpc.encode_response(2, [%{"enabled" => true}, %{}])
      binary = IO.iodata_to_binary(msg)

      [_headers, json] = String.split(binary, "\r\n\r\n", parts: 2)
      decoded = JSON.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 2
      assert decoded["result"] == [%{"enabled" => true}, %{}]
    end

    test "accepts string ids" do
      msg = JsonRpc.encode_response("configuration-1", [%{}])
      binary = IO.iodata_to_binary(msg)

      [_headers, json] = String.split(binary, "\r\n\r\n", parts: 2)
      decoded = JSON.decode!(json)

      assert decoded["id"] == "configuration-1"
      assert decoded["result"] == [%{}]
    end

    test "accepts nil results" do
      msg = JsonRpc.encode_response(3, nil)
      binary = IO.iodata_to_binary(msg)

      [_headers, json] = String.split(binary, "\r\n\r\n", parts: 2)
      decoded = JSON.decode!(json)

      assert decoded["id"] == 3
      assert Map.has_key?(decoded, "result")
      assert decoded["result"] == nil
    end
  end

  describe "encode_error_response/3" do
    test "produces JSON-RPC error response" do
      msg = JsonRpc.encode_error_response(1, -32_600, "Invalid Request")
      binary = IO.iodata_to_binary(msg)

      [_headers, json] = String.split(binary, "\r\n\r\n", parts: 2)
      decoded = JSON.decode!(json)

      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["error"]["code"] == -32_600
      assert decoded["error"]["message"] == "Invalid Request"
    end

    test "accepts string ids" do
      msg = JsonRpc.encode_error_response("unknown-1", -32_601, "Method not found")
      binary = IO.iodata_to_binary(msg)

      [_headers, json] = String.split(binary, "\r\n\r\n", parts: 2)
      decoded = JSON.decode!(json)

      assert decoded["id"] == "unknown-1"
      assert decoded["error"]["code"] == -32_601
      assert decoded["error"]["message"] == "Method not found"
    end
  end

  describe "decode/1" do
    test "decodes a single complete message" do
      encoded = IO.iodata_to_binary(JsonRpc.encode_notification("test/method", %{"key" => "val"}))

      {messages, rest} = JsonRpc.decode(encoded)

      assert Enum.count(messages) == 1
      assert hd(messages)["method"] == "test/method"
      assert hd(messages)["params"]["key"] == "val"
      assert rest == ""
    end

    test "decodes multiple messages in one buffer" do
      msg1 = IO.iodata_to_binary(JsonRpc.encode_notification("first", %{}))
      msg2 = IO.iodata_to_binary(JsonRpc.encode_notification("second", %{}))
      buffer = msg1 <> msg2

      {messages, rest} = JsonRpc.decode(buffer)

      assert Enum.count(messages) == 2
      assert Enum.at(messages, 0)["method"] == "first"
      assert Enum.at(messages, 1)["method"] == "second"
      assert rest == ""
    end

    test "returns incomplete when headers are partial" do
      {messages, rest} = JsonRpc.decode("Content-Len")

      assert messages == []
      assert rest == "Content-Len"
    end

    test "returns incomplete when body is partial" do
      json = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "test", "params" => %{}})
      # Declare full length but only provide partial body
      buffer = "Content-Length: #{byte_size(json)}\r\n\r\n" <> binary_part(json, 0, 5)

      {messages, rest} = JsonRpc.decode(buffer)

      assert messages == []
      assert rest == buffer
    end

    test "drops complete header block without Content-Length and decodes following message" do
      valid = IO.iodata_to_binary(JsonRpc.encode_notification("valid", %{}))
      buffer = "X-Other: 1\r\n\r\n" <> valid

      log =
        capture_log(fn ->
          {[decoded], rest} = JsonRpc.decode(buffer)

          assert decoded["method"] == "valid"
          assert rest == ""
        end)

      assert log =~ "dropped a complete header block"
      assert log =~ "Content-Length"
    end

    test "drops complete header block with invalid Content-Length and decodes following message" do
      valid = IO.iodata_to_binary(JsonRpc.encode_notification("valid", %{}))
      buffer = "Content-Length: nope\r\n\r\n" <> valid

      log =
        capture_log(fn ->
          {[decoded], rest} = JsonRpc.decode(buffer)

          assert decoded["method"] == "valid"
          assert rest == ""
        end)

      assert log =~ "dropped a complete header block"
      assert log =~ "Content-Length"
    end

    test "raises on malformed JSON bodies" do
      buffer = "Content-Length: 1\r\n\r\n{"

      assert_raise JSON.DecodeError, fn ->
        JsonRpc.decode(buffer)
      end
    end

    test "handles message followed by partial message" do
      complete = IO.iodata_to_binary(JsonRpc.encode_notification("complete", %{}))
      partial = "Content-Length: 100\r\n\r\n{\"partial\":"

      buffer = complete <> partial

      {messages, rest} = JsonRpc.decode(buffer)

      assert Enum.count(messages) == 1
      assert hd(messages)["method"] == "complete"
      assert rest == partial
    end

    test "handles empty buffer" do
      {messages, rest} = JsonRpc.decode("")

      assert messages == []
      assert rest == ""
    end

    test "round-trips request messages" do
      original =
        JsonRpc.encode_request(42, "textDocument/completion", %{
          "position" => %{"line" => 10, "character" => 5}
        })

      binary = IO.iodata_to_binary(original)

      {[decoded], ""} = JsonRpc.decode(binary)

      assert decoded["id"] == 42
      assert decoded["method"] == "textDocument/completion"
      assert decoded["params"]["position"]["line"] == 10
    end

    test "round-trips response messages" do
      original = JsonRpc.encode_response(7, %{"items" => [%{"label" => "defmodule"}]})
      binary = IO.iodata_to_binary(original)

      {[decoded], ""} = JsonRpc.decode(binary)

      assert decoded["id"] == 7
      assert decoded["result"]["items"] == [%{"label" => "defmodule"}]
    end

    test "handles unicode in message body" do
      msg = JsonRpc.encode_notification("test", %{"text" => "héllo wörld 🎉"})
      binary = IO.iodata_to_binary(msg)

      {[decoded], ""} = JsonRpc.decode(binary)

      assert decoded["params"]["text"] == "héllo wörld 🎉"
    end

    test "handles messages with multiple headers" do
      # Some LSP servers send Content-Type header too
      json = JSON.encode!(%{"jsonrpc" => "2.0", "method" => "test", "params" => %{}})

      buffer =
        "Content-Length: #{byte_size(json)}\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n" <>
          json

      {[decoded], ""} = JsonRpc.decode(buffer)

      assert decoded["method"] == "test"
    end
  end

  describe "decode/1 framing limits" do
    test "rejects buffer exceeding max buffer size" do
      # 52 MiB + 1 byte exceeds the 52 MiB buffer limit
      oversized = :binary.copy(<<0>>, 52_000_001)

      assert {:error, :buffer_overflow} = JsonRpc.decode(oversized)
    end

    test "rejects Content-Length exceeding max body size" do
      # Claim a 50 MiB + 1 body. Only the header needs to be present for the check.
      content_length = 50_000_001
      buffer = "Content-Length: #{content_length}\r\n\r\n"

      assert {:error, {:body_too_large, ^content_length}} = JsonRpc.decode(buffer)
    end

    test "rejects headers exceeding max header size" do
      # Build a headers section larger than 8 KiB
      padding = :binary.copy("X-Pad: " <> :binary.copy("a", 200) <> "\r\n", 50)
      buffer = padding <> "Content-Length: 2\r\n\r\n{}"

      header_size = byte_size(padding <> "Content-Length: 2")
      assert header_size > 8_192

      assert {:error, {:headers_too_large, _}} = JsonRpc.decode(buffer)
    end

    test "rejects an unterminated header block once it exceeds the header limit" do
      # No blank line has arrived, so every retained byte belongs to the header block.
      buffer = "Content-Length: 2\r\nX-Pad: " <> :binary.copy("a", 8_192)

      assert {:error, {:headers_too_large, size}} = JsonRpc.decode(buffer)
      assert size == byte_size(buffer)
    end

    test "keeps an unterminated header block that is still within the header limit" do
      # The limit plus a partial terminator is the longest prefix of a valid header block.
      buffer = "Content-Length: 2\r\nX-Pad: " <> :binary.copy("a", 8_192 - 26) <> "\r\n\r"
      assert byte_size(buffer) == 8_192 + 3

      assert {[], ^buffer} = JsonRpc.decode(buffer)
      assert {[%{}], ""} = JsonRpc.decode(buffer <> "\n{}")
    end

    test "accepts normal messages within all limits" do
      encoded = IO.iodata_to_binary(JsonRpc.encode_notification("test", %{"ok" => true}))

      assert {[%{"method" => "test"}], ""} = JsonRpc.decode(encoded)
    end

    test "accepts partial frames within buffer limit" do
      # A partial frame within limits should still return :incomplete, not error
      partial = "Content-Length: 100\r\n\r\n{\"partial\":"

      assert {[], ^partial} = JsonRpc.decode(partial)
    end

    test "returns error mid-stream when second frame has oversized body" do
      valid = IO.iodata_to_binary(JsonRpc.encode_notification("first", %{}))
      oversized_header = "Content-Length: 50000001\r\n\r\n"
      buffer = valid <> oversized_header

      assert {:error, {:body_too_large, 50_000_001}} = JsonRpc.decode(buffer)
    end
  end
end
