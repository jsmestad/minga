defmodule Minga.Distribution.ConnectionManagerTest do
  use ExUnit.Case, async: true

  alias Minga.Distribution.Config
  alias Minga.Distribution.ConnectionManager
  alias Minga.Distribution.Events.NodeConnectedEvent
  alias Minga.Distribution.Events.NodeDisconnectedEvent
  alias Minga.Events

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

  test "connect_all broadcasts node_connected" do
    registry = start_events_registry()
    Events.subscribe(:node_connected, registry)

    node = :"remote@127.0.0.1"
    servers = [%{name: "local", node: node, cookie: :abcdefghijklmnopqrstuvwxyz123456}]

    {:ok, pid} = start_connection_manager(servers, registry)

    send(pid, :connect_all)
    :sys.get_state(pid)

    assert_receive {:minga_event, :node_connected,
                    %NodeConnectedEvent{server_name: "local", node: connected_node}}

    assert connected_node == node
  end

  test "nodedown broadcasts node_disconnected and does not create duplicate retry timers" do
    registry = start_events_registry()
    Events.subscribe(:node_connected, registry)
    Events.subscribe(:node_disconnected, registry)

    node = :"remote@127.0.0.1"
    servers = [%{name: "local", node: node, cookie: :abcdefghijklmnopqrstuvwxyz123456}]

    {:ok, pid} = start_connection_manager(servers, registry)

    send(pid, :connect_all)
    :sys.get_state(pid)
    assert_receive {:minga_event, :node_connected, %NodeConnectedEvent{}}

    send(pid, {:nodedown, node, :test_down})
    :sys.get_state(pid)

    assert_receive {:minga_event, :node_disconnected,
                    %NodeDisconnectedEvent{
                      server_name: "local",
                      node: disconnected_node,
                      reason: :test_down,
                      disconnected_at: %DateTime{}
                    }}

    assert disconnected_node == node
    first_timer = retry_timer(pid, "local")
    assert is_reference(first_timer)

    send(pid, {:nodedown, node, :duplicate_down})
    :sys.get_state(pid)

    assert retry_timer(pid, "local") == first_timer
    refute_receive {:minga_event, :node_disconnected, %NodeDisconnectedEvent{}}, 50
  end

  @spec start_connection_manager([Config.server_entry()], Minga.Events.registry()) :: {:ok, pid()}
  defp start_connection_manager(servers, registry) do
    start_supervised(
      {ConnectionManager,
       name: nil,
       servers: servers,
       events_registry: registry,
       connect_on_init: false,
       connect_fun: fn _node -> true end,
       monitor_fun: fn _node, _flag -> true end,
       set_cookie_fun: fn _node, _cookie -> true end}
    )
  end

  @spec start_events_registry() :: atom()
  defp start_events_registry do
    name = :"connection_manager_events_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: name})
    name
  end

  defp retry_timer(pid, server_name) do
    ConnectionManager.retry_timer(pid, server_name)
  end
end
