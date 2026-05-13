defmodule Minga.Distribution.ConnectionManager do
  @moduledoc """
  Owns Erlang distribution connections to configured remote Minga servers.

  The manager reads `Minga.Distribution.Config`, connects to each node, monitors node health, retries failed connections with exponential backoff, and broadcasts connection events through `Minga.Events`.
  """

  use GenServer

  alias Minga.Distribution.Config
  alias Minga.Distribution.Events.NodeConnectedEvent
  alias Minga.Distribution.Events.NodeDisconnectedEvent

  @type public_connection_status :: :connected | :disconnected
  @type connected_node :: {String.t(), node(), public_connection_status()}
  @type connect_fun :: (node() -> boolean() | :ignored)
  @type monitor_fun :: (node(), boolean() -> term())
  @type set_cookie_fun :: (node(), atom() -> term())
  @type server_state :: %{
          node: node(),
          cookie: atom(),
          status: :connected | :disconnected | :connecting,
          retry_count: non_neg_integer(),
          retry_timer: reference() | nil,
          monitored?: boolean(),
          connected_at: DateTime.t() | nil
        }
  @type state :: %{
          servers: %{String.t() => server_state()},
          node_to_server: %{node() => String.t()},
          events_registry: Minga.Events.registry(),
          connect_fun: connect_fun(),
          monitor_fun: monitor_fun(),
          set_cookie_fun: set_cookie_fun()
        }

  @doc "Starts the connection manager."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts, [])
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc "Returns every configured remote node with its public connection status. In-progress reconnect attempts are reported as disconnected."
  @spec connected_nodes() :: [connected_node()]
  def connected_nodes do
    call_or_default(:connected_nodes, [])
  end

  @doc "Returns the connected node for a configured server name."
  @spec node_for_server(String.t()) :: {:ok, node()} | {:error, :not_found | :disconnected}
  def node_for_server(server_name) when is_binary(server_name) do
    call_or_default({:node_for_server, server_name}, {:error, :not_found})
  end

  @doc "Returns the configured server name for a node."
  @spec server_name_for_node(node()) :: {:ok, String.t()} | {:error, :not_found}
  def server_name_for_node(node) when is_atom(node) do
    call_or_default({:server_name_for_node, node}, {:error, :not_found})
  end

  @doc "Returns true when `server_name` is currently connected."
  @spec connected?(String.t()) :: boolean()
  def connected?(server_name) when is_binary(server_name) do
    call_or_default({:connected?, server_name}, false)
  end

  @doc "Returns the retry delay for `retry_count`, starting at 1s and doubling until the 30s cap. Clamps once the doubled value would exceed 30s."
  @spec backoff_ms(non_neg_integer()) :: pos_integer()
  def backoff_ms(retry_count) when is_integer(retry_count) and retry_count >= 5, do: 30_000

  def backoff_ms(retry_count) when is_integer(retry_count) and retry_count >= 0 do
    1_000 * Integer.pow(2, retry_count)
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    servers = Keyword.get_lazy(opts, :servers, fn -> load_servers(opts) end)

    state =
      new_state(
        servers,
        Keyword.get(opts, :events_registry, Minga.Events.default_registry()),
        Keyword.get(opts, :connect_fun, &Node.connect/1),
        Keyword.get(opts, :monitor_fun, &Node.monitor/2),
        Keyword.get(opts, :set_cookie_fun, &Node.set_cookie/2)
      )

    if map_size(state.servers) > 0 and Keyword.get(opts, :connect_on_init, true) do
      send(self(), :connect_all)
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:connected_nodes, _from, state) do
    nodes =
      Enum.map(state.servers, fn {server_name, server} ->
        {server_name, server.node, public_status(server.status)}
      end)

    {:reply, nodes, state}
  end

  def handle_call({:node_for_server, server_name}, _from, state) do
    {:reply, node_for_server_result(state, server_name), state}
  end

  def handle_call({:server_name_for_node, node}, _from, state) do
    {:reply, server_name_for_node_result(state, node), state}
  end

  def handle_call({:connected?, server_name}, _from, state) do
    {:reply, connected_server?(state, server_name), state}
  end

  @impl GenServer
  def handle_info(:connect_all, state) do
    {:noreply, connect_all(state)}
  end

  def handle_info({:reconnect, server_name}, state) do
    {:noreply, connect_to_server(state, server_name)}
  end

  def handle_info({:nodedown, node}, state) do
    {:noreply, handle_node_down(state, node, :nodedown)}
  end

  def handle_info({:nodedown, node, info}, state) do
    {:noreply, handle_node_down(state, node, info)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @spec call_or_default(term(), term()) :: term()
  defp call_or_default(request, default) do
    case Process.whereis(__MODULE__) do
      nil -> default
      _pid -> GenServer.call(__MODULE__, request)
    end
  catch
    :exit, _ -> default
  end

  @spec load_servers(keyword()) :: [Config.server_entry()]
  defp load_servers(opts) do
    case Keyword.fetch(opts, :config_path) do
      {:ok, path} -> Config.load(path)
      :error -> Config.load()
    end
  end

  @spec new_state(
          [Config.server_entry()],
          Minga.Events.registry(),
          connect_fun(),
          monitor_fun(),
          set_cookie_fun()
        ) :: state()
  defp new_state(entries, events_registry, connect_fun, monitor_fun, set_cookie_fun) do
    servers =
      Map.new(entries, fn %{name: name, node: node, cookie: cookie} ->
        {name,
         %{
           node: node,
           cookie: cookie,
           status: :disconnected,
           retry_count: 0,
           retry_timer: nil,
           monitored?: false,
           connected_at: nil
         }}
      end)

    node_to_server = Map.new(entries, fn %{name: name, node: node} -> {node, name} end)

    %{
      servers: servers,
      node_to_server: node_to_server,
      events_registry: events_registry,
      connect_fun: connect_fun,
      monitor_fun: monitor_fun,
      set_cookie_fun: set_cookie_fun
    }
  end

  @spec public_status(:connected | :disconnected | :connecting) :: public_connection_status()
  defp public_status(:connected), do: :connected
  defp public_status(_status), do: :disconnected

  @spec node_for_server_result(state(), String.t()) ::
          {:ok, node()} | {:error, :not_found | :disconnected}
  defp node_for_server_result(%{servers: servers}, server_name) do
    case Map.fetch(servers, server_name) do
      {:ok, %{node: node, status: :connected}} -> {:ok, node}
      {:ok, _server} -> {:error, :disconnected}
      :error -> {:error, :not_found}
    end
  end

  @spec server_name_for_node_result(state(), node()) :: {:ok, String.t()} | {:error, :not_found}
  defp server_name_for_node_result(%{node_to_server: node_to_server}, node) do
    case Map.fetch(node_to_server, node) do
      {:ok, server_name} -> {:ok, server_name}
      :error -> {:error, :not_found}
    end
  end

  @spec connected_server?(state(), String.t()) :: boolean()
  defp connected_server?(%{servers: servers}, server_name) do
    case Map.fetch(servers, server_name) do
      {:ok, %{status: :connected}} -> true
      _ -> false
    end
  end

  @spec connect_all(state()) :: state()
  defp connect_all(state) do
    state.servers
    |> Map.keys()
    |> Enum.reduce(state, &connect_to_server(&2, &1))
  end

  @spec connect_to_server(state(), String.t()) :: state()
  defp connect_to_server(%{servers: servers} = state, server_name) do
    case Map.fetch(servers, server_name) do
      {:ok, %{status: :connected}} -> state
      {:ok, server} -> attempt_connect(state, server_name, mark_connecting(server))
      :error -> state
    end
  end

  @spec attempt_connect(state(), String.t(), server_state()) :: state()
  defp attempt_connect(state, server_name, server) do
    state = put_server(state, server_name, server)
    state.set_cookie_fun.(server.node, server.cookie)

    case state.connect_fun.(server.node) do
      true -> mark_connected(state, server_name, server)
      false -> schedule_retry(state, server_name, server)
      :ignored -> schedule_retry(state, server_name, server)
    end
  end

  @spec mark_connecting(server_state()) :: server_state()
  defp mark_connecting(server) do
    %{server | status: :connecting, retry_timer: nil}
  end

  @spec mark_connected(state(), String.t(), server_state()) :: state()
  defp mark_connected(state, server_name, server) do
    monitor_node(state, server.node, server.monitored?)
    connected_at = DateTime.utc_now()

    server = %{
      server
      | status: :connected,
        retry_count: 0,
        retry_timer: nil,
        monitored?: true,
        connected_at: connected_at
    }

    Minga.Log.info(:distribution, "Connected to #{server_name} (#{server.node})")

    Minga.Events.broadcast(
      :node_connected,
      %NodeConnectedEvent{
        server_name: server_name,
        node: server.node,
        connected_at: connected_at
      },
      state.events_registry
    )

    put_server(state, server_name, server)
  end

  @spec monitor_node(state(), node(), boolean()) :: :ok
  defp monitor_node(_state, _node, true), do: :ok

  defp monitor_node(state, node, false) do
    state.monitor_fun.(node, true)
    :ok
  end

  @spec schedule_retry(state(), String.t(), server_state()) :: state()
  defp schedule_retry(state, server_name, %{retry_timer: timer} = server)
       when is_reference(timer) do
    put_server(state, server_name, %{server | status: :disconnected})
  end

  defp schedule_retry(state, server_name, server) do
    delay = backoff_ms(server.retry_count)
    timer = Process.send_after(self(), {:reconnect, server_name}, delay)

    Minga.Log.debug(:distribution, fn ->
      "Failed to connect to #{server_name} (#{server.node}); retrying in #{delay}ms"
    end)

    server = %{
      server
      | status: :disconnected,
        retry_count: server.retry_count + 1,
        retry_timer: timer
    }

    put_server(state, server_name, server)
  end

  @spec handle_node_down(state(), node(), term()) :: state()
  defp handle_node_down(state, node, reason) do
    case Map.fetch(state.node_to_server, node) do
      {:ok, server_name} -> mark_disconnected(state, server_name, reason)
      :error -> state
    end
  end

  @spec mark_disconnected(state(), String.t(), term()) :: state()
  defp mark_disconnected(%{servers: servers} = state, server_name, reason) do
    case Map.fetch(servers, server_name) do
      {:ok, %{status: :disconnected, retry_timer: timer}} when is_reference(timer) ->
        state

      {:ok, %{status: :disconnected} = server} ->
        schedule_retry(state, server_name, server)

      {:ok, server} ->
        broadcast_disconnected(state, server_name, server, reason)

      :error ->
        state
    end
  end

  @spec broadcast_disconnected(state(), String.t(), server_state(), term()) :: state()
  defp broadcast_disconnected(state, server_name, server, reason) do
    disconnected_at = DateTime.utc_now()

    Minga.Log.warning(
      :distribution,
      "Disconnected from #{server_name} (#{server.node}): #{inspect(reason)}"
    )

    Minga.Events.broadcast(
      :node_disconnected,
      %NodeDisconnectedEvent{
        server_name: server_name,
        node: server.node,
        reason: reason,
        disconnected_at: disconnected_at
      },
      state.events_registry
    )

    server = %{
      server
      | status: :disconnected,
        retry_count: 0,
        retry_timer: nil,
        monitored?: false,
        connected_at: nil
    }

    schedule_retry(state, server_name, server)
  end

  @spec put_server(state(), String.t(), server_state()) :: state()
  defp put_server(%{servers: servers} = state, server_name, server) do
    %{state | servers: Map.put(servers, server_name, server)}
  end
end
