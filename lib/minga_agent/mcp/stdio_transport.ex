defmodule MingaAgent.MCP.StdioTransport do
  @moduledoc """
  JSON-lines stdio transport for MCP servers.

  The MCP client process owns the port. Requests are serialized by the client
  GenServer, so this transport can wait synchronously for the matching JSON-RPC
  response while preserving simple failure handling for port exits.

  ## Framing limits

  JSON-lines framing has no header. Each message is one line, and the newline ends the frame.

  - **Port piece size:** the port is opened with `{:line, 65_536}`, so the runtime delivers a long line in pieces of at most 64 KiB.
  - **Frame size:** one frame, including its last piece, may hold at most `max_line_bytes` bytes. The default is 10 MiB (10_485_760 bytes). Set `:max_line_bytes` in the transport options, or the `:minga, :mcp_max_line_bytes` application environment value, to change it.
  - **Retained incomplete-frame bytes:** `MingaAgent.MCP.LineDecoder` retains at most `max_line_bytes` bytes for a frame that has not ended.

  When a frame exceeds the limit, the transport closes the port and returns `{:error, {:line_too_long, byte_count}}`. The rest of that line can no longer be framed safely, so `MingaAgent.MCP.Client` marks only this server down. Other MCP servers keep their own transports.
  """

  @behaviour MingaAgent.MCP.Transport

  alias MingaAgent.MCP.LineDecoder
  alias MingaAgent.MCP.ServerConfig
  alias MingaAgent.Redaction

  @default_max_line_bytes 10_485_760

  @enforce_keys [:port]
  defstruct [:port, max_line_bytes: @default_max_line_bytes]

  @type t :: %__MODULE__{port: port(), max_line_bytes: pos_integer()}
  @typep env_value :: charlist() | false
  @typep env_entry :: {charlist(), env_value()}
  @allowlisted_env_keys ~w(PATH HOME LANG LANGUAGE LC_ALL SSL_CERT_FILE SSL_CERT_DIR TMPDIR TEMP TMP XDG_RUNTIME_DIR)

  @impl MingaAgent.MCP.Transport
  @spec start(ServerConfig.t(), pid(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(%ServerConfig{} = config, _owner, opts) do
    with {:ok, executable} <- resolve_executable(config.command) do
      port_opts = [
        :binary,
        :exit_status,
        :use_stdio,
        {:line, 65_536},
        {:args, config.args},
        {:env, port_env(config)}
      ]

      port = Port.open({:spawn_executable, executable}, port_opts)

      {:ok,
       %__MODULE__{
         port: port,
         max_line_bytes: Keyword.get(opts, :max_line_bytes, max_line_bytes())
       }}
    end
  rescue
    error -> {:error, Redaction.format_error(Exception.message(error))}
  end

  @impl MingaAgent.MCP.Transport
  @spec request(t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def request(%__MODULE__{port: port} = transport, message, timeout) when is_map(message) do
    with :ok <- write_message(port, message) do
      transport
      |> await_response(Map.fetch!(message, "id"), timeout)
      |> close_on_overflow(transport)
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

  @spec port_env(ServerConfig.t()) :: [env_entry()]
  def port_env(%ServerConfig{} = config), do: port_env(config, System.get_env())

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

  @spec await_response(t(), term(), timeout()) :: {:ok, map()} | {:error, term()}
  defp await_response(transport, id, :infinity),
    do: await_response_until(transport, id, :infinity, LineDecoder.new(transport.max_line_bytes))

  defp await_response(transport, id, timeout) when is_integer(timeout) and timeout >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_response_until(transport, id, deadline, LineDecoder.new(transport.max_line_bytes))
  end

  @spec await_response_until(t(), term(), deadline(), LineDecoder.t()) ::
          {:ok, map()} | {:error, term()}
  defp await_response_until(%__MODULE__{port: port} = transport, id, deadline, decoder) do
    receive do
      {^port, {:data, {:noeol, piece}}} ->
        with {:ok, decoder} <- LineDecoder.push(decoder, piece) do
          await_response_until(transport, id, deadline, decoder)
        end

      {^port, {:data, {:eol, tail}}} ->
        with {:ok, line, decoder} <- LineDecoder.finish(decoder, tail) do
          handle_line(transport, id, line, deadline, decoder)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      remaining_ms(deadline) -> {:error, :timeout}
    end
  end

  @spec handle_line(t(), term(), binary(), deadline(), LineDecoder.t()) ::
          {:ok, map()} | {:error, term()}
  defp handle_line(transport, id, line, deadline, decoder) do
    case JSON.decode(line) do
      {:ok, %{"id" => ^id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^id, "error" => error}} ->
        {:error, error}

      {:ok, _notification_or_other_response} ->
        await_response_until(transport, id, deadline, decoder)

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  # The rest of an oversized line cannot be framed, so the port is closed before the error is returned.
  @spec close_on_overflow({:ok, map()} | {:error, term()}, t()) :: {:ok, map()} | {:error, term()}
  defp close_on_overflow({:error, {:line_too_long, _bytes}} = error, transport) do
    stop(transport)
    error
  end

  defp close_on_overflow(result, _transport), do: result

  @doc false
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes,
    do: Application.get_env(:minga, :mcp_max_line_bytes, @default_max_line_bytes)

  @spec remaining_ms(deadline()) :: non_neg_integer() | :infinity
  defp remaining_ms(:infinity), do: :infinity
  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
