defmodule MingaAgent.MCP.FakeTransport do
  @moduledoc false

  @behaviour MingaAgent.MCP.Transport

  use GenServer

  alias MingaAgent.MCP.ServerConfig

  @impl MingaAgent.MCP.Transport
  def start(%ServerConfig{}, owner, opts) do
    GenServer.start(__MODULE__, {owner, opts})
  end

  @impl MingaAgent.MCP.Transport
  def request(pid, message, timeout) when is_pid(pid) do
    GenServer.call(pid, {:request, message}, timeout)
  end

  @impl MingaAgent.MCP.Transport
  def notify(pid, message) when is_pid(pid) do
    GenServer.call(pid, {:notify, message})
  end

  @impl MingaAgent.MCP.Transport
  def stop(pid) when is_pid(pid) do
    GenServer.call(pid, :stop, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl MingaAgent.MCP.Transport
  def handle_transport_info({:mcp_fake_transport_exit, pid, reason}, pid), do: {:down, reason}
  def handle_transport_info(_message, _pid), do: :ignore

  def crash(pid), do: GenServer.call(pid, :crash)

  @impl GenServer
  def init({owner, opts}) do
    tools = Keyword.get(opts, :tools, [])
    call_results = Keyword.get(opts, :call_results, %{})
    request_errors = Keyword.get(opts, :request_errors, %{})
    test_pid = Keyword.get(opts, :test_pid)

    state = %{
      owner: owner,
      tools: tools,
      call_results: call_results,
      request_errors: request_errors,
      test_pid: test_pid
    }

    maybe_report(state, {:mcp_transport_started, self()})
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:request, %{"method" => "initialize"} = message}, _from, state) do
    maybe_report(state, {:mcp_request, message})

    case request_error(state, "initialize") do
      {:error, reason} -> {:reply, {:error, reason}, state}
      :none -> {:reply, {:ok, %{"protocolVersion" => "2024-11-05", "capabilities" => %{}}}, state}
    end
  end

  def handle_call({:request, %{"method" => "tools/list"} = message}, _from, state) do
    maybe_report(state, {:mcp_request, message})

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
    name = params["name"]
    args = params["arguments"] || %{}
    maybe_report(state, {:mcp_tool_call, name, args})

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
    {:reply, :ok, state}
  end

  def handle_call(:crash, _from, state) do
    send(state.owner, {:mcp_fake_transport_exit, self(), :boom})
    {:reply, :ok, state}
  end

  def handle_call(:stop, _from, state) do
    maybe_report(state, {:mcp_transport_stopped, self()})
    {:stop, :normal, :ok, state}
  end

  defp request_error(state, name) do
    case Map.fetch(state.request_errors, name) do
      {:ok, reason} -> {:error, reason}
      :error -> :none
    end
  end

  defp maybe_report(%{test_pid: nil}, _message), do: :ok
  defp maybe_report(%{test_pid: test_pid}, message), do: send(test_pid, message)
end
