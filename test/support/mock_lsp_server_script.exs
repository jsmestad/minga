# Mock LSP Server Script
#
# A minimal language server that speaks JSON-RPC 2.0 for testing.
# Reads from stdin, writes to stdout, logs to stderr.
#
# Supports:
# - initialize/initialized handshake
# - textDocument/didOpen, didChange, didSave, didClose
# - Publishes a diagnostic on didOpen (for testing)
# - shutdown/exit lifecycle

defmodule MockServer do
  @moduledoc false

  def run do
    # Set stdout to binary mode
    :io.setopts(:standard_io, binary: true, encoding: :latin1)
    loop("")
  end

  defp loop(buffer) do
    case IO.binread(:stdio, 1) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      data when is_binary(data) ->
        buffer = buffer <> data
        {messages, remaining} = decode_messages(buffer)
        Enum.each(messages, &handle_message/1)
        loop(remaining)
    end
  end

  defp decode_messages(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [_partial] ->
        {[], buffer}

      [headers, rest] ->
        case parse_content_length(headers) do
          nil ->
            {[], buffer}

          length when byte_size(rest) >= length ->
            <<json::binary-size(length), remaining::binary>> = rest
            msg = JSON.decode!(json)
            {more_msgs, final_rest} = decode_messages(remaining)
            {[msg | more_msgs], final_rest}

          _length ->
            {[], buffer}
        end
    end
  end

  defp parse_content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(fn
      "Content-Length: " <> val -> String.to_integer(String.trim(val))
      _ -> nil
    end)
  end

  defp handle_message(%{"method" => "initialize", "id" => id}) do
    result = %{
      "capabilities" => %{
        "positionEncoding" => "utf-8",
        "textDocumentSync" => %{
          "openClose" => true,
          "change" => 1,
          "save" => true
        },
        "diagnosticProvider" => %{
          "interFileDependencies" => false,
          "workspaceDiagnostics" => false
        }
      }
    }

    send_response(id, result)
  end

  defp handle_message(%{"method" => "initialized"}) do
    # No response needed
    :ok
  end

  defp handle_message(%{"method" => "textDocument/didOpen", "params" => params}) do
    # Publish a test diagnostic for the opened file
    uri = get_in(params, ["textDocument", "uri"])

    send_notification("textDocument/publishDiagnostics", %{
      "uri" => uri,
      "diagnostics" => [
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 5}
          },
          "severity" => 2,
          "source" => "mock_lsp",
          "message" => "mock warning on line 1",
          "code" => "W001"
        }
      ]
    })
  end

  defp handle_message(%{"method" => "textDocument/didChange"}) do
    :ok
  end

  defp handle_message(%{"method" => "textDocument/didSave"}) do
    :ok
  end

  defp handle_message(%{"method" => "textDocument/didClose"}) do
    :ok
  end

  defp handle_message(%{"method" => "shutdown", "id" => id}) do
    send_response(id, nil)
  end

  defp handle_message(%{"method" => "exit"}) do
    System.halt(0)
  end

  defp handle_message(msg) do
    IO.puts(:stderr, "MockLSP: unhandled message: #{inspect(msg)}")
  end

  defp send_response(id, result) do
    msg = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    write_message(msg)
  end

  defp send_notification(method, params) do
    msg = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    write_message(msg)
  end

  defp write_message(msg) do
    json = JSON.encode!(msg)
    header = "Content-Length: #{byte_size(json)}\r\n\r\n"
    IO.binwrite(:stdio, header <> json)
  end
end

MockServer.run()
