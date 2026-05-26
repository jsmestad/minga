defmodule MingaAgent.MCP.Registry do
  @moduledoc """
  In-memory registry for MCP clients attached to one native agent session.

  The native provider owns this struct in its GenServer state. Each MCP server
  still runs as its own client process, but the registry keeps routing data and
  cleanup logic in-process so tool calls do not need another coordinator hop.
  """

  alias MingaAgent.Event
  alias MingaAgent.MCP.Client, as: MCPClient
  alias MingaAgent.MCP.ServerConfig
  alias ReqLLM.Tool

  @enforce_keys [:clients]
  defstruct clients: %{}

  @typedoc "Stable user-facing MCP server name."
  @type server_name :: String.t()

  @typedoc "Provider-facing safe tool name."
  @type tool_name :: String.t()

  @typedoc "Tracked state for one MCP server client."
  @type client_entry :: %{
          pid: pid(),
          ref: reference(),
          tool_names: [tool_name()]
        }

  @typedoc "MCP client registry owned by the native provider."
  @type t :: %__MODULE__{clients: %{server_name() => client_entry()}}

  @typedoc "Options forwarded from the native provider to MCP clients."
  @type start_opt ::
          {:transport, module()}
          | {:transport_opts, keyword()}
          | {:request_timeout, timeout()}
          | {:notify_pid, pid()}
          | {:reserved_tool_names, [tool_name()]}
          | {:supervisor, GenServer.server() | nil}

  @doc "Starts all enabled MCP servers and returns the registry, tools, and startup failure messages."
  @spec start_all([ServerConfig.t()], pid(), [start_opt()]) :: {t(), [Tool.t()], [String.t()]}
  def start_all(configs, subscriber, opts \\ []) when is_list(configs) and is_pid(subscriber) do
    seen = MapSet.new(Keyword.get(opts, :reserved_tool_names, []))

    {registry, tools, failures, _seen} =
      Enum.reduce(configs, {new(), [], [], seen}, fn config, {registry, tools, failures, seen} ->
        case start_one(config, subscriber, opts) do
          {:ok, client, client_tools} ->
            {registry, client_tools, seen} =
              add_client(registry, config.name, client, client_tools, seen)

            {registry, tools ++ client_tools, failures, seen}

          {:error, message} ->
            {registry, tools, failures ++ [message], seen}
        end
      end)

    {registry, tools, failures}
  end

  @doc "Returns an empty registry."
  @spec new() :: t()
  def new, do: %__MODULE__{clients: %{}}

  @doc "Starts one MCP server if needed and returns the client pid."
  @spec ensure_server(t(), ServerConfig.t(), pid(), [start_opt()]) ::
          {:ok, t(), pid()} | {:error, String.t()}
  def ensure_server(
        %__MODULE__{} = registry,
        %ServerConfig{name: server_name} = config,
        subscriber,
        opts \\ []
      )
      when is_pid(subscriber) do
    case client_for_server(registry, server_name) do
      {:ok, pid} ->
        {:ok, registry, pid}

      :error ->
        case start_one(config, subscriber, opts) do
          {:ok, client, client_tools} ->
            {registry, _client_tools, _seen} =
              add_client(registry, config.name, client, client_tools, MapSet.new())

            {:ok, registry, client}

          {:error, message} ->
            {:error, message}
        end
    end
  end

  @doc "Returns the client pid for a started MCP server."
  @spec client_for_server(t() | nil, String.t()) :: {:ok, pid()} | :error
  def client_for_server(nil, _server_name), do: :error

  def client_for_server(%__MODULE__{} = registry, server_name) when is_binary(server_name) do
    case Map.fetch(registry.clients, server_name) do
      {:ok, %{pid: pid}} -> {:ok, pid}
      :error -> :error
    end
  end

  @doc "Returns the server name for a monitored client pid."
  @spec server_for_pid(t() | nil, pid()) :: String.t() | nil
  def server_for_pid(nil, _pid), do: nil

  def server_for_pid(%__MODULE__{} = registry, pid) when is_pid(pid) do
    Enum.find_value(registry.clients, fn {server_name, %{pid: client_pid}} ->
      if client_pid == pid, do: server_name
    end)
  end

  @doc "Removes one server from the registry and returns its removed tool names."
  @spec remove_server(t() | nil, String.t()) :: {t() | nil, [String.t()]}
  def remove_server(nil, _server_name), do: {nil, []}

  def remove_server(%__MODULE__{} = registry, server_name) when is_binary(server_name) do
    case Map.pop(registry.clients, server_name) do
      {nil, _clients} ->
        {registry, []}

      {%{pid: pid, ref: ref, tool_names: tool_names}, clients} ->
        Process.demonitor(ref, [:flush])
        stop_client(pid, server_name)
        {%{registry | clients: clients}, tool_names}
    end
  end

  @doc "Stops all tracked MCP clients."
  @spec stop_all(t() | nil) :: :ok
  def stop_all(nil), do: :ok

  def stop_all(%__MODULE__{} = registry) do
    Enum.each(registry.clients, fn {server_name, %{pid: pid, ref: ref}} ->
      Process.demonitor(ref, [:flush])
      stop_client(pid, server_name)
    end)

    :ok
  end

  @spec add_client(t(), String.t(), pid(), [Tool.t()], MapSet.t(String.t())) ::
          {t(), [Tool.t()], MapSet.t(String.t())}
  defp add_client(%__MODULE__{} = registry, server_name, client, tools, seen) do
    ref = Process.monitor(client)
    {tool_names, tools, seen} = unique_tool_names(seen, tools)

    entry = %{pid: client, ref: ref, tool_names: tool_names}

    registry = %{registry | clients: Map.put(registry.clients, server_name, entry)}

    {registry, tools, seen}
  end

  @spec unique_tool_names(MapSet.t(String.t()), [Tool.t()]) ::
          {[String.t()], [Tool.t()], MapSet.t(String.t())}
  defp unique_tool_names(seen, tools) do
    {tool_names, tools, seen} =
      Enum.reduce(tools, {[], [], seen}, fn tool, {names, acc, seen} ->
        name = unique_tool_name(tool.name, seen)
        tool = %{tool | name: name}
        {[name | names], [tool | acc], MapSet.put(seen, name)}
      end)

    {Enum.reverse(tool_names), Enum.reverse(tools), seen}
  end

  @spec unique_tool_name(String.t(), MapSet.t(String.t())) :: String.t()
  defp unique_tool_name(name, seen) do
    if MapSet.member?(seen, name) do
      unique_tool_name(name, seen, 2)
    else
      name
    end
  end

  @spec unique_tool_name(String.t(), MapSet.t(String.t()), pos_integer()) :: String.t()
  defp unique_tool_name(name, seen, index) do
    suffix = "_#{index}"
    max_base_length = max(1, 64 - String.length(suffix))
    candidate = String.slice(name, 0, max_base_length) <> suffix

    if MapSet.member?(seen, candidate) do
      unique_tool_name(name, seen, index + 1)
    else
      candidate
    end
  end

  @spec start_one(ServerConfig.t(), pid(), keyword()) ::
          {:ok, pid(), [Tool.t()]} | {:error, String.t()}
  defp start_one(%ServerConfig{} = config, subscriber, opts) do
    client_opts = [
      server_config: config,
      transport: Keyword.get(opts, :transport, MingaAgent.MCP.StdioTransport),
      transport_opts: Keyword.get(opts, :transport_opts, []),
      notify_pid: Keyword.get(opts, :notify_pid, self()),
      request_timeout: Keyword.get(opts, :request_timeout, 5_000)
    ]

    case start_client(
           client_opts,
           Keyword.get(opts, :supervisor, Minga.Extensions.MCP.Supervisor)
         ) do
      {:ok, client} ->
        tools_for_started_client(client, config, subscriber)

      {:error, reason} ->
        {:error, notify_start_failure(subscriber, config.name, reason)}
    end
  end

  @spec start_client(keyword(), GenServer.server() | nil) :: GenServer.on_start()
  defp start_client(client_opts, nil), do: MCPClient.start(client_opts)

  defp start_client(client_opts, supervisor) do
    if is_atom(supervisor) and Process.whereis(supervisor) == nil do
      MCPClient.start(client_opts)
    else
      Minga.Extensions.MCP.Supervisor.start_client(client_opts, supervisor)
    end
  end

  @spec tools_for_started_client(pid(), ServerConfig.t(), pid()) ::
          {:ok, pid(), [Tool.t()]} | {:error, String.t()}
  defp tools_for_started_client(client, config, subscriber) do
    case MCPClient.reqllm_tools(client) do
      {:ok, tools} ->
        {:ok, client, tools}

      {:error, reason} ->
        stop_client(client, config.name)
        {:error, notify_start_failure(subscriber, config.name, reason)}
    end
  end

  @spec notify_start_failure(pid(), String.t(), term()) :: String.t()
  defp notify_start_failure(subscriber, server_name, reason) do
    message =
      "MCP server #{server_name} failed to start: #{format_error(reason)}. Built-in tools remain available."

    Minga.Log.warning(:agent, "[Agent.Native] #{message}")
    send(subscriber, {:agent_provider_event, %Event.Error{message: message}})
    message
  end

  @spec stop_client(pid(), String.t() | nil) :: :ok
  defp stop_client(pid, server_name) when is_pid(pid) do
    GenServer.stop(pid, :normal, 1_000)
    :ok
  catch
    :exit, reason ->
      Minga.Log.warning(
        :agent,
        "MCP server #{server_name || inspect(pid)} stop failed: #{inspect(reason)}"
      )

      :ok
  end

  @spec format_error(term()) :: String.t()
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
