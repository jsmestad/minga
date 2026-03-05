defmodule Minga.LSP.Client do
  @moduledoc """
  GenServer managing a single language server instance.

  Spawns a language server as an Erlang Port, handles the JSON-RPC
  protocol, and manages the LSP lifecycle (initialize → initialized →
  working → shutdown → exit).

  One Client process exists per `{server_name, root_path}` pair. Multiple
  buffers of the same filetype in the same project share a single Client.

  ## Lifecycle

  1. `init/1` — spawns the language server Port
  2. Sends `initialize` request, waits for response
  3. Parses `ServerCapabilities`, negotiates offset encoding
  4. Sends `initialized` notification
  5. Status becomes `:ready` — document sync and diagnostics flow

  ## Diagnostics

  When the server sends `textDocument/publishDiagnostics`, this Client
  converts the positions and publishes them via `Minga.Diagnostics.publish/3`,
  making the Client just another diagnostic producer in the source-agnostic
  framework.
  """

  use GenServer

  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.Client.State
  alias Minga.LSP.JsonRpc
  alias Minga.LSP.PositionEncoding

  require Logger

  @request_timeout 30_000

  # ── Client API ─────────────────────────────────────────────────────────────

  @typedoc "Options for starting the client."
  @type start_opt ::
          {:server_config, Minga.LSP.ServerRegistry.server_config()}
          | {:root_path, String.t()}
          | {:diagnostics, GenServer.server()}
          | {:name, GenServer.name()}

  @doc "Starts an LSP client for a specific server and project root."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Returns the server's negotiated capabilities."
  @spec capabilities(GenServer.server()) :: map()
  def capabilities(server) do
    GenServer.call(server, :capabilities)
  end

  @doc "Returns the client's current status."
  @spec status(GenServer.server()) :: State.status()
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc "Returns the server name atom from config."
  @spec server_name(GenServer.server()) :: atom()
  def server_name(server) do
    GenServer.call(server, :server_name)
  end

  @doc "Returns the negotiated position encoding."
  @spec encoding(GenServer.server()) :: PositionEncoding.encoding()
  def encoding(server) do
    GenServer.call(server, :encoding)
  end

  @doc """
  Notifies the server that a document was opened.

  Sends `textDocument/didOpen` with the full document content.
  """
  @spec did_open(GenServer.server(), String.t(), String.t(), String.t()) :: :ok
  def did_open(server, uri, language_id, text)
      when is_binary(uri) and is_binary(language_id) and is_binary(text) do
    GenServer.cast(server, {:did_open, uri, language_id, text})
  end

  @doc """
  Notifies the server that a document changed.

  Sends `textDocument/didChange` with full document content (full sync).
  """
  @spec did_change(GenServer.server(), String.t(), String.t()) :: :ok
  def did_change(server, uri, text) when is_binary(uri) and is_binary(text) do
    GenServer.cast(server, {:did_change, uri, text})
  end

  @doc "Notifies the server that a document was saved."
  @spec did_save(GenServer.server(), String.t()) :: :ok
  def did_save(server, uri) when is_binary(uri) do
    GenServer.cast(server, {:did_save, uri})
  end

  @doc "Notifies the server that a document was closed."
  @spec did_close(GenServer.server(), String.t()) :: :ok
  def did_close(server, uri) when is_binary(uri) do
    GenServer.cast(server, {:did_close, uri})
  end

  @doc "Subscribes the calling process to LSP events."
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc """
  Sends an async LSP request and returns a reference.

  The response will be delivered as `{:lsp_response, ref, {:ok, result} | {:error, error}}`
  to the calling process. This is the primary API for features like completion,
  go-to-definition, and hover that need request/response semantics without
  blocking the caller.
  """
  @spec request(GenServer.server(), String.t(), map()) :: reference()
  def request(server, method, params) when is_binary(method) and is_map(params) do
    ref = make_ref()
    GenServer.cast(server, {:async_request, method, params, self(), ref})
    ref
  end

  @doc "Sends a shutdown request and exit notification to the server."
  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(server) do
    GenServer.call(server, :shutdown, @request_timeout)
  end

  # ── Server Callbacks ───────────────────────────────────────────────────────

  @impl true
  @spec init(keyword()) :: {:ok, State.t()} | {:stop, term()}
  def init(opts) do
    server_config = Keyword.fetch!(opts, :server_config)
    root_path = Keyword.fetch!(opts, :root_path)
    diagnostics = Keyword.get(opts, :diagnostics, Diagnostics)

    case find_executable(server_config) do
      {:ok, executable} ->
        port = spawn_server(executable, server_config.args, root_path)

        state = %State{
          server_config: server_config,
          root_path: root_path,
          port: port,
          encoding: :utf16
        }

        Process.put(:diagnostics_server, diagnostics)

        send(self(), :send_initialize)
        {:ok, state}

      :error ->
        {:stop, {:server_not_found, server_config.command}}
    end
  end

  @impl true
  def handle_call(:capabilities, _from, state) do
    {:reply, state.capabilities, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:server_name, _from, state) do
    {:reply, state.server_config.name, state}
  end

  def handle_call(:encoding, _from, state) do
    {:reply, state.encoding, state}
  end

  def handle_call(:root_path, _from, state) do
    {:reply, state.root_path, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  def handle_call(:shutdown, from, %{status: :ready} = state) do
    {id, state} = send_request(state, "shutdown", %{})
    state = put_pending(state, id, "shutdown", from)
    {:noreply, %{state | status: :shutdown}}
  end

  def handle_call(:shutdown, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:did_open, uri, language_id, text}, %{status: :ready} = state) do
    doc = %{uri: uri, version: 1}
    state = %{state | open_documents: Map.put(state.open_documents, uri, doc)}

    send_notification(state, "textDocument/didOpen", %{
      "textDocument" => %{
        "uri" => uri,
        "languageId" => language_id,
        "version" => 1,
        "text" => text
      }
    })

    {:noreply, state}
  end

  def handle_cast({:did_change, uri, text}, %{status: :ready} = state) do
    case Map.get(state.open_documents, uri) do
      nil ->
        {:noreply, state}

      %{version: version} ->
        new_version = version + 1
        doc = %{uri: uri, version: new_version}
        state = %{state | open_documents: Map.put(state.open_documents, uri, doc)}

        send_notification(state, "textDocument/didChange", %{
          "textDocument" => %{"uri" => uri, "version" => new_version},
          "contentChanges" => [%{"text" => text}]
        })

        {:noreply, state}
    end
  end

  def handle_cast({:did_save, uri}, %{status: :ready} = state) do
    if Map.has_key?(state.open_documents, uri) do
      send_notification(state, "textDocument/didSave", %{
        "textDocument" => %{"uri" => uri}
      })
    end

    {:noreply, state}
  end

  def handle_cast({:did_close, uri}, %{status: :ready} = state) do
    if Map.has_key?(state.open_documents, uri) do
      send_notification(state, "textDocument/didClose", %{
        "textDocument" => %{"uri" => uri}
      })

      diag_server = Process.get(:diagnostics_server, Diagnostics)
      Diagnostics.clear(diag_server, state.server_config.name, uri)
      state = %{state | open_documents: Map.delete(state.open_documents, uri)}
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:async_request, method, params, caller, ref}, %{status: :ready} = state) do
    {id, state} = send_request(state, method, params)
    state = put_pending(state, id, method, {:async, caller, ref})
    {:noreply, state}
  end

  # Ignore casts when not ready
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:send_initialize, state) do
    root_uri = "file://#{state.root_path}"

    params = %{
      "processId" => System.pid() |> String.to_integer(),
      "rootUri" => root_uri,
      "capabilities" => client_capabilities(),
      "initializationOptions" => state.server_config.init_options
    }

    {id, state} = send_request(state, "initialize", params)
    state = put_pending(state, id, "initialize", nil)
    {:noreply, %{state | status: :initializing}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data
    {messages, remaining} = JsonRpc.decode(buffer)
    state = %{state | buffer: remaining}

    state = Enum.reduce(messages, state, &handle_message/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("LSP server #{state.server_config.name} exited with code #{code}")
    {:stop, {:server_exited, code}, %{state | port: nil, status: :shutdown}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("LSP server #{state.server_config.name} port crashed: #{inspect(reason)}")
    {:stop, {:port_crashed, reason}, %{state | port: nil, status: :shutdown}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from, method: method}, pending} ->
        Logger.warning("LSP request #{method} (id=#{id}) timed out")
        reply_to_caller(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port} = _state) when is_port(port) do
    # Best-effort: try to send exit notification
    try do
      msg = JsonRpc.encode_notification("exit", %{})
      Port.command(port, IO.iodata_to_binary(msg))
    catch
      _, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Message Handling ───────────────────────────────────────────────────────

  @spec handle_message(map(), State.t()) :: State.t()
  defp handle_message(%{"id" => id, "result" => result}, state) do
    handle_response(id, {:ok, result}, state)
  end

  defp handle_message(%{"id" => id, "error" => error}, state) do
    handle_response(id, {:error, error}, state)
  end

  defp handle_message(%{"method" => method, "params" => params}, state)
       when is_binary(method) do
    handle_server_notification(method, params, state)
  end

  defp handle_message(%{"method" => method, "id" => id}, state)
       when is_binary(method) do
    # Server request — respond with empty result for now
    handle_server_request(method, id, %{}, state)
  end

  defp handle_message(_msg, state), do: state

  @spec handle_response(integer(), {:ok, map()} | {:error, map()}, State.t()) :: State.t()
  defp handle_response(id, result, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        Logger.warning("Received response for unknown request id=#{id}")
        state

      {%{method: method, from: from, timer: timer}, pending} ->
        if timer, do: Process.cancel_timer(timer)
        state = %{state | pending: pending}
        handle_method_response(method, result, from, state)
    end
  end

  @spec handle_method_response(
          String.t(),
          {:ok, map()} | {:error, map()},
          GenServer.from() | nil,
          State.t()
        ) :: State.t()
  defp handle_method_response("initialize", {:ok, result}, _from, state) do
    capabilities = Map.get(result, "capabilities", %{})

    encoding =
      result
      |> get_in(["capabilities", "positionEncoding"])
      |> List.wrap()
      |> PositionEncoding.negotiate()

    send_notification(state, "initialized", %{})

    Logger.info("LSP server #{state.server_config.name} initialized (encoding: #{encoding})")

    notify_subscribers(state.subscribers, {:lsp_ready, state.server_config.name})

    %{state | capabilities: capabilities, encoding: encoding, status: :ready}
  end

  defp handle_method_response("initialize", {:error, error}, _from, state) do
    Logger.error("LSP initialize failed: #{inspect(error)}")
    state
  end

  defp handle_method_response("shutdown", result, from, state) do
    if from do
      case result do
        {:ok, _} -> GenServer.reply(from, :ok)
        {:error, _} -> GenServer.reply(from, :ok)
      end
    end

    send_notification(state, "exit", %{})
    state
  end

  defp handle_method_response(_method, result, {:async, caller, ref}, state) do
    send(caller, {:lsp_response, ref, result})
    state
  end

  defp handle_method_response(_method, _result, from, state) do
    if from do
      GenServer.reply(from, :ok)
    end

    state
  end

  @spec handle_server_notification(String.t(), map(), State.t()) :: State.t()
  defp handle_server_notification("textDocument/publishDiagnostics", params, state) do
    uri = Map.get(params, "uri", "")
    raw_diags = Map.get(params, "diagnostics", [])

    diagnostics =
      Enum.map(raw_diags, fn raw ->
        convert_diagnostic(raw, uri, state)
      end)

    diag_server = Process.get(:diagnostics_server, Diagnostics)
    Diagnostics.publish(diag_server, state.server_config.name, uri, diagnostics)
    state
  end

  defp handle_server_notification("window/logMessage", params, state) do
    level = Map.get(params, "type", 4)
    message = Map.get(params, "message", "")

    log_level =
      case level do
        1 -> :error
        2 -> :warning
        3 -> :info
        _ -> :debug
      end

    Logger.log(log_level, "LSP [#{state.server_config.name}]: #{message}")
    state
  end

  defp handle_server_notification(_method, _params, state), do: state

  @spec handle_server_request(String.t(), integer(), map(), State.t()) :: State.t()
  defp handle_server_request("window/workDoneProgress/create", id, _params, state) do
    send_response(state, id, %{})
    state
  end

  defp handle_server_request("client/registerCapability", id, _params, state) do
    send_response(state, id, %{})
    state
  end

  defp handle_server_request(method, id, _params, state) do
    Logger.debug("Unhandled server request: #{method} (id=#{id})")
    send_response(state, id, %{})
    state
  end

  # ── Diagnostic Conversion ─────────────────────────────────────────────────

  @spec convert_diagnostic(map(), String.t(), State.t()) :: Diagnostic.t()
  defp convert_diagnostic(raw, _uri, state) do
    range = Map.get(raw, "range", %{})
    start_pos = Map.get(range, "start", %{"line" => 0, "character" => 0})
    end_pos = Map.get(range, "end", %{"line" => 0, "character" => 0})

    # For position conversion we'd need the line text. For now, when using
    # UTF-8 encoding the character offset equals byte offset. For UTF-16,
    # we store the raw character offset — accurate conversion requires
    # line text which will come from the buffer in the DocumentSync integration.
    start_line = Map.get(start_pos, "line", 0)
    start_col = Map.get(start_pos, "character", 0)
    end_line = Map.get(end_pos, "line", 0)
    end_col = Map.get(end_pos, "character", 0)

    %Diagnostic{
      range: %{
        start_line: start_line,
        start_col: start_col,
        end_line: end_line,
        end_col: end_col
      },
      severity: convert_severity(Map.get(raw, "severity", 1)),
      message: Map.get(raw, "message", ""),
      source: Map.get(raw, "source", to_string(state.server_config.name)),
      code: convert_code(Map.get(raw, "code"))
    }
  end

  @spec convert_severity(integer()) :: Diagnostic.severity()
  defp convert_severity(1), do: :error
  defp convert_severity(2), do: :warning
  defp convert_severity(3), do: :info
  defp convert_severity(4), do: :hint
  defp convert_severity(_), do: :info

  @spec convert_code(term()) :: String.t() | integer() | nil
  defp convert_code(nil), do: nil
  defp convert_code(code) when is_integer(code), do: code
  defp convert_code(code) when is_binary(code), do: code
  defp convert_code(code), do: inspect(code)

  # ── Port & Protocol Helpers ────────────────────────────────────────────────

  @spec spawn_server(String.t(), [String.t()], String.t()) :: port()
  defp spawn_server(executable, args, root_path) do
    Port.open(
      {:spawn_executable, String.to_charlist(executable)},
      [
        {:args, Enum.map(args, &String.to_charlist/1)},
        {:cd, String.to_charlist(root_path)},
        {:env, []},
        :binary,
        :exit_status,
        :use_stdio,
        :stream
      ]
    )
  end

  @spec find_executable(Minga.LSP.ServerConfig.t()) ::
          {:ok, String.t()} | :error
  defp find_executable(%Minga.LSP.ServerConfig{command: command}) do
    case System.find_executable(command) do
      nil -> :error
      path -> {:ok, path}
    end
  end

  @spec send_request(State.t(), String.t(), map()) :: {integer(), State.t()}
  defp send_request(state, method, params) do
    id = state.next_id
    msg = JsonRpc.encode_request(id, method, params)
    port_send(state.port, msg)
    {id, %{state | next_id: id + 1}}
  end

  @spec send_notification(State.t(), String.t(), map()) :: :ok
  defp send_notification(state, method, params) do
    msg = JsonRpc.encode_notification(method, params)
    port_send(state.port, msg)
  end

  @spec send_response(State.t(), integer(), map()) :: :ok
  defp send_response(state, id, result) do
    msg = JsonRpc.encode_response(id, result)
    port_send(state.port, msg)
  end

  @spec port_send(port(), iodata()) :: :ok
  defp port_send(port, msg) do
    Port.command(port, IO.iodata_to_binary(msg))
    :ok
  end

  @spec put_pending(State.t(), integer(), String.t(), State.pending_from()) :: State.t()
  defp put_pending(state, id, method, from) do
    timer = Process.send_after(self(), {:request_timeout, id}, @request_timeout)

    entry = %{method: method, from: from, timer: timer}
    %{state | pending: Map.put(state.pending, id, entry)}
  end

  @spec client_capabilities() :: map()
  defp client_capabilities do
    %{
      "general" => %{
        "positionEncodings" => PositionEncoding.client_supported_encodings()
      },
      "textDocument" => %{
        "synchronization" => %{
          "dynamicRegistration" => false,
          "didSave" => true
        },
        "publishDiagnostics" => %{
          "relatedInformation" => true
        },
        "completion" => %{
          "dynamicRegistration" => false,
          "completionItem" => %{
            "snippetSupport" => false,
            "insertReplaceSupport" => true
          },
          "completionItemKind" => %{
            "valueSet" => Enum.to_list(1..25)
          }
        }
      }
    }
  end

  @spec reply_to_caller(State.pending_from(), term()) :: :ok
  defp reply_to_caller(nil, _result), do: :ok

  defp reply_to_caller({:async, caller, ref}, result) do
    send(caller, {:lsp_response, ref, result})
    :ok
  end

  defp reply_to_caller(from, result) do
    GenServer.reply(from, result)
    :ok
  end

  @spec notify_subscribers([pid()], term()) :: :ok
  defp notify_subscribers(subscribers, message) do
    Enum.each(subscribers, &send(&1, message))
  end
end
