defmodule MingaAgent.Gateway.Router do
  @moduledoc """
  HTTP router for the API gateway.

  Two endpoints:
    * `GET /ws` upgrades to a WebSocket connection for JSON-RPC
    * `GET /health` returns 200 OK for load balancer probes
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/ws" do
    case authenticate_websocket(conn) do
      :ok ->
        conn
        |> WebSockAdapter.upgrade(MingaAgent.Gateway.WebSocket, [], timeout: 60_000)
        |> halt()

      {:error, status, message} ->
        conn
        |> send_resp(status, message)
        |> halt()
    end
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @spec authenticate_websocket(Plug.Conn.t()) :: :ok | {:error, pos_integer(), String.t()}
  defp authenticate_websocket(conn) do
    conn
    |> configured_gateway_token()
    |> authenticate_token(presented_bearer_token(conn))
  end

  @spec configured_gateway_token(Plug.Conn.t()) :: String.t() | nil
  defp configured_gateway_token(_conn) do
    Application.get_env(:minga, :gateway_auth_token)
  end

  @spec authenticate_token(String.t() | nil, String.t() | nil) ::
          :ok | {:error, pos_integer(), String.t()}
  defp authenticate_token(nil, _presented),
    do: {:error, 503, "gateway websocket auth not configured"}

  defp authenticate_token("", _presented),
    do: {:error, 503, "gateway websocket auth not configured"}

  defp authenticate_token(_expected, nil), do: {:error, 401, "unauthorized"}

  defp authenticate_token(expected, presented) when byte_size(expected) != byte_size(presented),
    do: {:error, 401, "unauthorized"}

  defp authenticate_token(expected, presented), do: secure_token_compare(expected, presented)

  @spec secure_token_compare(String.t(), String.t()) :: :ok | {:error, 401, String.t()}
  defp secure_token_compare(expected, presented) do
    if Plug.Crypto.secure_compare(expected, presented) do
      :ok
    else
      {:error, 401, "unauthorized"}
    end
  end

  @spec presented_bearer_token(Plug.Conn.t()) :: String.t() | nil
  defp presented_bearer_token(conn) do
    conn
    |> Plug.Conn.get_req_header("authorization")
    |> bearer_token_from_headers()
  end

  @spec bearer_token_from_headers([String.t()]) :: String.t() | nil
  defp bearer_token_from_headers(["Bearer " <> token | _rest]), do: token
  defp bearer_token_from_headers([_header | rest]), do: bearer_token_from_headers(rest)
  defp bearer_token_from_headers([]), do: nil
end
