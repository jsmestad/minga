# Mock LSP Server Script
#
# A minimal language server that speaks JSON-RPC 2.0 for testing.
# Reads from stdin, writes to stdout, logs to stderr.
#
# Supports:
# - initialize/initialized handshake
# - textDocument/didOpen, didChange, didSave, didClose
# - Optional workspace/configuration request after initialized
# - Optional unknown server request after initialized
# - Publishes a diagnostic on didOpen (for testing)
# - shutdown/exit lifecycle

defmodule MockServer do
  @moduledoc false

  def run do
    # Set stdout to binary mode and suppress Logger output so teardown
    # of the parent port doesn't produce noisy :epipe errors.
    :io.setopts(:standard_io, binary: true, encoding: :latin1)
    Logger.configure(level: :none)
    Process.put(:documents, %{})
    Process.put(:transcript, [])
    if stderr_banner?(), do: IO.puts(:standard_error, "mock lsp stderr banner")
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
            <<json::binary-size(^length), remaining::binary>> = rest
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
        "positionEncoding" => position_encoding(),
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
    if request_configuration?(), do: send_configuration_request()
    if request_unknown?(), do: send_unknown_request()
    if show_message?(), do: send_show_message()
    if show_message_request?(), do: send_show_message_request()
    :ok
  end

  defp handle_message(%{"method" => "textDocument/didOpen", "params" => params}) do
    # Publish a test diagnostic for the opened file
    uri = get_in(params, ["textDocument", "uri"])
    text = get_in(params, ["textDocument", "text"])
    version = get_in(params, ["textDocument", "version"])
    put_document(uri, text, version)
    record_transcript("textDocument/didOpen", %{"uri" => uri, "version" => version})

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

  defp handle_message(%{"method" => "textDocument/didChange", "params" => params}) do
    uri = get_in(params, ["textDocument", "uri"])
    version = get_in(params, ["textDocument", "version"])
    changes = Map.fetch!(params, "contentChanges")
    text = changed_document_text(uri, changes)
    put_document(uri, text, version)

    record_transcript("textDocument/didChange", %{
      "uri" => uri,
      "version" => version,
      "changeKind" => change_kind(changes)
    })

    :ok
  end

  defp handle_message(%{"method" => "textDocument/didSave"}) do
    :ok
  end

  defp handle_message(%{"method" => "textDocument/didClose"}) do
    :ok
  end

  defp handle_message(%{"method" => "mock/stall", "id" => _id}) do
    :ok
  end

  defp handle_message(%{"method" => "mock/transcript", "id" => id}) do
    documents =
      Process.get(:documents, %{})
      |> Map.new(fn {uri, document} ->
        {uri, Map.put(document, "bytes", :binary.bin_to_list(document["text"]))}
      end)

    send_response(id, %{
      "events" => Enum.reverse(Process.get(:transcript, [])),
      "documents" => documents
    })
  end

  defp handle_message(%{
         "method" => "textDocument/rename",
         "id" => id,
         "params" => params
       }) do
    uri = get_in(params, ["textDocument", "uri"])
    position = Map.fetch!(params, "position")
    document = Process.get(:documents, %{}) |> Map.fetch!(uri)
    start_character = Map.fetch!(position, "character")

    record_transcript("textDocument/rename", %{
      "uri" => uri,
      "position" => position,
      "documentVersion" => document["version"],
      "documentBytes" => :binary.bin_to_list(document["text"])
    })

    send_response(id, %{
      "documentChanges" => [
        %{
          "textDocument" => %{"uri" => uri, "version" => document["version"]},
          "edits" => [
            %{
              "range" => %{
                "start" => %{"line" => position["line"], "character" => start_character},
                "end" => %{"line" => position["line"], "character" => start_character + 3}
              },
              "newText" => Map.fetch!(params, "newName")
            }
          ]
        }
      ]
    })
  end

  defp handle_message(%{"method" => "$/cancelRequest", "params" => %{"id" => id}}) do
    if report_cancellations?() do
      send_test_diagnostic("file:///tmp/cancel-request-test.ex", "CANCEL", inspect(id))
      send_response(id, "late response after cancellation")
    end

    :ok
  end

  defp handle_message(%{"id" => "configuration-900", "result" => result}) when is_list(result) do
    send_test_diagnostic("file:///tmp/configuration-test.ex", "CONFIG", JSON.encode!(result))
  end

  defp handle_message(%{"id" => "unknown-900", "error" => %{"code" => code} = error}) do
    send_test_diagnostic(
      "file:///tmp/unknown-request-test.ex",
      "UNKNOWN",
      "#{code}:#{error["message"]}"
    )
  end

  defp handle_message(%{"id" => "show-message-request-901"} = msg) do
    # Echo the client's response to window/showMessageRequest back as a
    # diagnostic so tests can assert the client replied (rather than hanging).
    result = Map.get(msg, "result", :missing)
    send_test_diagnostic("file:///tmp/show-message-request-test.ex", "SHOWMSG", inspect(result))
  end

  defp handle_message(%{"method" => "shutdown", "id" => id}) do
    send_response(id, nil)
  end

  defp handle_message(%{"method" => "exit"}) do
    System.halt(0)
  end

  # Silently handle known methods that don't need mock responses
  defp handle_message(%{"method" => "textDocument/hover", "id" => id}) do
    send_response(id, nil)
  end

  defp handle_message(%{"method" => "textDocument/completion", "id" => id}) do
    send_response(id, %{"isIncomplete" => false, "items" => []})
  end

  defp handle_message(_msg) do
    :ok
  end

  defp send_response(id, result) do
    msg = %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    write_message(msg)
  end

  defp send_configuration_request do
    send_request("configuration-900", "workspace/configuration", %{
      "items" => [
        %{"scopeUri" => "file:///tmp/configuration-test.ex", "section" => "mock_lsp.nested"},
        %{"scopeUri" => "file:///tmp/configuration-test.ex", "section" => "missing"},
        %{"scopeUri" => "file:///tmp/configuration-test.ex"}
      ]
    })
  end

  defp send_unknown_request do
    send_request("unknown-900", "mock/unknown", %{})
  end

  defp send_show_message do
    send_notification("window/showMessage", %{
      "type" => 1,
      "message" => "mock show message"
    })
  end

  defp send_show_message_request do
    send_request("show-message-request-901", "window/showMessageRequest", %{
      "type" => 3,
      "message" => "apply migration?",
      "actions" => [%{"title" => "Yes"}, %{"title" => "No"}]
    })
  end

  defp send_request(id, method, params) do
    msg = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    write_message(msg)
  end

  defp send_notification(method, params) do
    msg = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    write_message(msg)
  end

  defp request_configuration? do
    "--request-configuration" in System.argv()
  end

  defp request_unknown? do
    "--request-unknown" in System.argv()
  end

  defp stderr_banner? do
    "--stderr-banner" in System.argv()
  end

  defp show_message? do
    "--show-message" in System.argv()
  end

  defp show_message_request? do
    "--show-message-request" in System.argv()
  end

  defp report_cancellations? do
    "--report-cancellations" in System.argv()
  end

  defp position_encoding do
    Enum.find_value(System.argv(), "utf-8", fn
      "--position-encoding=" <> encoding -> encoding
      _ -> nil
    end)
  end

  defp put_document(uri, text, version) do
    documents = Process.get(:documents, %{})
    Process.put(:documents, Map.put(documents, uri, %{"text" => text, "version" => version}))
  end

  defp record_transcript(method, details) do
    event = Map.put(details, "method", method)
    Process.put(:transcript, [event | Process.get(:transcript, [])])
  end

  defp changed_document_text(_uri, [%{"text" => text}]), do: text

  defp changed_document_text(uri, changes) do
    document = Process.get(:documents, %{}) |> Map.fetch!(uri)

    Enum.reduce(changes, document["text"], fn change, text ->
      apply_incremental_change(text, change)
    end)
  end

  defp apply_incremental_change(text, %{"range" => range, "text" => replacement}) do
    start_offset = lsp_offset(text, range["start"])
    end_offset = lsp_offset(text, range["end"])
    prefix = binary_part(text, 0, start_offset)
    suffix = binary_part(text, end_offset, byte_size(text) - end_offset)
    prefix <> replacement <> suffix
  end

  defp lsp_offset(text, %{"line" => line, "character" => character}) do
    {line_prefix, target_line} = split_target_line(text, line)
    byte_size(line_prefix) + character_offset(target_line, character, position_encoding())
  end

  defp split_target_line(text, target_line) do
    lines = String.split(text, "\n", trim: false)
    line_prefix = lines |> Enum.take(target_line) |> Enum.map_join(&(&1 <> "\n"))
    {line_prefix, Enum.at(lines, target_line, "")}
  end

  defp character_offset(line, character, "utf-8"), do: min(character, byte_size(line))

  defp character_offset(line, character, encoding) do
    unit_size = if encoding == "utf-16", do: 2, else: 4

    line
    |> String.codepoints()
    |> Enum.reduce_while({0, 0}, fn codepoint, {units, bytes} ->
      next_units =
        units +
          div(
            byte_size(:unicode.characters_to_binary(codepoint, :utf8, encoding_atom(encoding))),
            unit_size
          )

      if next_units > character do
        {:halt, {units, bytes}}
      else
        {:cont, {next_units, bytes + byte_size(codepoint)}}
      end
    end)
    |> elem(1)
  end

  defp encoding_atom("utf-16"), do: {:utf16, :little}
  defp encoding_atom("utf-32"), do: {:utf32, :little}

  defp change_kind([%{"range" => _range} | _]), do: "incremental"
  defp change_kind(_changes), do: "full"

  defp send_test_diagnostic(uri, code, message) do
    send_notification("textDocument/publishDiagnostics", %{
      "uri" => uri,
      "diagnostics" => [
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 1}
          },
          "severity" => 3,
          "source" => "mock_lsp",
          "message" => message,
          "code" => code
        }
      ]
    })
  end

  defp write_message(msg) do
    json = JSON.encode!(msg)
    header = "Content-Length: #{byte_size(json)}\r\n\r\n"

    try do
      IO.binwrite(:stdio, header <> json)
    rescue
      # Stdout pipe closed because the test tore down the port. Exit quietly.
      ErlangError -> :ok
    end
  end
end

MockServer.run()
