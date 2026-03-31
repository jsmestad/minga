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
  alias Minga.LSP.SemanticTokens

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

  @doc "Returns the project root path."
  @spec root_path(GenServer.server()) :: String.t()
  def root_path(server) do
    GenServer.call(server, :root_path)
  end

  @doc "Returns the monotonic start time (seconds) for uptime calculation."
  @spec started_at(GenServer.server()) :: integer() | nil
  def started_at(server) do
    GenServer.call(server, :started_at)
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

  @doc """
  Returns the sync kind negotiated with the server.

  - `:full` (1) — server expects full content on every change
  - `:incremental` (2) — server accepts incremental content changes
  - `:none` (0) — server doesn't want change notifications
  """
  @spec sync_kind(GenServer.server()) :: :none | :full | :incremental
  def sync_kind(server) do
    GenServer.call(server, :sync_kind)
  end

  @doc """
  Sends `textDocument/didChange` with incremental content changes.

  Each change is a `{start_line, start_col, end_line, end_col, new_text}`
  tuple matching the LSP TextDocumentContentChangeEvent format.
  """
  @spec did_change_incremental(
          GenServer.server(),
          String.t(),
          [
            {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
             String.t()}
          ]
        ) :: :ok
  def did_change_incremental(server, uri, changes)
      when is_binary(uri) and is_list(changes) do
    GenServer.cast(server, {:did_change_incremental, uri, changes})
  end

  @doc """
  Sends a synchronous LSP request and waits for the response.

  Blocks the caller for up to `timeout` milliseconds. Returns
  `{:ok, result}` or `{:error, reason}`. Use sparingly; prefer
  the async `request/3` for most features. This is intended for
  picker sources that need results before building candidates.
  """
  @spec request_sync(GenServer.server(), String.t(), map(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  def request_sync(server, method, params, timeout \\ @request_timeout)
      when is_binary(method) and is_map(params) do
    ref = request(server, method, params)

    receive do
      {:lsp_response, ^ref, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Returns the semantic token legend if the server supports semantic tokens.

  Returns `{token_types, token_modifiers}` or `nil`.
  """
  @spec semantic_token_legend(GenServer.server()) :: {[String.t()], [String.t()]} | nil
  def semantic_token_legend(server) do
    GenServer.call(server, :semantic_token_legend)
  end

  @doc """
  Requests full semantic tokens for a document.

  Returns a reference. The response will be delivered as
  `{:lsp_response, ref, {:ok, %{"data" => [...]}}}` with the
  delta-encoded token array.
  """
  @spec request_semantic_tokens(GenServer.server(), String.t()) :: reference()
  def request_semantic_tokens(server, uri) when is_binary(uri) do
    request(server, "textDocument/semanticTokens/full", %{
      "textDocument" => %{"uri" => uri}
    })
  end

  @doc """
  Requests semantic tokens for a specific range of a document.

  More efficient than full tokens when only the visible viewport
  needs highlighting.
  """
  @spec request_semantic_tokens_range(GenServer.server(), String.t(), map()) :: reference()
  def request_semantic_tokens_range(server, uri, range) when is_binary(uri) and is_map(range) do
    request(server, "textDocument/semanticTokens/range", %{
      "textDocument" => %{"uri" => uri},
      "range" => range
    })
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
          encoding: :utf16,
          started_at: System.monotonic_time(:second)
        }

        Process.put(:diagnostics_server, diagnostics)

        broadcast_status_changed(server_config.name, :starting, root_path)
        send(self(), :send_initialize)
        {:ok, state}

      :error ->
        msg = "#{server_config.name}: #{server_config.command} not found on PATH"
        Minga.Log.warning(:lsp, msg)

        Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{
          text: msg,
          level: :warning
        })

        {:stop, {:server_not_found, server_config.command}}
    end
  end

  @impl true
  def handle_call(:capabilities, _from, state) do
    {:reply, state.capabilities, state}
  end

  def handle_call(:sync_kind, _from, state) do
    {:reply, extract_sync_kind(state.capabilities), state}
  end

  def handle_call(:semantic_token_legend, _from, state) do
    {:reply, state.semantic_token_legend, state}
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

  def handle_call(:server_config, _from, state) do
    {:reply, state.server_config, state}
  end

  def handle_call(:started_at, _from, state) do
    {:reply, state.started_at, state}
  end

  def handle_call(:shutdown, from, %{status: :ready} = state) do
    {id, state} = send_request(state, "shutdown", %{})
    state = put_pending(state, id, "shutdown", from)
    broadcast_status_changed(state.server_config.name, :stopped, state.root_path)
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

  def handle_cast({:did_change_incremental, uri, changes}, %{status: :ready} = state) do
    case Map.get(state.open_documents, uri) do
      nil ->
        {:noreply, state}

      %{version: version} ->
        new_version = version + 1
        doc = %{uri: uri, version: new_version}
        state = %{state | open_documents: Map.put(state.open_documents, uri, doc)}

        content_changes =
          Enum.map(changes, fn {sl, sc, el, ec, text} ->
            %{
              "range" => %{
                "start" => %{"line" => sl, "character" => sc},
                "end" => %{"line" => el, "character" => ec}
              },
              "text" => text
            }
          end)

        send_notification(state, "textDocument/didChange", %{
          "textDocument" => %{"uri" => uri, "version" => new_version},
          "contentChanges" => content_changes
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
    broadcast_status_changed(state.server_config.name, :initializing, state.root_path)
    {:noreply, %{state | status: :initializing}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    buffer = state.buffer <> data
    {messages, remaining} = JsonRpc.decode(buffer)
    state = %{state | buffer: remaining}

    state = Enum.reduce(messages, state, &handle_message/2)
    {:noreply, state}
  end

  # Normal exit after deliberate shutdown: :stopped was already broadcast.
  def handle_info({port, {:exit_status, _code}}, %{port: port, status: :shutdown} = state) do
    {:stop, :normal, %{state | port: nil}}
  end

  # Unexpected exit: server died on its own.
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    msg = "LSP server #{state.server_config.name} exited with code #{code}"
    Minga.Log.warning(:lsp, msg)

    Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{text: msg, level: :warning})

    broadcast_status_changed(state.server_config.name, :crashed, state.root_path)
    {:stop, {:server_exited, code}, %{state | port: nil, status: :shutdown}}
  end

  # Normal port close after deliberate shutdown: :stopped was already broadcast.
  def handle_info({:EXIT, port, _reason}, %{port: port, status: :shutdown} = state) do
    {:stop, :normal, %{state | port: nil}}
  end

  # Unexpected port crash.
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    msg = "LSP server #{state.server_config.name} crashed: #{inspect(reason)}"
    Minga.Log.warning(:lsp, msg)

    Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{text: msg, level: :warning})

    broadcast_status_changed(state.server_config.name, :crashed, state.root_path)
    {:stop, {:port_crashed, reason}, %{state | port: nil, status: :shutdown}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from, method: method}, pending} ->
        Minga.Log.warning(:lsp, "LSP request #{method} (id=#{id}) timed out")
        reply_to_caller(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
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
        Minga.Log.warning(:lsp, "Received response for unknown request id=#{id}")
        state

      {%{method: method, from: from, timer: timer}, pending} ->
        if timer, do: Process.cancel_timer(timer)

        case result do
          {:ok, _} ->
            Minga.Log.debug(:lsp, "← #{method} (id: #{id}, ok)")

          {:error, err} ->
            Minga.Log.debug(:lsp, "← #{method} (id: #{id}, error: #{inspect(err)})")
        end

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

    Minga.Log.info(
      :lsp,
      "LSP server #{state.server_config.name} initialized (encoding: #{encoding})"
    )

    legend =
      case SemanticTokens.extract_legend(capabilities) do
        {types, mods} ->
          Minga.Log.info(
            :lsp,
            "LSP #{state.server_config.name} supports semantic tokens (#{length(types)} types, #{length(mods)} modifiers)"
          )

          {types, mods}

        :not_supported ->
          nil
      end

    broadcast_status_changed(state.server_config.name, :ready, state.root_path)

    %{
      state
      | capabilities: capabilities,
        encoding: encoding,
        status: :ready,
        semantic_token_legend: legend
    }
  end

  defp handle_method_response("initialize", {:error, error}, _from, state) do
    msg = "LSP #{state.server_config.name} initialization failed: #{inspect(error)}"
    Minga.Log.error(:lsp, msg)
    Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{text: msg, level: :error})
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
  defp handle_server_notification("textDocument/publishDiagnostics" = method, params, state) do
    diag_count = params |> Map.get("diagnostics", []) |> length()
    Minga.Log.debug(:lsp, "← #{method} (#{diag_count} items)")
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

    msg = "LSP [#{state.server_config.name}]: #{message}"

    case log_level do
      :error -> Minga.Log.error(:lsp, msg)
      :warning -> Minga.Log.warning(:lsp, msg)
      :info -> Minga.Log.info(:lsp, msg)
      :debug -> Minga.Log.debug(:lsp, msg)
    end

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
    Minga.Log.debug(:lsp, "Unhandled server request: #{method} (id=#{id})")
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
    Minga.Log.debug(:lsp, "→ #{method} (id: #{id})")
    msg = JsonRpc.encode_request(id, method, params)
    port_send(state.port, msg)
    {id, %{state | next_id: id + 1}}
  end

  @spec send_notification(State.t(), String.t(), map()) :: :ok
  defp send_notification(state, method, params) do
    Minga.Log.debug(:lsp, "→ #{method} (notification)")
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
            "insertReplaceSupport" => true,
            "documentationFormat" => ["markdown", "plaintext"],
            "resolveSupport" => %{
              "properties" => ["documentation", "detail", "additionalTextEdits"]
            }
          },
          "completionItemKind" => %{
            "valueSet" => Enum.to_list(1..25)
          }
        },
        "definition" => %{
          "dynamicRegistration" => false
        },
        "hover" => %{
          "dynamicRegistration" => false,
          "contentFormat" => ["markdown", "plaintext"]
        },
        "signatureHelp" => %{
          "dynamicRegistration" => false,
          "signatureInformation" => %{
            "documentationFormat" => ["markdown", "plaintext"],
            "parameterInformation" => %{"labelOffsetSupport" => true},
            "activeParameterSupport" => true
          }
        },
        "semanticTokens" => %{
          "dynamicRegistration" => false,
          "requests" => %{
            "full" => true,
            "range" => true
          },
          "tokenTypes" => SemanticTokens.standard_token_types(),
          "tokenModifiers" => SemanticTokens.standard_token_modifiers(),
          "formats" => ["relative"],
          "overlappingTokenSupport" => false,
          "multilineTokenSupport" => false
        },
        "references" => %{
          "dynamicRegistration" => false
        },
        "documentHighlight" => %{
          "dynamicRegistration" => false
        },
        "codeAction" => %{
          "dynamicRegistration" => false,
          "codeActionLiteralSupport" => %{
            "codeActionKind" => %{
              "valueSet" => [
                "quickfix",
                "refactor",
                "refactor.extract",
                "refactor.inline",
                "refactor.rewrite",
                "source",
                "source.organizeImports",
                "source.fixAll"
              ]
            }
          },
          "isPreferredSupport" => true,
          "resolveSupport" => %{
            "properties" => ["edit"]
          }
        },
        "rename" => %{
          "dynamicRegistration" => false,
          "prepareSupport" => true
        },
        "documentSymbol" => %{
          "dynamicRegistration" => false,
          "hierarchicalDocumentSymbolSupport" => true,
          "symbolKind" => %{
            "valueSet" => Enum.to_list(1..26)
          }
        },
        "typeDefinition" => %{
          "dynamicRegistration" => false
        },
        "implementation" => %{
          "dynamicRegistration" => false
        },
        "selectionRange" => %{
          "dynamicRegistration" => false
        },
        "callHierarchy" => %{
          "dynamicRegistration" => false
        },
        "codeLens" => %{
          "dynamicRegistration" => false
        },
        "inlayHint" => %{
          "dynamicRegistration" => false
        }
      },
      "workspace" => %{
        "symbol" => %{
          "dynamicRegistration" => false,
          "symbolKind" => %{
            "valueSet" => Enum.to_list(1..26)
          }
        },
        "workspaceEdit" => %{
          "documentChanges" => true
        }
      }
    }
  end

  @spec extract_sync_kind(map()) :: :none | :full | :incremental
  defp extract_sync_kind(capabilities) do
    sync = get_in(capabilities, ["textDocumentSync"])

    case sync do
      # TextDocumentSyncOptions object
      %{"change" => 2} -> :incremental
      %{"change" => 1} -> :full
      %{"change" => 0} -> :none
      # Shorthand integer
      2 -> :incremental
      1 -> :full
      0 -> :none
      # Default to full
      _ -> :full
    end
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

  @spec broadcast_status_changed(
          atom(),
          :starting | :initializing | :ready | :stopped | :crashed,
          String.t()
        ) :: :ok
  defp broadcast_status_changed(name, status, root_path) do
    Minga.Events.broadcast(
      :lsp_status_changed,
      %Minga.Events.LspStatusEvent{
        name: name,
        status: status,
        uri: "file://#{root_path}"
      }
    )
  end
end
