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

  alias Minga.Config
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic
  alias Minga.LSP.Client.RequestRegistry
  alias Minga.LSP.Client.State
  alias Minga.LSP.GlobMatcher
  alias Minga.LSP.JsonRpc
  alias Minga.LSP.PositionEncoding
  alias Minga.LSP.SemanticTokens
  alias Minga.Log

  @request_timeout 30_000
  @canceled_request_tombstone_ttl 30_000

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
  Sends `workspace/didChangeWatchedFiles` for file changes matching registered watchers.

  Accepts a list of `{path, change_type}` tuples where `change_type` is
  `:created`, `:changed`, or `:deleted`. Filters against registered glob
  patterns and watch kinds, then sends the notification for matching changes.
  No-op when no watchers are registered or no changes match.
  """
  @spec notify_file_changes(GenServer.server(), [{String.t(), GlobMatcher.change_type()}]) :: :ok
  def notify_file_changes(server, changes) when is_list(changes) do
    GenServer.cast(server, {:notify_file_changes, changes})
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

  @doc "Queues cancellation of an asynchronous request by the reference returned from `request/3`."
  @spec cancel_request(GenServer.server(), reference()) :: :ok
  def cancel_request(server, ref) when is_reference(ref) do
    GenServer.cast(server, {:cancel_request, ref})
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

  @doc """
  Requests formatting for the entire document.

  Returns a reference. The response will be delivered as
  `{:lsp_response, ref, {:ok, [text_edits]}}` with an array of TextEdit objects,
  or empty array if no changes needed.
  """
  @spec request_formatting(GenServer.server(), String.t()) :: reference()
  def request_formatting(server, uri) when is_binary(uri) do
    request(server, "textDocument/formatting", %{
      "textDocument" => %{"uri" => uri},
      "options" => %{
        "tabSize" => 2,
        "insertSpaces" => true
      }
    })
  end

  @doc """
  Requests formatting for a specific range of a document.

  The range is specified as `{start_line, start_col, end_line, end_col}`.
  Returns a reference. The response will be delivered as
  `{:lsp_response, ref, {:ok, [text_edits]}}`.
  """
  @spec request_range_formatting(
          GenServer.server(),
          String.t(),
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
        ) :: reference()
  def request_range_formatting(server, uri, {start_line, start_col, end_line, end_col})
      when is_binary(uri) do
    request(server, "textDocument/rangeFormatting", %{
      "textDocument" => %{"uri" => uri},
      "range" => %{
        "start" => %{"line" => start_line, "character" => start_col},
        "end" => %{"line" => end_line, "character" => end_col}
      },
      "options" => %{
        "tabSize" => 2,
        "insertSpaces" => true
      }
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
        Log.warning(:lsp, msg)

        Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{
          text: msg,
          level: :warning
        })

        {:stop, {:server_not_found, server_config.command}}
    end
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), State.t()) ::
          {:reply, term(), State.t()} | {:noreply, State.t()}
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
    {:noreply, send_did_open(state, uri, language_id, text)}
  end

  def handle_cast({:did_open, uri, language_id, text}, state) do
    {:noreply, queue_document_open(state, uri, language_id, text)}
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

  def handle_cast({:did_change, uri, text}, state) do
    {:noreply, update_queued_document_text(state, uri, text)}
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

  def handle_cast({:did_close, uri}, state) do
    {:noreply, %{state | pending_document_opens: Map.delete(state.pending_document_opens, uri)}}
  end

  def handle_cast({:async_request, method, params, caller, ref}, %{status: :ready} = state) do
    {id, state} = send_request(state, method, params)
    state = put_pending(state, id, method, {:async, caller, ref})
    {:noreply, state}
  end

  def handle_cast({:cancel_request, ref}, state) do
    case cancel_request_by_ref(state, ref) do
      {:ok, state} ->
        {:noreply, state}

      {:error, :not_found, state} ->
        Log.debug(:lsp, "Skipping cancellation for unknown LSP request ref=#{inspect(ref)}")
        {:noreply, state}
    end
  end

  def handle_cast({:notify_file_changes, changes}, %{status: :ready} = state) do
    matching = filter_matching_changes(state, changes)

    if matching != [] do
      send_notification(state, "workspace/didChangeWatchedFiles", %{"changes" => matching})
    end

    {:noreply, state}
  end

  # Ignore casts when not ready
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), State.t()) ::
          {:noreply, State.t()} | {:stop, term(), State.t()}
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
    Log.warning(:lsp, msg)

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
    Log.warning(:lsp, msg)

    Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{text: msg, level: :warning})

    broadcast_status_changed(state.server_config.name, :crashed, state.root_path)
    {:stop, {:port_crashed, reason}, %{state | port: nil, status: :shutdown}}
  end

  def handle_info({:request_timeout, id}, state) do
    case RequestRegistry.fetch(state.requests, id) do
      :error ->
        {:noreply, state}

      {:ok, %{from: from, method: method}} ->
        Log.warning(:lsp, "LSP request #{method} (id=#{id}) timed out")
        state = cancel_request_by_id(state, id)
        reply_to_caller(from, {:error, :timeout})
        {:noreply, state}
    end
  end

  def handle_info({:expire_canceled_request, id}, state) do
    requests = RequestRegistry.drop_canceled(state.requests, id)
    {:noreply, %{state | requests: requests}}
  end

  def handle_info({:DOWN, monitor, :process, _caller, _reason}, state) do
    case RequestRegistry.id_for_monitor(state.requests, monitor) do
      {:ok, id} -> {:noreply, cancel_request_by_id(state, id)}
      :error -> {:noreply, state}
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

  defp handle_message(%{"method" => method, "id" => id, "params" => params}, state)
       when is_binary(method) do
    handle_server_request(method, id, params, state)
  end

  defp handle_message(%{"method" => method, "id" => id}, state)
       when is_binary(method) do
    handle_server_request(method, id, %{}, state)
  end

  defp handle_message(%{"method" => method, "params" => params}, state)
       when is_binary(method) do
    handle_server_notification(method, params, state)
  end

  defp handle_message(_msg, state), do: state

  @spec handle_response(JsonRpc.id(), {:ok, term()} | {:error, map()}, State.t()) :: State.t()
  defp handle_response(id, result, state) do
    case RequestRegistry.fetch(state.requests, id) do
      :error ->
        discard_or_log_unknown_response(state, id)

      {:ok, %{method: method, from: from}} ->
        state = drop_pending(state, id)

        case result do
          {:ok, _} ->
            Log.debug(:lsp, "← #{method} (id: #{id}, ok)")

          {:error, err} ->
            Log.debug(:lsp, "← #{method} (id: #{id}, error: #{inspect(err)})")
        end

        handle_method_response(method, result, from, state)
    end
  end

  @spec handle_method_response(
          String.t(),
          {:ok, term()} | {:error, term()},
          State.pending_from(),
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

    Log.info(
      :lsp,
      "LSP server #{state.server_config.name} initialized (encoding: #{encoding})"
    )

    legend =
      case SemanticTokens.extract_legend(capabilities) do
        {types, mods} ->
          Log.info(
            :lsp,
            "LSP #{state.server_config.name} supports semantic tokens (#{Enum.count(types)} types, #{Enum.count(mods)} modifiers)"
          )

          {types, mods}

        :not_supported ->
          nil
      end

    broadcast_status_changed(state.server_config.name, :ready, state.root_path)

    state = %{
      state
      | capabilities: capabilities,
        encoding: encoding,
        status: :ready,
        semantic_token_legend: legend
    }

    flush_queued_document_opens(state)
  end

  defp handle_method_response("initialize", {:error, error}, _from, state) do
    msg = "LSP #{state.server_config.name} initialization failed: #{inspect(error)}"
    Log.error(:lsp, msg)
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
    diag_count = params |> Map.get("diagnostics", []) |> Enum.count()
    Log.debug(:lsp, "← #{method} (#{diag_count} items)")
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
    surface_lsp_message(params, state)
    state
  end

  defp handle_server_notification("window/showMessage", params, state) do
    surface_lsp_message(params, state)
    state
  end

  defp handle_server_notification(_method, _params, state), do: state

  @spec handle_server_request(String.t(), JsonRpc.id(), map(), State.t()) :: State.t()
  defp handle_server_request("window/workDoneProgress/create", id, _params, state) do
    send_response(state, id, nil)
    state
  end

  defp handle_server_request("client/registerCapability", id, params, state) do
    send_response(state, id, nil)
    registrations = Map.get(params, "registrations", [])
    new_watchers = extract_file_watchers(registrations)

    if new_watchers != [] do
      Log.debug(:lsp, "Registered #{Enum.count(new_watchers)} file watcher(s)")
    end

    %{state | file_watchers: state.file_watchers ++ new_watchers}
  end

  defp handle_server_request("client/unregisterCapability", id, params, state) do
    send_response(state, id, nil)
    # "unregisterations" is the LSP spec's spelling (intentionally misspelled on the wire)
    unregistrations = Map.get(params, "unregisterations", [])

    ids_to_remove =
      for %{"id" => uid, "method" => "workspace/didChangeWatchedFiles"} <- unregistrations,
          do: uid

    remaining = Enum.reject(state.file_watchers, fn w -> w.id in ids_to_remove end)
    %{state | file_watchers: remaining}
  end

  defp handle_server_request("workspace/configuration", id, params, state) do
    settings = Config.get_lsp_settings(state.server_config)
    results = Enum.map(configuration_items(params), &configuration_item(settings, &1))

    send_response(state, id, results)
    state
  end

  defp handle_server_request("window/showMessageRequest", id, params, state) do
    # Shrunk scope: surface the message to the user via the log pipeline and
    # respond with `null` (no action selected) so the server does not hang
    # waiting on a choice. A minibuffer picker over `actions` is a follow-up
    # (see ticket #1270, step 3-7).
    surface_lsp_message(params, state)
    send_response(state, id, nil)
    state
  end

  defp handle_server_request(method, id, _params, state) do
    Log.debug(:lsp, "Unhandled server request: #{method} (id=#{id})")
    send_error_response(state, id, -32_601, "Method not found: #{method}")
    state
  end

  @spec configuration_items(map()) :: [term()]
  defp configuration_items(%{"items" => items}) when is_list(items), do: items
  defp configuration_items(_params), do: []

  @spec configuration_item(map(), term()) :: term()
  defp configuration_item(settings, %{"section" => section}) when is_binary(section) do
    configuration_section(settings, section)
  end

  defp configuration_item(settings, _item), do: settings

  @spec surface_lsp_message(map(), State.t()) :: :ok
  defp surface_lsp_message(params, state) do
    type = Map.get(params, "type", 4)
    message = Map.get(params, "message", "")
    {severity, level} = lsp_message_severity(type)
    text = "[LSP/#{severity}] #{state.server_config.name}: #{message}"

    Log.info(:lsp, text)
    Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{text: text, level: level})
  end

  @spec lsp_message_severity(integer()) :: {String.t(), Minga.Events.LogMessageEvent.level()}
  defp lsp_message_severity(1), do: {"error", :error}
  defp lsp_message_severity(2), do: {"warning", :warning}
  defp lsp_message_severity(3), do: {"info", :info}
  defp lsp_message_severity(_), do: {"log", :info}

  @spec configuration_section(map(), String.t()) :: term()
  defp configuration_section(settings, section) do
    case fetch_configuration_section(settings, section) do
      {:ok, value} -> value
      :error -> %{}
    end
  end

  @spec fetch_configuration_section(map(), String.t()) :: {:ok, term()} | :error
  defp fetch_configuration_section(settings, section) do
    case Map.fetch(settings, section) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_configuration_path(settings, String.split(section, "."))
    end
  end

  @spec fetch_configuration_path(term(), [String.t()]) :: {:ok, term()} | :error
  defp fetch_configuration_path(settings, [key]) when is_map(settings),
    do: Map.fetch(settings, key)

  defp fetch_configuration_path(settings, [key | rest]) when is_map(settings) do
    case Map.fetch(settings, key) do
      {:ok, value} -> fetch_configuration_path(value, rest)
      :error -> :error
    end
  end

  defp fetch_configuration_path(_settings, _path), do: :error

  # ── File Watcher Registration ─────────────────────────────────────────────

  @default_watch_kind 7

  @spec extract_file_watchers([map()]) :: [State.file_watcher()]
  defp extract_file_watchers(registrations) do
    registrations
    |> Enum.filter(&(&1["method"] == "workspace/didChangeWatchedFiles"))
    |> Enum.flat_map(fn reg ->
      id = reg["id"] || ""
      watchers = get_in(reg, ["registerOptions", "watchers"]) || []
      Enum.flat_map(watchers, &compile_watcher(&1, id))
    end)
  end

  @spec compile_watcher(map(), String.t()) :: [State.file_watcher()]
  defp compile_watcher(watcher_spec, registration_id) do
    pattern = watcher_spec["globPattern"]
    kind = watcher_spec["kind"] || @default_watch_kind

    case GlobMatcher.compile(pattern) do
      {:ok, compiled} ->
        [%{id: registration_id, pattern: compiled, kind: kind}]

      {:error, _} ->
        Log.warning(:lsp, "Invalid glob pattern in file watcher: #{inspect(pattern)}")
        []
    end
  end

  @spec filter_matching_changes(State.t(), [{String.t(), GlobMatcher.change_type()}]) :: [map()]
  defp filter_matching_changes(%{file_watchers: []}, _changes), do: []

  defp filter_matching_changes(state, changes) do
    root = state.root_path

    Enum.flat_map(changes, fn {path, change_type} ->
      rel_path = Path.relative_to(path, root)

      matched =
        Enum.any?(state.file_watchers, fn watcher ->
          GlobMatcher.matches?(watcher.pattern, rel_path) and
            GlobMatcher.matches_kind?(watcher.kind, change_type)
        end)

      if matched do
        [%{"uri" => "file://" <> path, "type" => change_type_to_lsp(change_type)}]
      else
        []
      end
    end)
  end

  @spec change_type_to_lsp(GlobMatcher.change_type()) :: 1 | 2 | 3
  defp change_type_to_lsp(:created), do: 1
  defp change_type_to_lsp(:changed), do: 2
  defp change_type_to_lsp(:deleted), do: 3

  # ── Diagnostic Conversion ─────────────────────────────────────────────────

  @spec convert_diagnostic(map(), String.t(), State.t()) :: Diagnostic.t()
  defp convert_diagnostic(raw, _uri, state) do
    range = Map.get(raw, "range", %{})
    start_pos = Map.get(range, "start", %{"line" => 0, "character" => 0})
    end_pos = Map.get(range, "end", %{"line" => 0, "character" => 0})

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
      code: convert_code(Map.get(raw, "code")),
      encoding: state.encoding
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

  # ── Document Sync Helpers ─────────────────────────────────────────────────

  @spec send_did_open(State.t(), String.t(), String.t(), String.t()) :: State.t()
  defp send_did_open(state, uri, language_id, text) do
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

    state
  end

  @spec queue_document_open(State.t(), String.t(), String.t(), String.t()) :: State.t()
  defp queue_document_open(state, uri, language_id, text) do
    pending_open = %{uri: uri, language_id: language_id, text: text}
    pending = Map.put(state.pending_document_opens, uri, pending_open)
    %{state | pending_document_opens: pending}
  end

  @spec update_queued_document_text(State.t(), String.t(), String.t()) :: State.t()
  defp update_queued_document_text(state, uri, text) do
    case Map.fetch(state.pending_document_opens, uri) do
      {:ok, pending_open} ->
        pending = Map.put(state.pending_document_opens, uri, Map.put(pending_open, :text, text))
        %{state | pending_document_opens: pending}

      :error ->
        state
    end
  end

  @spec flush_queued_document_opens(State.t()) :: State.t()
  defp flush_queued_document_opens(state) do
    pending_opens = Map.values(state.pending_document_opens)
    state = %{state | pending_document_opens: %{}}

    Enum.reduce(pending_opens, state, fn %{uri: uri, language_id: language_id, text: text}, acc ->
      send_did_open(acc, uri, language_id, text)
    end)
  end

  # ── Port & Protocol Helpers ────────────────────────────────────────────────

  @spec spawn_server(String.t(), [String.t()], String.t()) :: port()
  defp spawn_server(executable, args, root_path) do
    stderr_path = child_stderr_log_path()

    Port.open(
      {:spawn_executable, ~c"/bin/sh"},
      [
        {:args,
         Enum.map(
           [
             "-c",
             "log_path=$1; shift; exec \"$@\" 2>> \"$log_path\"",
             "minga-lsp-wrapper",
             stderr_path,
             executable | args
           ],
           &String.to_charlist/1
         )},
        {:cd, String.to_charlist(root_path)},
        {:env, []},
        :binary,
        :exit_status,
        :use_stdio,
        :stream
      ]
    )
  end

  @spec child_stderr_log_path() :: String.t()
  defp child_stderr_log_path do
    log_dir = Path.expand("~/.local/share/minga")
    File.mkdir_p!(log_dir)
    Path.join(log_dir, "minga.log")
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
    Log.debug(:lsp, "→ #{method} (id: #{id})")
    msg = JsonRpc.encode_request(id, method, params)
    port_send(state.port, msg)
    {id, %{state | next_id: id + 1}}
  end

  @spec send_notification(State.t(), String.t(), map()) :: :ok
  defp send_notification(state, method, params) do
    Log.debug(:lsp, "→ #{method} (notification)")
    msg = JsonRpc.encode_notification(method, params)
    port_send(state.port, msg)
  end

  @spec send_response(State.t(), JsonRpc.id(), JsonRpc.json_value()) :: :ok
  defp send_response(state, id, result) do
    msg = JsonRpc.encode_response(id, result)
    port_send(state.port, msg)
  end

  @spec send_error_response(State.t(), JsonRpc.id(), integer(), String.t()) :: :ok
  defp send_error_response(state, id, code, message) do
    msg = JsonRpc.encode_error_response(id, code, message)
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
    {request_ref, caller_monitor} = pending_identity(from)

    entry = %{
      method: method,
      from: from,
      timer: timer,
      request_ref: request_ref,
      caller_monitor: caller_monitor
    }

    %{state | requests: RequestRegistry.put(state.requests, id, entry)}
  end

  @spec pending_identity(State.pending_from()) :: {reference() | nil, reference() | nil}
  defp pending_identity({:async, caller, request_ref}) do
    {request_ref, Process.monitor(caller)}
  end

  defp pending_identity(_from), do: {nil, nil}

  @spec cancel_request_by_ref(State.t(), reference()) ::
          {:ok, State.t()} | {:error, :not_found, State.t()}
  defp cancel_request_by_ref(state, ref) do
    case RequestRegistry.id_for_ref(state.requests, ref) do
      {:ok, id} -> {:ok, cancel_request_by_id(state, id)}
      :error -> {:error, :not_found, state}
    end
  end

  @spec cancel_request_by_id(State.t(), integer()) :: State.t()
  defp cancel_request_by_id(state, id) do
    case RequestRegistry.fetch(state.requests, id) do
      {:ok, _entry} ->
        send_notification(state, "$/cancelRequest", %{"id" => id})
        state |> drop_pending(id) |> put_canceled_tombstone(id)

      :error ->
        state
    end
  end

  @spec drop_pending(State.t(), integer()) :: State.t()
  defp drop_pending(state, id) do
    case RequestRegistry.pop(state.requests, id) do
      {nil, _requests} ->
        state

      {entry, requests} ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        if entry.caller_monitor, do: Process.demonitor(entry.caller_monitor, [:flush])
        %{state | requests: requests}
    end
  end

  @spec put_canceled_tombstone(State.t(), integer()) :: State.t()
  defp put_canceled_tombstone(state, id) do
    timer =
      Process.send_after(self(), {:expire_canceled_request, id}, @canceled_request_tombstone_ttl)

    %{state | requests: RequestRegistry.put_canceled(state.requests, id, timer)}
  end

  @spec discard_or_log_unknown_response(State.t(), integer()) :: State.t()
  defp discard_or_log_unknown_response(state, id) do
    case RequestRegistry.pop_canceled(state.requests, id) do
      {nil, _requests} ->
        Log.warning(:lsp, "Received response for unknown request id=#{id}")
        state

      {timer, requests} ->
        Process.cancel_timer(timer)
        %{state | requests: requests}
    end
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
        },
        "formatting" => %{
          "dynamicRegistration" => false
        },
        "rangeFormatting" => %{
          "dynamicRegistration" => false
        }
      },
      "workspace" => %{
        "configuration" => true,
        "didChangeWatchedFiles" => %{
          "dynamicRegistration" => true
        },
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
