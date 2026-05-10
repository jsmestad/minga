defmodule MingaAgent.MCP.Client do
  @moduledoc """
  Session-scoped MCP client used by the native provider.

  The client performs the MCP initialize handshake, sends the initialized
  notification, lists tools, and exposes `call_tool/3` for provider tool
  callbacks. Production uses `MingaAgent.MCP.StdioTransport`; tests inject a
  fake in-BEAM transport.
  """

  use GenServer

  alias MingaAgent.MCP.ServerConfig
  alias MingaAgent.MCP.StdioTransport
  alias MingaAgent.MCP.Tool, as: MCPTool
  alias ReqLLM.Tool

  @default_timeout 5_000
  @protocol_version "2024-11-05"

  @enforce_keys [
    :config,
    :transport_mod,
    :transport,
    :tools,
    :next_id,
    :notify_pid,
    :alive,
    :request_timeout
  ]
  defstruct [
    :config,
    :transport_mod,
    :transport,
    :tools,
    :next_id,
    :notify_pid,
    :alive,
    :request_timeout
  ]

  @typedoc "Client process state."
  @type state :: %__MODULE__{
          config: ServerConfig.t(),
          transport_mod: module(),
          transport: term(),
          tools: [MCPTool.t()],
          next_id: pos_integer(),
          notify_pid: pid() | nil,
          alive: boolean(),
          request_timeout: timeout()
        }

  @doc "Starts a linked MCP client and completes handshake before returning."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Starts an unlinked MCP client and completes handshake before returning."
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @doc "Returns listed MCP tools with original and safe names."
  @spec list_tools(GenServer.server()) :: {:ok, [MCPTool.t()]} | {:error, term()}
  def list_tools(client), do: safe_call(client, :list_tools)

  @doc "Builds ReqLLM tools from the listed MCP tools."
  @spec reqllm_tools(GenServer.server()) :: {:ok, [Tool.t()]} | {:error, term()}
  def reqllm_tools(client), do: safe_call(client, :reqllm_tools)

  @doc "Calls an MCP tool by its original server-declared name."
  @spec call_tool(GenServer.server(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(client, original_name, args) when is_binary(original_name) and is_map(args) do
    safe_call(client, {:call_tool, original_name, args}, 30_000)
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()} | {:stop, term()}
  def init(opts) do
    with {:ok, config} <- normalize_config(opts) do
      transport_mod = Keyword.get(opts, :transport, StdioTransport)
      transport_opts = Keyword.get(opts, :transport_opts, [])
      request_timeout = Keyword.get(opts, :request_timeout, @default_timeout)

      case transport_mod.start(config, self(), transport_opts) do
        {:ok, transport} ->
          init_started_transport(opts, config, transport_mod, transport, request_timeout)

        {:error, reason} ->
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:list_tools, _from, %{alive: false} = state) do
    {:reply, {:error, unavailable_message(state)}, state}
  end

  def handle_call(:list_tools, _from, state) do
    {:reply, {:ok, state.tools}, state}
  end

  def handle_call(:reqllm_tools, _from, %{alive: false} = state) do
    {:reply, {:error, unavailable_message(state)}, state}
  end

  def handle_call(:reqllm_tools, _from, state) do
    tools = Enum.map(state.tools, &to_reqllm_tool(self(), &1))
    {:reply, {:ok, tools}, state}
  end

  def handle_call({:call_tool, _name, _args}, _from, %{alive: false} = state) do
    {:reply, {:error, unavailable_message(state)}, state}
  end

  def handle_call({:call_tool, name, args}, _from, state) do
    {request, state} = next_request(state, "tools/call", %{"name" => name, "arguments" => args})

    {reply, state} =
      case state.transport_mod.request(state.transport, request, state.request_timeout) do
        {:ok, result} ->
          {tool_call_reply(result), state}

        {:error, reason} ->
          {{:error, reason}, maybe_mark_transport_down(state, reason)}
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info(message, state) do
    case state.transport_mod.handle_transport_info(message, state.transport) do
      {:down, reason} when state.alive ->
        notify_down(state, reason)
        {:noreply, %{state | alive: false}}

      {:down, _reason} ->
        {:noreply, state}

      :ignore ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    state.transport_mod.stop(state.transport)
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec init_started_transport(keyword(), ServerConfig.t(), module(), term(), timeout()) ::
          {:ok, state()} | {:stop, term()}
  defp init_started_transport(opts, config, transport_mod, transport, request_timeout) do
    case initialize_and_list(transport_mod, transport, config, request_timeout) do
      {:ok, tools, next_id} ->
        state = %__MODULE__{
          config: config,
          transport_mod: transport_mod,
          transport: transport,
          tools: tools,
          next_id: next_id,
          notify_pid: Keyword.get(opts, :notify_pid),
          alive: true,
          request_timeout: request_timeout
        }

        {:ok, state}

      {:error, reason} ->
        stop_transport(transport_mod, transport)
        {:stop, reason}
    end
  end

  @spec normalize_config(keyword()) :: {:ok, ServerConfig.t()} | {:error, String.t()}
  defp normalize_config(opts) do
    case Keyword.fetch(opts, :server_config) do
      {:ok, server_config} ->
        server_config
        |> ServerConfig.normalize()
        |> case do
          {:ok, nil} -> {:error, "MCP server config is required"}
          other -> other
        end

      :error ->
        {:error, "MCP server config is required"}
    end
  end

  @spec initialize_and_list(module(), term(), ServerConfig.t(), timeout()) ::
          {:ok, [MCPTool.t()], pos_integer()} | {:error, term()}
  defp initialize_and_list(transport_mod, transport, config, timeout) do
    initialize = request(1, "initialize", initialize_params())

    with {:ok, _initialize_result} <- transport_mod.request(transport, initialize, timeout),
         :ok <- transport_mod.notify(transport, notification("notifications/initialized", %{})),
         {:ok, list_result} <-
           transport_mod.request(transport, request(2, "tools/list", %{}), timeout),
         {:ok, tools} <- listed_tools(config.name, list_result) do
      {:ok, tools, 3}
    end
  end

  @spec listed_tools(String.t(), map()) :: {:ok, [MCPTool.t()]} | {:error, String.t()}
  defp listed_tools(server_name, list_result) do
    case Map.get(list_result, "tools", []) do
      tools when is_list(tools) ->
        {:ok, MCPTool.from_list(server_name, tools)}

      other ->
        {:error, "MCP tools/list response must contain a tools list, got: #{inspect(other)}"}
    end
  end

  @spec initialize_params() :: map()
  defp initialize_params do
    %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "minga", "version" => "0.1.0"}
    }
  end

  @spec next_request(state(), String.t(), map()) :: {map(), state()}
  defp next_request(state, method, params) do
    {%{"jsonrpc" => "2.0", "id" => state.next_id, "method" => method, "params" => params},
     %{state | next_id: state.next_id + 1}}
  end

  @spec request(pos_integer(), String.t(), map()) :: map()
  defp request(id, method, params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  @spec notification(String.t(), map()) :: map()
  defp notification(method, params) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  @spec to_reqllm_tool(GenServer.server(), MCPTool.t()) :: Tool.t()
  defp to_reqllm_tool(client, %MCPTool{} = tool) do
    original_name = tool.name

    Tool.new!(
      name: tool.safe_name,
      description:
        "#{tool.description}\n\nMCP server: #{tool.server_name}. Original tool name: #{tool.name}.",
      parameter_schema: tool.input_schema,
      callback: fn args -> call_tool(client, original_name, args || %{}) end
    )
  end

  @spec tool_call_reply(term()) :: {:ok, term()} | {:error, term()}
  defp tool_call_reply(%{"isError" => true} = result), do: {:error, result}
  defp tool_call_reply(result), do: {:ok, result}

  @spec safe_call(GenServer.server(), term(), timeout()) :: term()
  defp safe_call(client, message, timeout \\ 5_000) do
    GenServer.call(client, message, timeout)
  catch
    :exit, reason -> {:error, {:mcp_client_unavailable, reason}}
  end

  @spec stop_transport(module(), term()) :: :ok
  defp stop_transport(transport_mod, transport) do
    transport_mod.stop(transport)
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec maybe_mark_transport_down(state(), term()) :: state()
  defp maybe_mark_transport_down(%{alive: true} = state, reason) do
    if transport_down_reason?(reason) do
      notify_down(state, reason)
      %{state | alive: false}
    else
      state
    end
  end

  defp maybe_mark_transport_down(state, _reason), do: state

  @spec transport_down_reason?(term()) :: boolean()
  defp transport_down_reason?({:exit_status, _status}), do: true
  defp transport_down_reason?(:badarg), do: true
  defp transport_down_reason?(:closed), do: true
  defp transport_down_reason?(:noproc), do: true
  defp transport_down_reason?(_reason), do: false

  @spec unavailable_message(state()) :: String.t()
  defp unavailable_message(state), do: "MCP server #{state.config.name} is unavailable"

  @spec notify_down(state(), term()) :: :ok
  defp notify_down(%{notify_pid: nil}, _reason), do: :ok

  defp notify_down(state, reason) do
    send(state.notify_pid, {:mcp_client_down, self(), state.config.name, reason})
    :ok
  end
end
