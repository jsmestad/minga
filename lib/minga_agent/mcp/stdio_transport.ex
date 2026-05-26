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
  @typep env_value :: charlist() | false
  @typep env_entry :: {charlist(), env_value()}
  @allowlisted_env_keys ~w(PATH HOME LANG LANGUAGE LC_ALL SSL_CERT_FILE SSL_CERT_DIR TMPDIR TEMP TMP XDG_RUNTIME_DIR)

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
        {:env, port_env(config)}
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

  @doc false
  @spec port_env(ServerConfig.t()) :: [env_entry()]
  def port_env(%ServerConfig{} = config), do: port_env(config, System.get_env())

  @doc false
  @spec port_env(ServerConfig.t(), %{String.t() => String.t()}) :: [env_entry()]
  def port_env(%ServerConfig{env: env}, inherited_env) when is_map(inherited_env) do
    explicit_env = Map.new(env)

    inherited_allowlist =
      inherited_env
      |> Enum.filter(fn {key, _value} -> allowlisted_env_key?(key) end)
      |> Map.new()

    merged_env = Map.merge(inherited_allowlist, explicit_env)
    unallowed_inherited = disallowed_inherited_env(inherited_env, explicit_env)

    merged_env
    |> Enum.map(&to_env_entry/1)
    |> Kernel.++(unallowed_inherited)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @spec disallowed_inherited_env(%{String.t() => String.t()}, %{String.t() => String.t()}) :: [
          env_entry()
        ]
  defp disallowed_inherited_env(inherited_env, explicit_env) do
    inherited_env
    |> Enum.reject(fn {key, _value} ->
      allowlisted_env_key?(key) or Map.has_key?(explicit_env, key)
    end)
    |> Enum.map(fn {key, _value} -> {String.to_charlist(key), false} end)
  end

  @spec allowlisted_env_key?(String.t()) :: boolean()
  defp allowlisted_env_key?(key) do
    key in @allowlisted_env_keys or String.starts_with?(key, "LC_")
  end

  @spec to_env_entry({String.t(), String.t()}) :: env_entry()
  defp to_env_entry({key, value}), do: {String.to_charlist(key), String.to_charlist(value)}

  @spec write_message(port(), map()) :: :ok | {:error, term()}
  defp write_message(port, message) do
    Port.command(port, [JSON.encode_to_iodata!(message), "\n"])
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
    case JSON.decode(line) do
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
