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
    conn
    |> WebSockAdapter.upgrade(MingaAgent.Gateway.WebSocket, [], timeout: 60_000)
    |> halt()
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
