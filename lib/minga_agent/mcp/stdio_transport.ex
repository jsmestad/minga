defmodule MingaAgent.MCP.StdioTransport do
  @moduledoc """
  JSON-lines stdio transport for MCP servers.

  The MCP client process owns the port. Requests are serialized by the client
  GenServer, so this transport can wait synchronously for the matching JSON-RPC
  response while preserving simple failure handling for port exits.
  """

  @behaviour MingaAgent.MCP.Transport

  alias MingaAgent.MCP.ServerConfig

  @enforce_keys [:port]
  defstruct [:port]

  @type t :: %__MODULE__{port: port()}

  @impl MingaAgent.MCP.Transport
  @spec start(ServerConfig.t(), pid(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(%ServerConfig{} = config, _owner, _opts) do
    with {:ok, executable} <- resolve_executable(config.command) do
      port_opts = [
        :binary,
        :exit_status,
        :use_stdio,
        {:line, 65_536},
        {:args, config.args},
        {:env, env_to_charlists(config.env)}
      ]

      {:ok, %__MODULE__{port: Port.open({:spawn_executable, executable}, port_opts)}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl MingaAgent.MCP.Transport
  @spec request(t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def request(%__MODULE__{port: port}, message, timeout) when is_map(message) do
    with :ok <- write_message(port, message) do
      await_response(port, Map.fetch!(message, "id"), timeout)
    end
  end

  @impl MingaAgent.MCP.Transport
  @spec notify(t(), map()) :: :ok | {:error, term()}
  def notify(%__MODULE__{port: port}, message) when is_map(message) do
    write_message(port, message)
  end

  @impl MingaAgent.MCP.Transport
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{port: port}) do
    Port.close(port)
    :ok
  catch
    :error, _ -> :ok
    :exit, _ -> :ok
  end

  @impl MingaAgent.MCP.Transport
  @spec handle_transport_info(term(), t()) :: :ignore | {:down, term()}
  def handle_transport_info({port, {:exit_status, status}}, %__MODULE__{port: port}),
    do: {:down, {:exit_status, status}}

  def handle_transport_info({_port, {:data, _line}}, %__MODULE__{}), do: :ignore
  def handle_transport_info(_message, %__MODULE__{}), do: :ignore

  @spec resolve_executable(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp resolve_executable(command) do
    if Path.type(command) == :absolute do
      {:ok, command}
    else
      case System.find_executable(command) do
        nil -> {:error, "MCP server executable not found: #{command}"}
        path -> {:ok, path}
      end
    end
  end

  @spec env_to_charlists(%{String.t() => String.t()}) :: [{charlist(), charlist()}]
  defp env_to_charlists(env) do
    Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  @spec write_message(port(), map()) :: :ok | {:error, term()}
  defp write_message(port, message) do
    Port.command(port, [Jason.encode!(message), "\n"])
    :ok
  catch
    :error, reason -> {:error, reason}
    :exit, reason -> {:error, reason}
  end

  @typep deadline :: integer() | :infinity

  @spec await_response(port(), term(), timeout()) :: {:ok, map()} | {:error, term()}
  defp await_response(port, id, :infinity), do: await_response_until(port, id, :infinity, "")

  defp await_response(port, id, timeout) when is_integer(timeout) and timeout >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_response_until(port, id, deadline, "")
  end

  @spec await_response_until(port(), term(), deadline(), binary()) ::
          {:ok, map()} | {:error, term()}
  defp await_response_until(port, id, deadline, buffered) do
    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        await_response_until(port, id, deadline, buffered <> chunk)

      {^port, {:data, {:eol, line}}} ->
        handle_line(port, id, buffered <> line, deadline)

      {^port, {:data, line}} when is_binary(line) ->
        handle_line(port, id, buffered <> line, deadline)

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      remaining_ms(deadline) -> {:error, :timeout}
    end
  end

  @spec handle_line(port(), term(), binary(), deadline()) :: {:ok, map()} | {:error, term()}
  defp handle_line(port, id, line, deadline) do
    case Jason.decode(line) do
      {:ok, %{"id" => ^id, "result" => result}} -> {:ok, result}
      {:ok, %{"id" => ^id, "error" => error}} -> {:error, error}
      {:ok, _notification_or_other_response} -> await_response_until(port, id, deadline, "")
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  @spec remaining_ms(deadline()) :: non_neg_integer() | :infinity
  defp remaining_ms(:infinity), do: :infinity
  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
