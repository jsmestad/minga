defmodule Minga.LSP.JsonRpcTest do
  use ExUnit.Case, async: true

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
  end

  describe "decode/1" do
    test "decodes a single complete message" do
      encoded = IO.iodata_to_binary(JsonRpc.encode_notification("test/method", %{"key" => "val"}))

      {messages, rest} = JsonRpc.decode(encoded)

      assert length(messages) == 1
      assert hd(messages)["method"] == "test/method"
      assert hd(messages)["params"]["key"] == "val"
      assert rest == ""
    end

    test "decodes multiple messages in one buffer" do
      msg1 = IO.iodata_to_binary(JsonRpc.encode_notification("first", %{}))
      msg2 = IO.iodata_to_binary(JsonRpc.encode_notification("second", %{}))
      buffer = msg1 <> msg2

      {messages, rest} = JsonRpc.decode(buffer)

      assert length(messages) == 2
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

    test "handles message followed by partial message" do
      complete = IO.iodata_to_binary(JsonRpc.encode_notification("complete", %{}))
      partial = "Content-Length: 100\r\n\r\n{\"partial\":"

      buffer = complete <> partial

      {messages, rest} = JsonRpc.decode(buffer)

      assert length(messages) == 1
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
end
