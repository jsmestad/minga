defmodule MingaAgent.Gateway.RouterTest do
  # Mutates Application env (:minga, :gateway_auth_token).
  use ExUnit.Case, async: false

  import Plug.Test

  alias MingaAgent.Gateway.Router

  setup do
    previous = Application.get_env(:minga, :gateway_auth_token)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:minga, :gateway_auth_token)
        token -> Application.put_env(:minga, :gateway_auth_token, token)
      end
    end)

    :ok
  end

  test "websocket route returns 503 when auth token is not configured" do
    Application.delete_env(:minga, :gateway_auth_token)

    conn = Router.call(conn(:get, "/ws"), [])

    assert conn.status == 503
    assert conn.resp_body == "gateway websocket auth not configured"
  end

  test "websocket route returns 503 when auth token is empty" do
    Application.put_env(:minga, :gateway_auth_token, "")

    conn = Router.call(conn(:get, "/ws"), [])

    assert conn.status == 503
    assert conn.resp_body == "gateway websocket auth not configured"
  end

  test "websocket route returns 401 when bearer token is missing" do
    Application.put_env(:minga, :gateway_auth_token, "expected-token")

    conn = Router.call(conn(:get, "/ws"), [])

    assert conn.status == 401
    assert conn.resp_body == "unauthorized"
  end

  test "websocket route returns 401 when bearer token is wrong" do
    Application.put_env(:minga, :gateway_auth_token, "expected-token")

    conn =
      :get
      |> conn("/ws")
      |> Plug.Conn.put_req_header("authorization", "Bearer wrong-token")
      |> Router.call([])

    assert conn.status == 401
    assert conn.resp_body == "unauthorized"
  end
end
