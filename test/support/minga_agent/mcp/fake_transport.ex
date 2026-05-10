defmodule MingaAgent.MCP.FakeTransport do
  @moduledoc false

  @behaviour MingaAgent.MCP.Transport

  use GenServer

  alias MingaAgent.MCP.ServerConfig

  @type state :: %{
          server_name: String.t(),
          owner: pid(),
          tools: [map()],
          call_results: map(),
          request_errors: map(),
          test_pid: pid() | nil
        }

  @impl MingaAgent.MCP.Transport
  @spec start(ServerConfig.t(), pid(), keyword()) :: GenServer.on_start()
  def start(%ServerConfig{} = config, owner, opts) do
    GenServer.start(__MODULE__, {config.name, owner, opts})
  end

  @impl MingaAgent.MCP.Transport
  @spec request(pid(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def request(pid, message, timeout) when is_pid(pid) do
    GenServer.call(pid, {:request, message}, timeout)
  end

  @impl MingaAgent.MCP.Transport
  @spec notify(pid(), map()) :: :ok
  def notify(pid, message) when is_pid(pid) do
    GenServer.call(pid, {:notify, message})
  end

  @impl MingaAgent.MCP.Transport
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.call(pid, :stop, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl MingaAgent.MCP.Transport
  @spec handle_transport_info(term(), pid()) :: :ignore | {:down, term()}
  def handle_transport_info({:mcp_fake_transport_exit, pid, reason}, pid), do: {:down, reason}
  def handle_transport_info(_message, _pid), do: :ignore

  @spec crash(pid()) :: :ok
  def crash(pid), do: GenServer.call(pid, :crash)

  @impl GenServer
  @spec init({String.t(), pid(), keyword()}) :: {:ok, state()}
  def init({server_name, owner, opts}) do
    tools = per_server(opts, :tools_by_server, server_name, Keyword.get(opts, :tools, []))

    call_results =
      per_server(
        opts,
        :call_results_by_server,
        server_name,
        Keyword.get(opts, :call_results, %{})
      )

    request_errors =
      per_server(
        opts,
        :request_errors_by_server,
        server_name,
        Keyword.get(opts, :request_errors, %{})
      )

    test_pid = Keyword.get(opts, :test_pid)

    state = %{
      server_name: server_name,
      owner: owner,
      tools: tools,
      call_results: call_results,
      request_errors: request_errors,
      test_pid: test_pid
    }

    maybe_report(state, {:mcp_transport_started, self()})
    maybe_report(state, {:mcp_transport_started, server_name, self()})
    {:ok, state}
  end

  @impl GenServer
  @spec handle_call(term(), GenServer.from(), state()) ::
          {:reply, term(), state()} | {:stop, :normal, :ok, state()}
  def handle_call({:request, %{"method" => "initialize"} = message}, _from, state) do
    maybe_report(state, {:mcp_request, message})
    maybe_report(state, {:mcp_request, state.server_name, message})

    case request_error(state, "initialize") do
      {:error, reason} -> {:reply, {:error, reason}, state}
      :none -> {:reply, {:ok, %{"protocolVersion" => "2024-11-05", "capabilities" => %{}}}, state}
    end
  end

  def handle_call({:request, %{"method" => "tools/list"} = message}, _from, state) do
    maybe_report(state, {:mcp_request, message})
    maybe_report(state, {:mcp_request, state.server_name, message})

    case request_error(state, "tools/list") do
      {:error, reason} -> {:reply, {:error, reason}, state}
      :none -> {:reply, {:ok, %{"tools" => state.tools}}, state}
    end
  end

  def handle_call(
        {:request, %{"method" => "tools/call", "params" => params} = message},
        _from,
        state
      ) do
    maybe_report(state, {:mcp_request, message})
    maybe_report(state, {:mcp_request, state.server_name, message})
    name = params["name"]
    args = params["arguments"] || %{}
    maybe_report(state, {:mcp_tool_call, name, args})
    maybe_report(state, {:mcp_tool_call, state.server_name, name, args})

    case request_error(state, name) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :none ->
        result =
          Map.get(state.call_results, name, %{
            "content" => [%{"type" => "text", "text" => "called #{name}"}]
          })

        {:reply, {:ok, result}, state}
    end
  end

  def handle_call({:notify, message}, _from, state) do
    maybe_report(state, {:mcp_notification, message})
    maybe_report(state, {:mcp_notification, state.server_name, message})
    {:reply, :ok, state}
  end

  def handle_call(:crash, _from, state) do
    send(state.owner, {:mcp_fake_transport_exit, self(), :boom})
    {:reply, :ok, state}
  end

  def handle_call(:stop, _from, state) do
    maybe_report(state, {:mcp_transport_stopped, self()})
    maybe_report(state, {:mcp_transport_stopped, state.server_name, self()})
    {:stop, :normal, :ok, state}
  end

  defp request_error(state, name) do
    case Map.fetch(state.request_errors, name) do
      {:ok, reason} -> {:error, reason}
      :error -> :none
    end
  end

  defp per_server(opts, key, server_name, default) do
    case Keyword.get(opts, key) do
      values when is_map(values) -> Map.get(values, server_name, default)
      _other -> default
    end
  end

  defp maybe_report(%{test_pid: nil}, _message), do: :ok
  defp maybe_report(%{test_pid: test_pid}, message), do: send(test_pid, message)
end
