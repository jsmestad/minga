defmodule Minga.LSP.JsonRpc do
  @moduledoc """
  Encodes and decodes LSP JSON-RPC messages.

  LSP uses JSON-RPC 2.0 over a transport with HTTP-style headers:

      Content-Length: 42\\r\\n
      \\r\\n
      {"jsonrpc":"2.0","method":"initialize",...}

  This module provides stateless, pure functions for encoding messages
  into this format and decoding them from a binary buffer (handling
  partial reads and multiple messages in a single chunk).

  Uses Elixir 1.19's built-in `JSON` module (backed by OTP's `:json` NIF)
  for maximum encode/decode performance with zero external dependencies.

  ## Message Types

  * **Request** — has `id`, `method`, and optional `params`
  * **Notification** — has `method` and optional `params`, no `id`
  * **Response** — has `id` and either `result` or `error`
  """

  @typedoc "A decoded JSON-RPC message as a map."
  @type message :: map()

  @doc """
  Encodes a JSON-RPC request (has an `id`, expects a response).

  ## Examples

      iex> msg = Minga.LSP.JsonRpc.encode_request(1, "initialize", %{})
      iex> IO.iodata_to_binary(msg) =~ "Content-Length:"
      true
  """
  @spec encode_request(integer(), String.t(), map()) :: iodata()
  def encode_request(id, method, params)
      when is_integer(id) and is_binary(method) and is_map(params) do
    encode(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  @doc """
  Encodes a JSON-RPC notification (no `id`, no response expected).

  ## Examples

      iex> msg = Minga.LSP.JsonRpc.encode_notification("initialized", %{})
      iex> IO.iodata_to_binary(msg) =~ "initialized"
      true
  """
  @spec encode_notification(String.t(), map()) :: iodata()
  def encode_notification(method, params)
      when is_binary(method) and is_map(params) do
    encode(%{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params
    })
  end

  @doc """
  Encodes a JSON-RPC success response.
  """
  @spec encode_response(integer(), map()) :: iodata()
  def encode_response(id, result) when is_integer(id) and is_map(result) do
    encode(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => result
    })
  end

  @doc """
  Encodes a JSON-RPC error response.
  """
  @spec encode_error_response(integer(), integer(), String.t()) :: iodata()
  def encode_error_response(id, code, message)
      when is_integer(id) and is_integer(code) and is_binary(message) do
    encode(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  @doc """
  Decodes zero or more JSON-RPC messages from a binary buffer.

  Returns `{decoded_messages, remaining_buffer}`. The remaining buffer
  contains any incomplete message data that needs more bytes.

  Handles:
  - Multiple complete messages in one buffer
  - Partial headers (waiting for `\\r\\n\\r\\n`)
  - Partial body (have headers but not enough bytes)

  ## Examples

      iex> encoded = IO.iodata_to_binary(Minga.LSP.JsonRpc.encode_notification("test", %{"a" => 1}))
      iex> {messages, rest} = Minga.LSP.JsonRpc.decode(encoded)
      iex> length(messages)
      1
      iex> hd(messages)["method"]
      "test"
      iex> rest
      ""
  """
  @spec decode(binary()) :: {[message()], binary()}
  def decode(buffer) when is_binary(buffer) do
    decode_loop(buffer, [])
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec encode(map()) :: iodata()
  defp encode(msg) do
    json = JSON.encode!(msg)
    length = byte_size(json)
    ["Content-Length: ", Integer.to_string(length), "\r\n\r\n", json]
  end

  @spec decode_loop(binary(), [message()]) :: {[message()], binary()}
  defp decode_loop(buffer, acc) do
    case extract_one(buffer) do
      {:ok, msg, rest} ->
        decode_loop(rest, [msg | acc])

      :incomplete ->
        {Enum.reverse(acc), buffer}
    end
  end

  @spec extract_one(binary()) :: {:ok, message(), binary()} | :incomplete
  defp extract_one(buffer) do
    with [headers_section, body_and_rest] <- :binary.split(buffer, "\r\n\r\n"),
         {:ok, content_length} <- parse_content_length(headers_section),
         true <- byte_size(body_and_rest) >= content_length do
      <<json::binary-size(^content_length), rest::binary>> = body_and_rest
      {:ok, JSON.decode!(json), rest}
    else
      _ -> :incomplete
    end
  end

  @spec parse_content_length(binary()) :: {:ok, non_neg_integer()} | :error
  defp parse_content_length(headers) do
    parse_content_length_lines(:binary.split(headers, "\r\n", [:global]))
  end

  @spec parse_content_length_lines([binary()]) :: {:ok, non_neg_integer()} | :error
  defp parse_content_length_lines([]), do: :error

  defp parse_content_length_lines([<<"Content-Length: ", value::binary>> | _rest]) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_content_length_lines([_ | rest]), do: parse_content_length_lines(rest)
end
