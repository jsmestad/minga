defmodule MingaAgent.Gateway.IntegrationTest do
  # Starts a Bandit listener on a network port.
  use ExUnit.Case, async: false

  import Bitwise

  alias MingaAgent.Gateway.Server

  @moduletag timeout: 15_000

  setup do
    # Start gateway on a random loopback port to avoid conflicts.
    token = "test-token-#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({Server, port: 0, auth_token: token})
    port = Server.port(pid)
    {:ok, port: port, token: token}
  end

  describe "health endpoint" do
    test "returns 200 OK", %{port: port} do
      {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port)
      {:ok, conn, _ref} = Mint.HTTP.request(conn, "GET", "/health", [], nil)

      assert {:ok, _conn, responses} = receive_responses(conn)
      status = Enum.find_value(responses, fn {:status, _, s} -> s end)
      assert status == 200
    end
  end

  describe "WebSocket JSON-RPC" do
    test "runtime.capabilities returns tool count", %{port: port, token: token} do
      {:ok, ws} = ws_connect(port, token)

      request =
        JSON.encode!(%{jsonrpc: "2.0", method: "runtime.capabilities", params: %{}, id: 1})

      :ok = ws_send(ws, request)

      {:ok, response} = ws_receive(ws)
      assert response["id"] == 1
      assert is_integer(response["result"]["tool_count"])
      assert is_binary(response["result"]["version"])

      ws_close(ws)
    end

    test "tool.list returns tool descriptions", %{port: port, token: token} do
      {:ok, ws} = ws_connect(port, token)

      request = JSON.encode!(%{jsonrpc: "2.0", method: "tool.list", params: %{}, id: 2})
      :ok = ws_send(ws, request)

      {:ok, response} = ws_receive(ws)
      assert response["id"] == 2
      assert is_list(response["result"])

      ws_close(ws)
    end

    test "unknown method returns error", %{port: port, token: token} do
      {:ok, ws} = ws_connect(port, token)

      request = JSON.encode!(%{jsonrpc: "2.0", method: "bogus", params: %{}, id: 3})
      :ok = ws_send(ws, request)

      {:ok, response} = ws_receive(ws)
      assert response["id"] == 3
      assert response["error"]["code"] == -32_601

      ws_close(ws)
    end

    # Regression for issue #2663: the gateway subscribes to Minga.Events on connect
    # and pushes event notifications on the same socket. A notification that
    # interleaves with a request/response pair must not be mistaken for the
    # response. Emitting a `:log_message` before the request enqueues the
    # notification frame ahead of the response frame, so a client that blindly read
    # "the next frame" would fail here.
    test "response is returned even when an event notification interleaves", %{
      port: port,
      token: token
    } do
      {:ok, ws} = ws_connect(port, token)

      # Warm-up round-trip: the WebSocket handler subscribes to Minga.Events in its
      # init/1, which runs asynchronously after the HTTP upgrade. Completing one
      # request/response proves init/1 (and thus the subscription) has run, so the
      # broadcast below is guaranteed to reach this connection.
      :ok = ws_send(ws, JSON.encode!(%{jsonrpc: "2.0", method: "tool.list", params: %{}, id: 4}))
      {:ok, warmup} = ws_receive(ws)
      assert warmup["id"] == 4

      # Now enqueue an event notification ahead of the next response. broadcast/2
      # delivers synchronously, so {:minga_event, ...} is in the connection's
      # mailbox (pushed as a notification frame) before the request below is sent.
      Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{
        text: "interleaved notification",
        level: :info
      })

      request =
        JSON.encode!(%{jsonrpc: "2.0", method: "runtime.capabilities", params: %{}, id: 5})

      :ok = ws_send(ws, request)

      {:ok, response} = ws_receive(ws)
      assert response["id"] == 5
      assert is_integer(response["result"]["tool_count"])

      ws_close(ws)
    end
  end

  # ── WebSocket helpers using raw :gen_tcp + HTTP upgrade ─────────────────────

  # We use raw TCP + manual WebSocket handshake to avoid adding a test-only
  # WebSocket client dependency. This is sufficient for JSON-RPC testing.

  defp ws_connect(port, token) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    upgrade_request =
      "GET /ws HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n" <>
        "Authorization: Bearer #{token}\r\n" <>
        "\r\n"

    :ok = :gen_tcp.send(socket, upgrade_request)

    # Read the HTTP upgrade response
    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
    assert response =~ "101 Switching Protocols", "WebSocket upgrade failed: #{response}"

    {:ok, socket}
  end

  defp ws_send(socket, text) do
    # Build a masked text frame (client frames must be masked per RFC 6455)
    payload = :erlang.iolist_to_binary(text)
    mask_key = :crypto.strong_rand_bytes(4)
    masked = mask_payload(payload, mask_key)
    len = byte_size(payload)

    frame =
      cond do
        len < 126 ->
          <<0x81, 0x80 ||| len, mask_key::binary-size(4), masked::binary>>

        len < 65_536 ->
          <<0x81, 0x80 ||| 126, len::16, mask_key::binary-size(4), masked::binary>>

        true ->
          <<0x81, 0x80 ||| 127, len::64, mask_key::binary-size(4), masked::binary>>
      end

    :gen_tcp.send(socket, frame)
  end

  # Reads WebSocket frames until a JSON-RPC *response* (a frame carrying an "id")
  # arrives, skipping any server-pushed notifications that interleave.
  #
  # Root cause of issue #2663: the gateway WebSocket subscribes to Minga.Events on
  # connect (`EventStream.subscribe_all/0`) and pushes event notifications
  # (`{"jsonrpc":"2.0","method":"event.<topic>",...}` frames with no "id") on the
  # same socket. Under full-suite load a `:log_message`/`:buffer_changed`/etc. event
  # can fire between our request and its response, so blindly reading "the next
  # frame" would read a notification and see the wrong (or missing) id. A real
  # JSON-RPC-over-WebSocket client correlates responses by id and ignores
  # notifications, so the test must too.
  defp ws_receive(socket) do
    frame = ws_read_frame(socket)

    cond do
      # JSON-RPC responses always carry the request id.
      Map.has_key?(frame, "id") -> {:ok, frame}
      # JSON-RPC notifications carry a method and no id: skip and keep reading.
      Map.has_key?(frame, "method") -> ws_receive(socket)
      true -> {:ok, frame}
    end
  end

  defp ws_read_frame(socket) do
    # Read a text frame. Simplified parser: assumes single unfragmented frame.
    {:ok, <<_fin_opcode, len_byte>>} = :gen_tcp.recv(socket, 2, 5_000)
    # Server frames are unmasked
    payload_len = len_byte &&& 0x7F

    actual_len =
      cond do
        payload_len < 126 ->
          payload_len

        payload_len == 126 ->
          {:ok, <<ext_len::16>>} = :gen_tcp.recv(socket, 2, 5_000)
          ext_len

        payload_len == 127 ->
          {:ok, <<ext_len::64>>} = :gen_tcp.recv(socket, 8, 5_000)
          ext_len
      end

    {:ok, payload} = :gen_tcp.recv(socket, actual_len, 5_000)
    JSON.decode!(payload)
  end

  defp ws_close(socket) do
    # Send a close frame
    :gen_tcp.send(socket, <<0x88, 0x80, 0, 0, 0, 0>>)
    :gen_tcp.close(socket)
  end

  defp mask_payload(payload, mask_key) do
    mask_bytes = :binary.bin_to_list(mask_key)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} ->
      Bitwise.bxor(byte, Enum.at(mask_bytes, rem(i, 4)))
    end)
    |> :binary.list_to_bin()
  end

  # ── Mint HTTP helpers ───────────────────────────────────────────────────────

  defp receive_responses(conn, acc \\ []) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            all = acc ++ responses

            if Enum.any?(responses, fn
                 {:done, _} -> true
                 _ -> false
               end) do
              {:ok, conn, all}
            else
              receive_responses(conn, all)
            end

          {:error, _conn, reason, _responses} ->
            {:error, reason}
        end
    after
      5_000 -> {:error, :timeout}
    end
  end
end
