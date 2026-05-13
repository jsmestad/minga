defmodule Minga.Distribution.ConnectionManagerTest do
  use ExUnit.Case, async: true

  alias Minga.Distribution.ConnectionManager

  test "connected_nodes/0 is safe when manager is not running" do
    assert is_list(ConnectionManager.connected_nodes())
  end

  test "starts with no configured servers" do
    {:ok, pid} =
      start_supervised({ConnectionManager, name: nil, servers: [], connect_on_init: false})

    assert GenServer.call(pid, :connected_nodes) == []
  end

  test "query API reports disconnected configured servers" do
    servers = [%{name: "home", node: :"minga_server@home.test", cookie: :secret}]

    {:ok, pid} =
      start_supervised({ConnectionManager, name: nil, servers: servers, connect_on_init: false})

    assert GenServer.call(pid, :connected_nodes) == [
             {"home", :"minga_server@home.test", :disconnected}
           ]

    assert GenServer.call(pid, {:node_for_server, "home"}) == {:error, :disconnected}

    assert GenServer.call(pid, {:server_name_for_node, :"minga_server@home.test"}) ==
             {:ok, "home"}

    assert GenServer.call(pid, {:connected?, "home"}) == false
  end

  test "backoff is capped at thirty seconds" do
    assert ConnectionManager.backoff_ms(0) == 1_000
    assert ConnectionManager.backoff_ms(1) == 2_000
    assert ConnectionManager.backoff_ms(5) == 30_000
    assert ConnectionManager.backoff_ms(12) == 30_000
  end
end
