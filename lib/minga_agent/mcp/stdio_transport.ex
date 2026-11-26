defmodule MingaAgent.MCP.StdioTransport do
  @moduledoc """
  JSON-lines stdio transport for MCP servers.

  The MCP client process owns the port. Requests are serialized by the client
  GenServer, so this transport can wait synchronously for the matching JSON-RPC
  response while preserving simple failure handling for port exits.

  ## Framing across requests

  The transport value owns the frame decoder, and the client installs the value that each call returns. Port data that arrives during `request/3` and port data that arrives between requests (through `handle_transport_info/2`) pass through the same decoder in arrival order. A request that times out in the middle of a frame therefore leaves the partial frame in the decoder. The rest of that frame completes it later, and the late response is skipped because no request is waiting for its id.

  ## Framing limits

  JSON-lines framing has no header. Each message is one line, and the newline ends the frame.

  - **Port piece size:** the port is opened with `{:line, 65_536}`, so the runtime delivers a long line in pieces of at most 64 KiB.
  - **Frame size:** one frame, including its last piece, may hold at most `max_line_bytes` bytes. The default is 10 MiB (10_485_760 bytes). Set `:max_line_bytes` in the transport options, or the `:minga, :mcp_max_line_bytes` application environment value, to change it.
  - **Retained incomplete-frame bytes:** `MingaAgent.MCP.LineDecoder` retains at most `max_line_bytes` bytes for a frame that has not ended, including a frame that continues across requests.

  When a frame exceeds the limit, the transport closes the port and reports `{:line_too_long, byte_count}`, as a request error or as a `{:down, reason}` from `handle_transport_info/2`. The rest of that line can no longer be framed safely, so `MingaAgent.MCP.Client` marks only this server down. Other MCP servers keep their own transports.
  """

  @behaviour MingaAgent.MCP.Transport

  alias MingaAgent.MCP.LineDecoder
  alias MingaAgent.MCP.ServerConfig
  alias MingaAgent.Redaction

  @default_max_line_bytes 10_485_760

  @enforce_keys [:port, :decoder]
  defstruct [:port, :decoder]

  @type t :: %__MODULE__{port: port(), decoder: LineDecoder.t()}
  @typep env_value :: charlist() | false
  @typep env_entry :: {charlist(), env_value()}
  @allowlisted_env_keys ~w(PATH HOME LANG LANGUAGE LC_ALL SSL_CERT_FILE SSL_CERT_DIR TMPDIR TEMP TMP XDG_RUNTIME_DIR)

  @impl MingaAgent.MCP.Transport
  @spec start(ServerConfig.t(), pid(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(%ServerConfig{} = config, _owner, opts) do
    with {:ok, executable} <- resolve_executable(config, Keyword.take(opts, [:path])) do
      port_opts =
        working_directory(config) ++
          [
            :binary,
            :exit_status,
            :use_stdio,
            {:line, 65_536},
            {:args, config.args},
            {:env, port_env(config)}
          ]

      port = Port.open({:spawn_executable, executable}, port_opts)
      {:ok, new(port, Keyword.get(opts, :max_line_bytes, max_line_bytes()))}
    end
  rescue
    error -> {:error, Redaction.format_error(Exception.message(error))}
  end

  @doc "Wraps an open line-mode port whose response frames may hold at most `max_line_bytes` bytes."
  @spec new(port(), pos_integer()) :: t()
  def new(port, max_line_bytes) when is_port(port),
    do: %__MODULE__{port: port, decoder: LineDecoder.new(max_line_bytes)}

  @impl MingaAgent.MCP.Transport
  @spec request(t(), map(), timeout()) :: MingaAgent.MCP.Transport.request_result()
  def request(%__MODULE__{port: port} = transport, message, timeout) when is_map(message) do
    case write_message(port, message) do
      :ok -> await_response(transport, Map.fetch!(message, "id"), deadline(timeout))
      {:error, reason} -> {:error, reason, transport}
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

  # No request is waiting between requests, so a frame that completes here is a late response or a notification.
  @impl MingaAgent.MCP.Transport
  @spec handle_transport_info(term(), t()) :: {:ok, t()} | {:down, term()}
  def handle_transport_info({port, {:data, data}}, %__MODULE__{port: port} = transport) do
    case accept(transport, data) do
      {:partial, transport} -> {:ok, transport}
      {:frame, _unrequested_frame, transport} -> {:ok, transport}
      {:overflow, reason, _transport} -> {:down, reason}
    end
  end

  def handle_transport_info({port, {:exit_status, status}}, %__MODULE__{port: port}),
    do: {:down, {:exit_status, status}}

  def handle_transport_info(_message, %__MODULE__{} = transport), do: {:ok, transport}

  # Project declarations with a path arrive with an absolute program that was already examined. A bare name is
  # resolved on the absolute folders of PATH at start; a relative path requires the server's directory.
  @spec resolve_executable(ServerConfig.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp resolve_executable(%ServerConfig{command: command, cwd: cwd}, path_opts) do
    if Path.type(command) == :absolute do
      {:ok, command}
    else
      case Minga.Project.Trust.program(cwd, command, path_opts) do
        {:ok, path} -> {:ok, path}
        {:error, _reason} -> {:error, "MCP server executable not found: #{command}"}
      end
    end
  end

  # The server starts in the directory its config names: the project root. Without one it starts where Minga runs.
  @spec working_directory(ServerConfig.t()) :: [{:cd, charlist()}]
  defp working_directory(%ServerConfig{cwd: cwd}) when is_binary(cwd),
    do: [{:cd, String.to_charlist(cwd)}]

  defp working_directory(%ServerConfig{cwd: nil}), do: []

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
  @typep accepted ::
           {:partial, t()} | {:frame, binary(), t()} | {:overflow, LineDecoder.overflow(), t()}

  @spec deadline(timeout()) :: deadline()
  defp deadline(:infinity), do: :infinity

  defp deadline(timeout) when is_integer(timeout) and timeout >= 0,
    do: System.monotonic_time(:millisecond) + timeout

  @spec await_response(t(), term(), deadline()) :: MingaAgent.MCP.Transport.request_result()
  defp await_response(%__MODULE__{port: port} = transport, id, deadline) do
    receive do
      {^port, {:data, data}} ->
        case accept(transport, data) do
          {:partial, transport} -> await_response(transport, id, deadline)
          {:frame, frame, transport} -> handle_frame(transport, id, frame, deadline)
          {:overflow, reason, transport} -> {:error, reason, transport}
        end

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}, transport}
    after
      remaining_ms(deadline) -> {:error, :timeout, transport}
    end
  end

  @spec handle_frame(t(), term(), binary(), deadline()) ::
          MingaAgent.MCP.Transport.request_result()
  defp handle_frame(transport, id, frame, deadline) do
    case JSON.decode(frame) do
      {:ok, %{"id" => ^id, "result" => result}} ->
        {:ok, result, transport}

      {:ok, %{"id" => ^id, "error" => error}} ->
        {:error, error, transport}

      {:ok, _notification_or_other_response} ->
        await_response(transport, id, deadline)

      {:error, reason} ->
        {:error, {:invalid_json, reason}, transport}
    end
  end

  # Every port data message goes through this decoder, during a request or between requests.
  # The rest of an oversized line cannot be framed, so overflow closes the port and drops the retained bytes.
  @spec accept(t(), {:noeol | :eol, binary()}) :: accepted()
  defp accept(%__MODULE__{decoder: decoder} = transport, {:noeol, piece}) do
    case LineDecoder.push(decoder, piece) do
      {:ok, decoder} -> {:partial, %{transport | decoder: decoder}}
      {:error, overflow} -> close_on_overflow(transport, overflow)
    end
  end

  defp accept(%__MODULE__{decoder: decoder} = transport, {:eol, tail}) do
    case LineDecoder.finish(decoder, tail) do
      {:ok, frame, decoder} -> {:frame, frame, %{transport | decoder: decoder}}
      {:error, overflow} -> close_on_overflow(transport, overflow)
    end
  end

  @spec close_on_overflow(t(), LineDecoder.overflow()) :: accepted()
  defp close_on_overflow(%__MODULE__{decoder: decoder} = transport, overflow) do
    stop(transport)
    {:overflow, overflow, %{transport | decoder: LineDecoder.reset(decoder)}}
  end

  @doc false
  @spec max_line_bytes() :: pos_integer()
  def max_line_bytes,
    do: Application.get_env(:minga, :mcp_max_line_bytes, @default_max_line_bytes)

  @spec remaining_ms(deadline()) :: non_neg_integer() | :infinity
  defp remaining_ms(:infinity), do: :infinity
  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
