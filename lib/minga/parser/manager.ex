defmodule Minga.Parser.Manager do
  @moduledoc """
  GenServer that manages the tree-sitter parser Port process.

  Spawns the `minga-parser` binary as an Erlang Port with `{:packet, 4}`
  framing. Incoming highlight responses from the parser are decoded and
  forwarded to subscribers. Outgoing highlight commands are encoded and
  sent to the Port.

  This is the parsing counterpart to the frontend manager (which handles rendering). Separating parsing from rendering means every frontend gets syntax highlighting for free, and a parser crash does not kill the renderer.

  The manager is the single process owner for editor-buffer parser identity, parse sequencing, activity, eviction, and crash-resync metadata. `Minga.Parser.BufferRegistry` owns the pure value transitions within this process.

  ## Crash Recovery

  When the Zig parser process exits unexpectedly (non-zero status), the
  manager automatically restarts the Port with exponential backoff
  (100ms, 200ms, 400ms, ..., capped at 5s). After a successful restart,
  it replays `set_language` + `parse_buffer` for every tracked buffer so
  highlighting recovers without user intervention.

  After `@max_restart_attempts` consecutive failures within
  `@restart_window_ms`, the manager stops retrying and notifies
  subscribers that highlighting is disabled. The `:parser-restart`
  command can manually trigger recovery.

  Subscribers register via `subscribe/1` and receive messages as:

      {:minga_highlight, event}

  where `event` is one of the highlight response types from
  `Minga.Parser.Protocol`.
  """

  use GenServer

  alias Minga.Language.Grammar
  alias Minga.Language.Highlight.Span
  alias Minga.Language.Registry, as: LanguageRegistry
  alias Minga.Parser.BufferRegistry
  alias Minga.Parser.Protocol
  alias Minga.Parser.StructuralNavResult

  # ── Restart constants ──

  @initial_backoff_ms 100
  @max_backoff_ms 5_000
  @max_restart_attempts 5
  @restart_window_ms 30_000
  @snippet_buffer_id_start 4_000_000_000
  @default_highlight_timeout_ms 50
  @default_indent_request_timeout_ms 2_000
  @default_textobject_request_timeout_ms 2_000
  @default_match_item_request_timeout_ms 2_000
  @default_structural_nav_request_timeout_ms 2_000
  @request_client_timeout_slack_ms 50

  @typedoc "Options for starting the parser manager."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:parser_path, String.t()}

  @typedoc "Synchronous syntax highlight result for a small source snippet."
  @type highlight_source_result ::
          {:ok, [String.t()], [Span.t()]}
          | :unsupported
          | :timeout
          | :unavailable

  @typedoc "Tracked pending synchronous snippet highlight request."
  @type pending_highlight :: %{
          from: GenServer.from(),
          names: [String.t()] | nil,
          spans: [Span.t()] | nil,
          timer_ref: reference()
        }

  @typedoc "Structural navigation result returned by the parser."
  @type structural_nav_result :: StructuralNavResult.t()

  @type buffer_meta :: BufferRegistry.meta()

  @enforce_keys [:parser_path]
  defstruct port: nil,
            subscribers: %{},
            parser_path: "",
            ready: false,
            next_request_id: 1,
            pending_requests: %{},
            next_snippet_buffer_id: @snippet_buffer_id_start,
            pending_highlights: %{},
            restart_timestamps: [],
            current_backoff_ms: @initial_backoff_ms,
            gave_up: false,
            buffers: BufferRegistry.new()

  @type t :: %__MODULE__{
          port: port() | nil,
          subscribers: %{pid() => reference()},
          parser_path: String.t(),
          ready: boolean(),
          next_request_id: non_neg_integer(),
          pending_requests: %{non_neg_integer() => GenServer.from()},
          next_snippet_buffer_id: non_neg_integer(),
          pending_highlights: %{non_neg_integer() => pending_highlight()},
          restart_timestamps: [integer()],
          current_backoff_ms: non_neg_integer(),
          gave_up: boolean(),
          buffers: BufferRegistry.t()
        }

  # ── Client API ──

  @doc "Starts the parser manager."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Sends a list of encoded highlight command binaries to the parser."
  @spec send_commands(GenServer.server(), [binary()]) :: :ok
  def send_commands(server \\ __MODULE__, commands) when is_list(commands) do
    GenServer.cast(server, {:send_commands, commands})
  end

  @doc "Sends encoded commands only while the PID still owns the supplied parser buffer ID."
  @spec send_buffer_commands(pid(), pos_integer(), [binary()], GenServer.server()) :: :ok
  def send_buffer_commands(buffer_pid, buffer_id, commands, server \\ __MODULE__)
      when is_pid(buffer_pid) and is_integer(buffer_id) and buffer_id > 0 and is_list(commands) do
    GenServer.cast(server, {:send_buffer_commands, buffer_pid, buffer_id, commands})
  end

  @doc "Subscribes the calling process to receive highlight events."
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc """
  Loads a tree-sitter grammar from a shared library into the parser.

  Sends the `load_grammar` protocol message and returns immediately.
  The parser responds asynchronously with a `grammar_loaded` event
  that is broadcast to subscribers.
  """
  @spec load_grammar(String.t(), String.t(), GenServer.server()) :: :ok
  def load_grammar(name, lib_path, server \\ __MODULE__)
      when is_binary(name) and is_binary(lib_path) do
    commands = [Protocol.encode_load_grammar(name, lib_path)]
    send_commands(server, commands)
  end

  @doc """
  Requests a tree-sitter indent level synchronously.

  Sends a `request_indent` command to the Zig parser and blocks until the
  result arrives. Keystroke-path callers can pass a short timeout; callers fall back to copy-indent if the parser is slow or unavailable.

  Returns a non-negative indent level, or `nil` if the parser is unavailable.
  """
  @spec request_indent(non_neg_integer(), non_neg_integer()) :: integer() | nil
  @spec request_indent(non_neg_integer(), non_neg_integer(), GenServer.server()) ::
          integer() | nil
  @spec request_indent(non_neg_integer(), non_neg_integer(), GenServer.server(), pos_integer()) ::
          integer() | nil
  def request_indent(buffer_id, line), do: request_indent(buffer_id, line, __MODULE__)

  def request_indent(buffer_id, line, server) do
    request_indent(buffer_id, line, server, @default_indent_request_timeout_ms)
  end

  def request_indent(buffer_id, line, server, timeout_ms)
      when is_integer(buffer_id) and buffer_id > 0 and is_integer(line) and line >= 0 and
             is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(
      server,
      {:request_indent, buffer_id, line, timeout_ms},
      timeout_ms + @request_client_timeout_slack_ms
    )
  catch
    :exit, _ -> nil
  end

  def request_indent(_buffer_id, _line, _server, _timeout_ms), do: nil

  @doc """
  Requests a tree-sitter text object range synchronously.

  Sends a `request_textobject` command to the Zig parser and blocks until
  the result arrives or the request times out.

  Returns `{start_row, start_col, end_row, end_col}` or `nil` if no match.
  """
  @spec request_textobject(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          GenServer.server()
        ) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
  def request_textobject(buffer_id, row, col, capture_name, server \\ __MODULE__)
      when is_integer(buffer_id) and is_integer(row) and is_integer(col) and
             is_binary(capture_name) do
    GenServer.call(
      server,
      {:request_textobject, buffer_id, row, col, capture_name,
       @default_textobject_request_timeout_ms},
      @default_textobject_request_timeout_ms + @request_client_timeout_slack_ms
    )
  catch
    :exit, _ -> nil
  end

  @doc """
  Requests the structural match item at the given buffer position synchronously.

  Returns `{row, col}` for the matched delimiter/keyword/tag/quote, or `nil` if no tree-sitter match is available.
  """
  @spec request_match_item(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          GenServer.server()
        ) :: {non_neg_integer(), non_neg_integer()} | nil
  def request_match_item(buffer_id, row, col, server \\ __MODULE__)
      when is_integer(buffer_id) and is_integer(row) and is_integer(col) do
    GenServer.call(
      server,
      {:request_match_item, buffer_id, row, col, @default_match_item_request_timeout_ms},
      @default_match_item_request_timeout_ms + @request_client_timeout_slack_ms
    )
  catch
    :exit, _ -> nil
  end

  @doc """
  Requests structural AST navigation synchronously.

  Action values are `0` for parent, `1` for first child, `2` for next sibling, and `3` for previous sibling.

  Returns `%Minga.Parser.StructuralNavResult{}` for the target node, or `nil` if no target exists or the parser is unavailable.
  """
  @spec request_structural_nav(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          0..3,
          GenServer.server()
        ) :: structural_nav_result() | nil
  def request_structural_nav(buffer_id, row, col, action, server \\ __MODULE__)
      when is_integer(buffer_id) and is_integer(row) and is_integer(col) and
             is_integer(action) and action >= 0 and action <= 3 do
    GenServer.call(
      server,
      {:request_structural_nav, buffer_id, row, col, action,
       @default_structural_nav_request_timeout_ms},
      @default_structural_nav_request_timeout_ms + @request_client_timeout_slack_ms
    )
  catch
    :exit, _ -> nil
  end

  @doc """
  Sets the active tree-sitter language for a buffer.
  """
  @spec set_language(non_neg_integer(), String.t(), GenServer.server()) :: :ok
  def set_language(buffer_id, name, server \\ __MODULE__)
      when is_integer(buffer_id) and is_binary(name) do
    send_commands(server, [Protocol.encode_set_language(buffer_id, name)])
  end

  @doc """
  Sets a custom highlight query for a buffer.
  """
  @spec set_highlight_query(non_neg_integer(), String.t(), GenServer.server()) :: :ok
  def set_highlight_query(buffer_id, query, server \\ __MODULE__)
      when is_integer(buffer_id) and is_binary(query) do
    send_commands(server, [Protocol.encode_set_highlight_query(buffer_id, query)])
  end

  @doc """
  Sets a custom injection query for a buffer.
  """
  @spec set_injection_query(non_neg_integer(), String.t(), GenServer.server()) :: :ok
  def set_injection_query(buffer_id, query, server \\ __MODULE__)
      when is_integer(buffer_id) and is_binary(query) do
    send_commands(server, [Protocol.encode_set_injection_query(buffer_id, query)])
  end

  @doc """
  Closes a buffer in the parser, freeing its tree and source.
  """
  @spec close_buffer(non_neg_integer(), GenServer.server()) :: :ok
  def close_buffer(buffer_id, server \\ __MODULE__)
      when is_integer(buffer_id) do
    send_commands(server, [Protocol.encode_close_buffer(buffer_id)])
  end

  @typedoc "Options for `register_buffer/4`."
  @type register_opt ::
          {:setup_commands_fn, (non_neg_integer() -> [binary()])}
          | {:server, GenServer.server()}

  @doc """
  Registers an editor buffer and returns its stable parser buffer ID.

  Registration is idempotent for a buffer PID and refreshes the language and crash-recovery callbacks. `setup_commands_fn`, when present, must rebuild the complete parser setup for the supplied ID, including custom queries and a version-zero parse.
  """
  @spec register_buffer(pid(), String.t(), (-> String.t()), [register_opt()]) :: pos_integer()
  def register_buffer(buffer_pid, language, content_fn, opts \\ [])
      when is_pid(buffer_pid) and is_binary(language) and is_function(content_fn, 0) do
    server = Keyword.get(opts, :server, __MODULE__)
    setup_fn = Keyword.get(opts, :setup_commands_fn)

    GenServer.call(server, {:register_buffer, buffer_pid, language, content_fn, setup_fn})
  end

  @doc "Returns the parser buffer ID for an editor buffer, or `nil` when unregistered."
  @spec buffer_id(pid(), GenServer.server()) :: pos_integer() | nil
  def buffer_id(buffer_pid, server \\ __MODULE__) when is_pid(buffer_pid) do
    GenServer.call(server, {:buffer_id, buffer_pid})
  catch
    :exit, reason -> log_unavailable(:buffer_id, reason, nil)
  end

  @doc "Resolves a parser buffer ID to its live editor buffer PID."
  @spec resolve_buffer(non_neg_integer(), GenServer.server()) :: pid() | nil
  def resolve_buffer(buffer_id, server \\ __MODULE__) when is_integer(buffer_id) do
    GenServer.call(server, {:resolve_buffer, buffer_id})
  catch
    :exit, reason -> log_unavailable(:resolve_buffer, reason, nil)
  end

  @doc "Allocates the next outgoing parse version for a registered buffer and marks it active."
  @spec begin_parse(pid(), GenServer.server()) :: {:ok, pos_integer(), pos_integer()} | :error
  def begin_parse(buffer_pid, server \\ __MODULE__) when is_pid(buffer_pid) do
    GenServer.call(server, {:begin_parse, buffer_pid})
  catch
    :exit, reason -> log_unavailable(:begin_parse, reason, :error)
  end

  @doc "Refreshes the parser activity timestamp for a registered buffer."
  @spec touch_buffer(pid(), GenServer.server()) :: :ok
  def touch_buffer(buffer_pid, server \\ __MODULE__) when is_pid(buffer_pid) do
    GenServer.cast(server, {:touch_buffer, buffer_pid})
  end

  @doc """
  Unregisters an editor buffer and closes its parser tree when one exists.

  The operation is idempotent: metadata and activity are removed even when the buffer has no parser ID.
  """
  @spec unregister_buffer(pid(), GenServer.server()) :: :ok
  def unregister_buffer(buffer_pid, server \\ __MODULE__) when is_pid(buffer_pid) do
    GenServer.call(server, {:unregister_buffer, buffer_pid})
  catch
    :exit, reason -> log_unavailable(:unregister_buffer, reason, :ok)
  end

  @doc "Evicts stale parser trees except for explicitly protected buffers and returns an explicit availability result."
  @spec evict_inactive([pid()], non_neg_integer(), GenServer.server()) ::
          {:ok, [pid()]} | {:error, :unavailable}
  def evict_inactive(protected_pids, ttl_ms, server \\ __MODULE__)
      when is_list(protected_pids) and is_integer(ttl_ms) and ttl_ms >= 0 do
    {:ok, GenServer.call(server, {:evict_inactive, protected_pids, ttl_ms})}
  catch
    :exit, reason -> log_unavailable(:evict_inactive, reason, {:error, :unavailable})
  end

  @doc """
  Manually restarts the parser Port and re-syncs all tracked buffers.

  Resets the give-up state so retries are possible again. Returns `:ok`
  if the Port was successfully started, `{:error, reason}` otherwise.
  """
  @spec restart(GenServer.server()) :: :ok | {:error, :binary_not_found}
  def restart(server \\ __MODULE__) do
    GenServer.call(server, :restart)
  end

  @doc """
  Returns whether the parser is currently available (Port is open).
  """
  @spec available?(GenServer.server()) :: boolean()
  def available?(server \\ __MODULE__) do
    GenServer.call(server, :available?)
  catch
    :exit, _ -> false
  end

  @doc """
  Syntax-highlights a small source snippet synchronously.

  This is intended for UI snippets such as hover popup code blocks. It uses a fresh internal buffer ID, applies the language's highlight query, parses the source, and waits up to `:timeout` milliseconds for highlight names and spans. Unsupported languages, parser unavailability, and timeouts are explicit non-raising fallback results.
  """
  @spec highlight_source(String.t(), String.t(), keyword()) :: highlight_source_result()
  def highlight_source(language, source, opts \\ [])
      when is_binary(language) and is_binary(source) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    # Resolve short/alternate fence labels (e.g. "js", "c++", "py3") to the
    # canonical grammar name we ship before reading the query or parsing.
    grammar = LanguageRegistry.canonical_grammar(language)

    timeout =
      normalize_highlight_timeout(Keyword.get(opts, :timeout, @default_highlight_timeout_ms))

    GenServer.call(server, {:highlight_source, grammar, source, timeout}, timeout + 100)
  catch
    :exit, {:timeout, _call} ->
      :timeout

    :exit, {:noproc, _call} ->
      :unavailable

    :exit, reason ->
      Minga.Log.warning(:port, "Parser: snippet highlight request failed: #{inspect(reason)}")
      :unavailable
  end

  @spec normalize_highlight_timeout(term()) :: non_neg_integer()
  defp normalize_highlight_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: timeout
  defp normalize_highlight_timeout(_timeout), do: @default_highlight_timeout_ms

  # ── Server Callbacks ──

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    Minga.Telemetry.StartupTimer.mark(:parser_port_spawn)
    parser_path = Keyword.get(opts, :parser_path, default_parser_path())
    state = %__MODULE__{parser_path: parser_path}
    result = {:ok, start_port(state)}
    Minga.Telemetry.StartupTimer.mark(:parser_port_ready)
    result
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    subscribers = monitor_subscriber(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call(
        {:request_indent, _buffer_id, _line, _timeout_ms},
        _from,
        %{port: nil} = state
      ) do
    {:reply, nil, state}
  end

  def handle_call({:request_indent, buffer_id, line, timeout_ms}, from, state) do
    if BufferRegistry.registered_id?(state.buffers, buffer_id) do
      request_id = state.next_request_id
      cmd = Protocol.encode_request_indent(buffer_id, request_id, line)
      enqueue_pending_request(state, from, request_id, cmd, timeout_ms)
    else
      {:reply, nil, state}
    end
  end

  def handle_call(
        {:request_textobject, _buffer_id, _row, _col, _capture, _timeout_ms},
        _from,
        %{port: nil} = state
      ) do
    {:reply, nil, state}
  end

  def handle_call(
        {:request_textobject, buffer_id, row, col, capture_name, timeout_ms},
        from,
        state
      ) do
    request_id = state.next_request_id
    cmd = Protocol.encode_request_textobject(buffer_id, request_id, row, col, capture_name)
    enqueue_pending_request(state, from, request_id, cmd, timeout_ms)
  end

  def handle_call(
        {:request_match_item, _buffer_id, _row, _col, _timeout_ms},
        _from,
        %{port: nil} = state
      ) do
    {:reply, nil, state}
  end

  def handle_call({:request_match_item, buffer_id, row, col, timeout_ms}, from, state) do
    request_id = state.next_request_id
    cmd = Protocol.encode_request_match_item(buffer_id, request_id, row, col)
    enqueue_pending_request(state, from, request_id, cmd, timeout_ms)
  end

  def handle_call(
        {:request_structural_nav, _buffer_id, _row, _col, _action, _timeout_ms},
        _from,
        %{port: nil} = state
      ) do
    {:reply, nil, state}
  end

  def handle_call({:request_structural_nav, buffer_id, row, col, action, timeout_ms}, from, state) do
    request_id = state.next_request_id
    cmd = Protocol.encode_request_structural_nav(buffer_id, request_id, row, col, action)
    enqueue_pending_request(state, from, request_id, cmd, timeout_ms)
  end

  def handle_call({:highlight_source, _language, _source, _timeout}, _from, %{port: nil} = state) do
    {:reply, :unavailable, state}
  end

  def handle_call({:highlight_source, language, source, timeout}, from, state) do
    case Grammar.read_query(language) do
      {:ok, query} ->
        start_highlight_source_request(language, query, source, timeout, from, state)

      {:error, _reason} ->
        {:reply, :unsupported, state}
    end
  end

  def handle_call(:restart, _from, state) do
    state = %{
      state
      | gave_up: false,
        current_backoff_ms: @initial_backoff_ms,
        restart_timestamps: []
    }

    # Close existing port if still open
    state = close_port(state)

    state = start_port(state)

    if state.port != nil do
      Minga.Log.info(:port, "Parser: manual restart successful")
      state = resync_all_buffers(state)
      broadcast(state.subscribers, {:minga_highlight, :parser_restarted})
      {:reply, :ok, state}
    else
      {:reply, {:error, :binary_not_found}, state}
    end
  end

  def handle_call(:available?, _from, state) do
    {:reply, state.port != nil and state.ready, state}
  end

  def handle_call({:register_buffer, buffer_pid, language, content_fn, setup_fn}, _from, state) do
    {buffer_id, state} = register_editor_buffer(state, buffer_pid, language, content_fn, setup_fn)
    {:reply, buffer_id, state}
  end

  def handle_call({:buffer_id, buffer_pid}, _from, state) do
    {:reply, BufferRegistry.buffer_id(state.buffers, buffer_pid), state}
  end

  def handle_call({:resolve_buffer, buffer_id}, _from, state) do
    {:reply, BufferRegistry.resolve(state.buffers, buffer_id), state}
  end

  def handle_call({:begin_parse, buffer_pid}, _from, state) do
    case BufferRegistry.begin_parse(state.buffers, buffer_pid, monotonic_ms()) do
      {:ok, buffer_id, version, buffers} ->
        {:reply, {:ok, buffer_id, version}, %{state | buffers: buffers}}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:unregister_buffer, buffer_pid}, _from, state) do
    {:reply, :ok, unregister_editor_buffer(state, buffer_pid)}
  end

  def handle_call({:evict_inactive, protected_pids, ttl_ms}, _from, state) do
    {evicted_pids, state} = evict_stale_buffers(state, protected_pids, ttl_ms)
    {:reply, evicted_pids, state}
  end

  @impl true
  def handle_cast({:send_commands, _commands}, %{port: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:send_commands, commands}, state) do
    send_command_batch(state.port, commands)
    {:noreply, state}
  end

  def handle_cast(
        {:send_buffer_commands, _buffer_pid, _buffer_id, _commands},
        %{port: nil} = state
      ) do
    {:noreply, state}
  end

  def handle_cast({:send_buffer_commands, buffer_pid, buffer_id, commands}, state) do
    if BufferRegistry.buffer_id(state.buffers, buffer_pid) == buffer_id do
      send_command_batch(state.port, commands)
    end

    {:noreply, state}
  end

  def handle_cast({:touch_buffer, buffer_pid}, state) do
    buffers = BufferRegistry.touch(state.buffers, buffer_pid, monotonic_ms())
    {:noreply, %{state | buffers: buffers}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Protocol.decode_event(data) do
      {:ok, {:indent_result, request_id, _line, indent_level}} ->
        reply_to_pending_request(state, request_id, indent_level)

      {:ok, {:textobject_result, request_id, result}} ->
        reply_to_pending_request(state, request_id, result)

      {:ok, {:match_item_result, request_id, result}} ->
        reply_to_pending_request(state, request_id, result)

      {:ok, {:node_info, request_id, result}} ->
        reply_to_pending_request(state, request_id, result)

      {:ok, {:highlight_names, _buffer_id, _names} = event} ->
        handle_highlight_source_event_or_broadcast(event, state)

      {:ok, {:highlight_spans, _buffer_id, _version, _spans} = event} ->
        handle_highlight_source_event_or_broadcast(event, state)

      {:ok, {:log_message, _level, _text} = event} ->
        broadcast(state.subscribers, {:minga_highlight, event})
        {:noreply, state}

      {:ok, event} ->
        broadcast_or_drop_snippet_event(event, state)

      :unknown ->
        Minga.Log.warning(:port, "Parser: received unknown opcode")
        {:noreply, state}

      {:error, reason} ->
        Minga.Log.warning(:port, "Parser: failed to decode event: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    Minga.Log.info(:port, "Parser process exited normally")
    # Fail any pending synchronous requests so callers don't hang.
    state = fail_pending_requests(state)
    {:noreply, %{state | port: nil, ready: false}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Minga.Log.error(:port, "Parser process crashed (exit status #{status})")
    # Fail any pending synchronous requests so callers don't hang.
    state = fail_pending_requests(state)
    state = %{state | port: nil, ready: false}
    broadcast(state.subscribers, {:minga_highlight, :parser_crashed})
    state = schedule_restart(state)
    {:noreply, state}
  end

  def handle_info(:restart_parser, state) do
    state = attempt_restart(state)
    {:noreply, state}
  end

  def handle_info({:highlight_source_timeout, buffer_id}, state) do
    case Map.pop(state.pending_highlights, buffer_id) do
      {nil, _pending_highlights} ->
        {:noreply, state}

      {pending, pending_highlights} ->
        GenServer.reply(pending.from, :timeout)
        state = %{state | pending_highlights: pending_highlights}
        {:noreply, close_highlight_source_buffer(state, buffer_id)}
    end
  end

  def handle_info({:request_timeout, request_id}, state) do
    reply_to_pending_request(state, request_id, nil)
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state = handle_buffer_down(state, pid, ref)
    subscribers = remove_down_subscriber(state.subscribers, pid, ref)
    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private: synchronous snippet highlighting ──

  @spec start_highlight_source_request(
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          GenServer.from(),
          t()
        ) :: {:noreply, t()}
  defp start_highlight_source_request(language, query, source, timeout, from, state) do
    buffer_id = state.next_snippet_buffer_id
    timer_ref = Process.send_after(self(), {:highlight_source_timeout, buffer_id}, timeout)

    pending_highlight = %{from: from, names: nil, spans: nil, timer_ref: timer_ref}
    pending_highlights = Map.put(state.pending_highlights, buffer_id, pending_highlight)

    commands = [
      Protocol.encode_set_language(buffer_id, language),
      Protocol.encode_set_highlight_query(buffer_id, query),
      Protocol.encode_parse_buffer(buffer_id, 1, source)
    ]

    Port.command(state.port, IO.iodata_to_binary(commands))

    {:noreply,
     %{
       state
       | next_snippet_buffer_id: buffer_id + 1,
         pending_highlights: pending_highlights
     }}
  end

  @spec handle_highlight_source_event_or_broadcast(term(), t()) :: {:noreply, t()}
  defp handle_highlight_source_event_or_broadcast(event, state) do
    case handle_highlight_source_event(event, state) do
      {:handled, state} ->
        {:noreply, state}

      {:miss, state} ->
        broadcast_or_drop_snippet_event(event, state)
    end
  end

  @typep highlight_source_event ::
           {:highlight_names, non_neg_integer(), [String.t()]}
           | {:highlight_spans, non_neg_integer(), non_neg_integer(), [Span.t()]}

  @spec handle_highlight_source_event(highlight_source_event(), t()) ::
          {:handled | :miss, t()}
  defp handle_highlight_source_event({:highlight_names, buffer_id, names}, state) do
    update_highlight_source_pending(buffer_id, :names, names, state)
  end

  defp handle_highlight_source_event({:highlight_spans, buffer_id, _version, spans}, state) do
    update_highlight_source_pending(buffer_id, :spans, spans, state)
  end

  @spec broadcast_or_drop_snippet_event(term(), t()) :: {:noreply, t()}
  defp broadcast_or_drop_snippet_event(event, state) do
    if snippet_buffer_event?(event) do
      Minga.Log.debug(
        :port,
        "Parser: dropping late snippet event #{inspect(event_name(event))}"
      )

      {:noreply, state}
    else
      broadcast(state.subscribers, {:minga_highlight, event})
      {:noreply, state}
    end
  end

  @spec snippet_buffer_event?(term()) :: boolean()
  defp snippet_buffer_event?(event) do
    event
    |> event_buffer_id()
    |> snippet_buffer_id?()
  end

  @spec event_buffer_id(term()) :: non_neg_integer() | nil
  defp event_buffer_id({:highlight_names, buffer_id, _names}), do: buffer_id
  defp event_buffer_id({:highlight_spans, buffer_id, _version, _spans}), do: buffer_id
  defp event_buffer_id({:injection_ranges, buffer_id, _ranges}), do: buffer_id
  defp event_buffer_id({:fold_ranges, buffer_id, _version, _ranges}), do: buffer_id
  defp event_buffer_id({:textobject_positions, buffer_id, _version, _positions}), do: buffer_id
  defp event_buffer_id({:document_symbols, buffer_id, _version, _symbols}), do: buffer_id
  defp event_buffer_id({:conceal_spans, buffer_id, _version, _spans}), do: buffer_id
  defp event_buffer_id({:request_reparse, buffer_id}), do: buffer_id
  defp event_buffer_id(_event), do: nil

  @spec snippet_buffer_id?(non_neg_integer() | nil) :: boolean()
  defp snippet_buffer_id?(buffer_id) when is_integer(buffer_id) do
    buffer_id >= @snippet_buffer_id_start
  end

  defp snippet_buffer_id?(_buffer_id), do: false

  @spec event_name(tuple()) :: atom()
  defp event_name(event), do: elem(event, 0)

  @spec update_highlight_source_pending(non_neg_integer(), :names | :spans, [term()], t()) ::
          {:handled | :miss, t()}
  defp update_highlight_source_pending(buffer_id, field, value, state) do
    case Map.fetch(state.pending_highlights, buffer_id) do
      :error ->
        {:miss, state}

      {:ok, pending_highlight} ->
        pending_highlight = Map.put(pending_highlight, field, value)
        maybe_complete_highlight_source(buffer_id, pending_highlight, state)
    end
  end

  @spec maybe_complete_highlight_source(non_neg_integer(), pending_highlight(), t()) ::
          {:handled, t()}
  defp maybe_complete_highlight_source(buffer_id, %{names: names, spans: spans} = pending, state)
       when is_list(names) and is_list(spans) do
    Process.cancel_timer(pending.timer_ref)
    GenServer.reply(pending.from, {:ok, names, spans})

    pending_highlights = Map.delete(state.pending_highlights, buffer_id)
    state = %{state | pending_highlights: pending_highlights}
    {:handled, close_highlight_source_buffer(state, buffer_id)}
  end

  defp maybe_complete_highlight_source(buffer_id, pending_highlight, state) do
    pending_highlights = Map.put(state.pending_highlights, buffer_id, pending_highlight)
    {:handled, %{state | pending_highlights: pending_highlights}}
  end

  @spec close_highlight_source_buffer(t(), non_neg_integer()) :: t()
  defp close_highlight_source_buffer(%{port: nil} = state, _buffer_id), do: state

  defp close_highlight_source_buffer(state, buffer_id) do
    Port.command(state.port, Protocol.encode_close_buffer(buffer_id))
    state
  end

  # ── Private: Port lifecycle ──

  @spec start_port(t()) :: t()
  defp start_port(state) do
    if File.exists?(state.parser_path) do
      port =
        Port.open(
          {:spawn_executable, state.parser_path},
          [:binary, :exit_status, {:packet, 4}, :use_stdio]
        )

      %{state | port: port, ready: true}
    else
      Minga.Log.warning(:port, "Parser binary not found at #{state.parser_path}")
      state
    end
  end

  @spec close_port(t()) :: t()
  defp close_port(%{port: nil} = state), do: state

  defp close_port(%{port: port} = state) do
    try do
      Port.close(port)
    catch
      :error, :badarg -> :ok
    end

    %{state | port: nil, ready: false}
  end

  # ── Private: Crash recovery ──

  @spec schedule_restart(t()) :: t()
  defp schedule_restart(%{gave_up: true} = state), do: state

  defp schedule_restart(state) do
    now = System.monotonic_time(:millisecond)

    # Prune timestamps outside the restart window
    recent = Enum.filter(state.restart_timestamps, fn ts -> now - ts < @restart_window_ms end)
    recent = [now | recent]

    if Enum.count(recent) >= @max_restart_attempts do
      Minga.Log.error(
        :port,
        "Parser crashed repeatedly (#{@max_restart_attempts} times in #{div(@restart_window_ms, 1000)}s), syntax highlighting disabled. Use :parser-restart to retry."
      )

      Minga.Events.broadcast(:log_message, %Minga.Events.LogMessageEvent{
        text:
          "Parser crashed repeatedly, syntax highlighting disabled. Use :parser-restart to retry.",
        level: :warning
      })

      broadcast(state.subscribers, {:minga_highlight, :parser_gave_up})
      %{state | gave_up: true, restart_timestamps: recent}
    else
      backoff = state.current_backoff_ms

      Minga.Log.info(
        :port,
        "Parser: scheduling restart in #{backoff}ms (attempt #{Enum.count(recent)}/#{@max_restart_attempts})"
      )

      Process.send_after(self(), :restart_parser, backoff)

      next_backoff = min(backoff * 2, @max_backoff_ms)

      %{
        state
        | restart_timestamps: recent,
          current_backoff_ms: next_backoff
      }
    end
  end

  @spec attempt_restart(t()) :: t()
  defp attempt_restart(%{gave_up: true} = state), do: state
  defp attempt_restart(%{port: port} = state) when port != nil, do: state

  defp attempt_restart(state) do
    state = start_port(state)

    if state.port != nil do
      Minga.Log.info(:port, "Parser: restarted successfully")
      state = resync_all_buffers(state)
      broadcast(state.subscribers, {:minga_highlight, :parser_restarted})
      # Reset backoff on success
      %{state | current_backoff_ms: @initial_backoff_ms}
    else
      # Binary missing; schedule another attempt
      schedule_restart(state)
    end
  end

  @spec register_editor_buffer(t(), pid(), String.t(), (-> String.t()), function() | nil) ::
          {pos_integer(), t()}
  defp register_editor_buffer(state, buffer_pid, language, content_fn, setup_fn) do
    {buffer_id, status, buffers} =
      BufferRegistry.register(
        state.buffers,
        buffer_pid,
        language,
        content_fn,
        setup_fn,
        monotonic_ms()
      )

    buffers =
      case status do
        :new -> BufferRegistry.put_monitor(buffers, buffer_pid, Process.monitor(buffer_pid))
        :existing -> buffers
      end

    {buffer_id, %{state | buffers: buffers}}
  end

  @spec unregister_editor_buffer(t(), pid(), boolean()) :: t()
  defp unregister_editor_buffer(state, buffer_pid, demonitor? \\ true) do
    {buffer_id, monitor_ref, buffers} = BufferRegistry.unregister(state.buffers, buffer_pid)
    maybe_demonitor(monitor_ref, demonitor?)
    maybe_close_editor_buffer(state.port, buffer_id)
    %{state | buffers: buffers}
  end

  @spec handle_buffer_down(t(), pid(), reference()) :: t()
  defp handle_buffer_down(state, buffer_pid, monitor_ref) do
    if BufferRegistry.monitored?(state.buffers, buffer_pid, monitor_ref) do
      unregister_editor_buffer(state, buffer_pid, false)
    else
      state
    end
  end

  @spec maybe_demonitor(reference() | nil, boolean()) :: :ok
  defp maybe_demonitor(nil, _demonitor?), do: :ok
  defp maybe_demonitor(_monitor_ref, false), do: :ok

  defp maybe_demonitor(monitor_ref, true) do
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  @spec send_command_batch(port(), [binary()]) :: true
  defp send_command_batch(port, commands) do
    commands
    |> IO.iodata_to_binary()
    |> then(&Port.command(port, &1))
  end

  @spec maybe_close_editor_buffer(port() | nil, pos_integer() | nil) :: :ok
  defp maybe_close_editor_buffer(_port, nil), do: :ok
  defp maybe_close_editor_buffer(nil, _buffer_id), do: :ok

  defp maybe_close_editor_buffer(port, buffer_id) do
    Port.command(port, Protocol.encode_close_buffer(buffer_id))
    :ok
  end

  @spec evict_stale_buffers(t(), [pid()], non_neg_integer()) :: {[pid()], t()}
  defp evict_stale_buffers(state, protected_pids, ttl_ms) do
    {evicted, buffers} =
      BufferRegistry.evict_inactive(state.buffers, protected_pids, ttl_ms, monotonic_ms())

    Enum.each(evicted, fn {_buffer_pid, buffer_id, monitor_ref} ->
      maybe_demonitor(monitor_ref, true)
      maybe_close_editor_buffer(state.port, buffer_id)
    end)

    {Enum.map(evicted, &elem(&1, 0)), %{state | buffers: buffers}}
  end

  @spec monotonic_ms() :: integer()
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  @spec resync_all_buffers(t()) :: t()
  defp resync_all_buffers(state) do
    buffer_count = BufferRegistry.count(state.buffers)

    if buffer_count > 0 do
      Minga.Log.info(:port, "Parser: re-syncing #{buffer_count} buffer(s)")
    end

    {commands, stale_pids} = resync_commands(state.buffers)
    state = Enum.reduce(stale_pids, state, &unregister_editor_buffer(&2, &1))

    if commands != [] do
      batch = IO.iodata_to_binary(commands)
      Port.command(state.port, batch)
    end

    %{state | buffers: BufferRegistry.reset_parse_version(state.buffers)}
  end

  @spec resync_commands(BufferRegistry.t()) :: {[binary()], [pid()]}
  defp resync_commands(buffers) do
    buffers
    |> BufferRegistry.entries()
    |> Enum.reduce({[], []}, fn {buffer_pid, meta}, {commands, stale_pids} ->
      case resync_buffer_commands(meta.id, meta) do
        {:ok, buffer_commands} -> {[buffer_commands | commands], stale_pids}
        :stale -> {commands, [buffer_pid | stale_pids]}
      end
    end)
    |> then(fn {commands, stale_pids} ->
      {commands |> Enum.reverse() |> List.flatten(), stale_pids}
    end)
  end

  # Uses the full setup_commands_fn if available (replays custom queries),
  # otherwise falls back to set_language + parse_buffer.
  @spec resync_buffer_commands(non_neg_integer(), buffer_meta()) :: {:ok, [binary()]} | :stale
  defp resync_buffer_commands(buffer_id, meta) do
    if is_function(meta.setup_commands_fn, 1) do
      case invoke_callback(meta.setup_commands_fn, [buffer_id]) do
        {:ok, commands} ->
          {:ok, commands}

        {:error, reason} ->
          Minga.Log.warning(
            :port,
            "Parser: setup callback failed for buffer #{buffer_id}: #{inspect(reason)}; falling back"
          )

          resync_buffer_fallback(buffer_id, meta)
      end
    else
      resync_buffer_fallback(buffer_id, meta)
    end
  end

  @spec resync_buffer_fallback(non_neg_integer(), buffer_meta()) :: {:ok, [binary()]} | :stale
  defp resync_buffer_fallback(buffer_id, meta) do
    case invoke_callback(meta.content_fn, []) do
      {:ok, text} when is_binary(text) ->
        {:ok,
         [
           Protocol.encode_set_language(buffer_id, meta.language),
           Protocol.encode_parse_buffer(buffer_id, 0, text)
         ]}

      {:ok, other} ->
        Minga.Log.warning(
          :port,
          "Parser: content callback returned #{inspect(other)} for buffer #{buffer_id}; unregistering"
        )

        :stale

      {:error, reason} ->
        Minga.Log.warning(
          :port,
          "Parser: content callback failed for buffer #{buffer_id}: #{inspect(reason)}; unregistering"
        )

        :stale
    end
  end

  @spec invoke_callback(function(), [term()]) :: {:ok, term()} | {:error, term()}
  defp invoke_callback(callback, args) do
    {:ok, apply(callback, args)}
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec enqueue_pending_request(
          t(),
          GenServer.from(),
          non_neg_integer(),
          binary(),
          pos_integer()
        ) :: {:noreply, t()}
  defp enqueue_pending_request(state, from, request_id, cmd, timeout_ms) do
    Port.command(state.port, cmd)
    pending = Map.put(state.pending_requests, request_id, from)
    Process.send_after(self(), {:request_timeout, request_id}, timeout_ms)
    {:noreply, %{state | next_request_id: request_id + 1, pending_requests: pending}}
  end

  @spec fail_pending_requests(t()) :: t()
  defp fail_pending_requests(%{pending_requests: pending, pending_highlights: highlights} = state)
       when pending == %{} and highlights == %{} do
    state
  end

  defp fail_pending_requests(state) do
    Enum.each(state.pending_requests, fn {_id, from} ->
      GenServer.reply(from, nil)
    end)

    Enum.each(state.pending_highlights, fn {_buffer_id, pending} ->
      Process.cancel_timer(pending.timer_ref)
      GenServer.reply(pending.from, :unavailable)
    end)

    %{state | pending_requests: %{}, pending_highlights: %{}}
  end

  @spec reply_to_pending_request(t(), non_neg_integer(), term()) :: {:noreply, t()}
  defp reply_to_pending_request(state, request_id, result) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, _pending} ->
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, result)
        {:noreply, %{state | pending_requests: pending}}
    end
  end

  @spec monitor_subscriber(%{pid() => reference()}, pid()) :: %{pid() => reference()}
  defp monitor_subscriber(subscribers, pid) do
    case Map.fetch(subscribers, pid) do
      {:ok, _ref} -> subscribers
      :error -> Map.put(subscribers, pid, Process.monitor(pid))
    end
  end

  @spec remove_down_subscriber(%{pid() => reference()}, pid(), reference()) :: %{
          pid() => reference()
        }
  defp remove_down_subscriber(subscribers, pid, ref) do
    case Map.get(subscribers, pid) do
      ^ref -> Map.delete(subscribers, pid)
      _other -> subscribers
    end
  end

  @spec broadcast(%{pid() => reference()}, term()) :: :ok
  defp broadcast(subscribers, message) do
    subscribers
    |> Map.keys()
    |> Enum.each(&send(&1, message))
  end

  @spec log_unavailable(atom(), term(), term()) :: term()
  defp log_unavailable(operation, reason, fallback) do
    Minga.Log.warning(:port, "Parser manager #{operation} unavailable: #{inspect(reason)}")
    fallback
  end

  @spec default_parser_path() :: String.t()
  defp default_parser_path do
    # In a release (or Burrito binary), the parser lives in priv/
    priv_path = Application.app_dir(:minga, "priv/minga-parser")

    if File.exists?(priv_path) do
      priv_path
    else
      # Dev/test fallback: compiled Zig binary in the source tree
      Path.join([File.cwd!(), "zig", "zig-out", "bin", "minga-parser"])
    end
  end
end
