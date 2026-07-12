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

  alias Minga.Buffer
  alias Minga.Buffer.SyncSnapshot
  alias Minga.Events
  alias Minga.Language.Grammar
  alias Minga.Language.Highlight.Span
  alias Minga.Language.Registry, as: LanguageRegistry
  alias Minga.Parser.BufferConfig
  alias Minga.Parser.BufferRegistration
  alias Minga.Parser.BufferRegistry
  alias Minga.Parser.ParseScheduler
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
  @parse_admission_timeout_ms 10_000

  @typedoc "Options for starting the parser manager."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:parser_path, String.t()}
          | {:events_registry, Events.registry()}

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
            events_registry: Events.default_registry(),
            buffers: BufferRegistry.new(),
            parse_scheduler: ParseScheduler.new()

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
          events_registry: Events.registry(),
          buffers: BufferRegistry.t(),
          parse_scheduler: ParseScheduler.t()
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

  @doc "Forces a callback-free full parse request for a registered buffer."
  @spec request_parse(pid(), GenServer.server()) :: :ok
  def request_parse(buffer_pid, server \\ __MODULE__) when is_pid(buffer_pid) do
    GenServer.cast(server, {:request_parse, buffer_pid})
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
  @spec request_indent(pid(), non_neg_integer()) :: integer() | nil
  @spec request_indent(pid(), non_neg_integer(), GenServer.server()) :: integer() | nil
  @spec request_indent(pid(), non_neg_integer(), GenServer.server(), pos_integer()) ::
          integer() | nil
  def request_indent(buffer_pid, line), do: request_indent(buffer_pid, line, __MODULE__)

  def request_indent(buffer_pid, line, server) do
    request_indent(buffer_pid, line, server, @default_indent_request_timeout_ms)
  end

  def request_indent(buffer_pid, line, server, timeout_ms)
      when is_pid(buffer_pid) and is_integer(line) and line >= 0 and is_integer(timeout_ms) and
             timeout_ms > 0 do
    GenServer.call(
      server,
      {:request_indent, buffer_pid, line, timeout_ms},
      timeout_ms + @request_client_timeout_slack_ms
    )
  catch
    :exit, _ -> nil
  end

  def request_indent(_buffer_pid, _line, _server, _timeout_ms), do: nil

  @doc """
  Requests a tree-sitter text object range synchronously.

  Sends a `request_textobject` command to the Zig parser and blocks until
  the result arrives or the request times out.

  Returns `{start_row, start_col, end_row, end_col}` or `nil` if no match.
  """
  @spec request_textobject(
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          GenServer.server()
        ) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil
  def request_textobject(buffer_pid, row, col, capture_name, server \\ __MODULE__)
      when is_pid(buffer_pid) and is_integer(row) and is_integer(col) and is_binary(capture_name) do
    GenServer.call(
      server,
      {:request_textobject, buffer_pid, row, col, capture_name,
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
  @spec request_match_item(pid(), non_neg_integer(), non_neg_integer(), GenServer.server()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def request_match_item(buffer_pid, row, col, server \\ __MODULE__)
      when is_pid(buffer_pid) and is_integer(row) and is_integer(col) do
    GenServer.call(
      server,
      {:request_match_item, buffer_pid, row, col, @default_match_item_request_timeout_ms},
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
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          0..3,
          GenServer.server()
        ) :: structural_nav_result() | nil
  def request_structural_nav(buffer_pid, row, col, action, server \\ __MODULE__)
      when is_pid(buffer_pid) and is_integer(row) and is_integer(col) and is_integer(action) and
             action >= 0 and action <= 3 do
    GenServer.call(
      server,
      {:request_structural_nav, buffer_pid, row, col, action,
       @default_structural_nav_request_timeout_ms},
      @default_structural_nav_request_timeout_ms + @request_client_timeout_slack_ms
    )
  catch
    :exit, _ -> nil
  end

  @doc "Configures the parser's default dynamic-grammar language and queries."
  @spec configure_dynamic_grammar(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          GenServer.server()
        ) :: :ok
  def configure_dynamic_grammar(
        language,
        highlight_query,
        injection_query,
        server \\ __MODULE__
      )
      when is_binary(language) do
    commands =
      [Protocol.encode_set_language(0, language)]
      |> append_query(highlight_query, &Protocol.encode_set_highlight_query(0, &1))
      |> append_query(injection_query, &Protocol.encode_set_injection_query(0, &1))

    send_commands(server, commands)
  end

  @typedoc "Options for `register_buffer/3`."
  @type register_opt :: {:server, GenServer.server()}

  @doc "Registers or refreshes a buffer using inert parser configuration."
  @spec register_buffer(pid(), BufferConfig.t(), [register_opt()]) :: pos_integer()
  def register_buffer(buffer_pid, %BufferConfig{} = config, opts \\ []) when is_pid(buffer_pid) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:register_buffer, buffer_pid, config})
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
    events_registry = Keyword.get(opts, :events_registry, Events.default_registry())
    :ok = Events.subscribe(:buffer_changed, events_registry)
    state = %__MODULE__{parser_path: parser_path, events_registry: events_registry}
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

  def handle_call({:request_indent, buffer_pid, line, timeout_ms}, from, state) do
    enqueue_buffer_request(state, buffer_pid, from, timeout_ms, fn buffer_id, request_id ->
      Protocol.encode_request_indent(buffer_id, request_id, line)
    end)
  end

  def handle_call(
        {:request_textobject, _buffer_id, _row, _col, _capture, _timeout_ms},
        _from,
        %{port: nil} = state
      ) do
    {:reply, nil, state}
  end

  def handle_call(
        {:request_textobject, buffer_pid, row, col, capture_name, timeout_ms},
        from,
        state
      ) do
    enqueue_buffer_request(state, buffer_pid, from, timeout_ms, fn buffer_id, request_id ->
      Protocol.encode_request_textobject(buffer_id, request_id, row, col, capture_name)
    end)
  end

  def handle_call(
        {:request_match_item, _buffer_id, _row, _col, _timeout_ms},
        _from,
        %{port: nil} = state
      ) do
    {:reply, nil, state}
  end

  def handle_call({:request_match_item, buffer_pid, row, col, timeout_ms}, from, state) do
    enqueue_buffer_request(state, buffer_pid, from, timeout_ms, fn buffer_id, request_id ->
      Protocol.encode_request_match_item(buffer_id, request_id, row, col)
    end)
  end

  def handle_call(
        {:request_structural_nav, _buffer_id, _row, _col, _action, _timeout_ms},
        _from,
        %{port: nil} = state
      ) do
    {:reply, nil, state}
  end

  def handle_call(
        {:request_structural_nav, buffer_pid, row, col, action, timeout_ms},
        from,
        state
      ) do
    enqueue_buffer_request(state, buffer_pid, from, timeout_ms, fn buffer_id, request_id ->
      Protocol.encode_request_structural_nav(buffer_id, request_id, row, col, action)
    end)
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
      state = restart_parse_pumps(state)
      broadcast(state.subscribers, {:minga_highlight, :parser_restarted})
      {:reply, :ok, state}
    else
      {:reply, {:error, :binary_not_found}, state}
    end
  end

  def handle_call(:available?, _from, state) do
    {:reply, state.port != nil and state.ready, state}
  end

  def handle_call({:register_buffer, buffer_pid, config}, _from, state) do
    {buffer_id, state} = register_editor_buffer(state, buffer_pid, config)
    {:reply, buffer_id, pump_buffer(state, buffer_pid)}
  end

  def handle_call({:buffer_id, buffer_pid}, _from, state) do
    {:reply, BufferRegistry.buffer_id(state.buffers, buffer_pid), state}
  end

  def handle_call({:resolve_buffer, buffer_id}, _from, state) do
    {:reply, BufferRegistry.resolve(state.buffers, buffer_id), state}
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
    if send_command_batch(state.port, commands) do
      {:noreply, state}
    else
      Minga.Log.warning(:port, "Parser: command write failed; scheduling restart")
      state = state |> fail_pending_requests() |> reset_parse_admission() |> close_port()
      {:noreply, schedule_restart(state)}
    end
  end

  def handle_cast({:request_parse, buffer_pid}, state) do
    {:noreply, force_parse(state, buffer_pid)}
  end

  def handle_cast({:touch_buffer, buffer_pid}, state) do
    buffers = BufferRegistry.touch(state.buffers, buffer_pid, monotonic_ms())
    {:noreply, %{state | buffers: buffers}}
  end

  @impl true
  def handle_info(
        {:minga_event, :buffer_changed,
         %Events.BufferChangedEvent{buffer: buffer_pid, sequence: sequence}},
        state
      ) do
    {:noreply, mark_buffer_dirty(state, buffer_pid, sequence)}
  end

  def handle_info({:buffer_sync_snapshot, %SyncSnapshot{} = snapshot}, state) do
    {:noreply, handle_sync_snapshot(state, snapshot)}
  end

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

      {:ok, {:request_reparse, buffer_id}} ->
        {:noreply, recover_parser_buffer(state, buffer_id)}

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
    Minga.Log.warning(:port, "Parser process exited unexpectedly")
    state = state |> fail_pending_requests() |> reset_parse_admission() |> close_port()
    {:noreply, schedule_restart(state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Minga.Log.error(:port, "Parser process crashed (exit status #{status})")
    # Fail any pending synchronous requests so callers don't hang.
    state = state |> fail_pending_requests() |> reset_parse_admission() |> close_port()
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

  def handle_info({:parse_admission_timeout, buffer_pid, token}, state) do
    if ParseScheduler.timeout?(state.parse_scheduler, buffer_pid, token) do
      Minga.Log.error(
        :port,
        "Parser: synchronization timed out for buffer #{inspect(buffer_pid)}; restarting"
      )

      broadcast(state.subscribers, {:minga_highlight, :parser_crashed})

      state =
        state
        |> fail_pending_requests()
        |> reset_parse_admission()
        |> close_port()
        |> schedule_restart()

      {:noreply, state}
    else
      {:noreply, state}
    end
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
      broadcast_editor_event(event, state)
    end
  end

  @spec broadcast_editor_event(term(), t()) :: {:noreply, t()}
  defp broadcast_editor_event({:highlight_spans, buffer_id, version, _spans} = event, state) do
    case BufferRegistry.resolve(state.buffers, buffer_id) do
      nil ->
        {:noreply, state}

      buffer_pid ->
        complete_editor_parse(state, buffer_pid, version, event)
    end
  end

  defp broadcast_editor_event(event, state) do
    case editor_event_identity(event) do
      {:versioned, buffer_id, version} ->
        broadcast_versioned_editor_event(state, buffer_id, version, event)

      {:unversioned, buffer_id} ->
        broadcast_registered_editor_event(state, buffer_id, event)

      :global ->
        broadcast(state.subscribers, {:minga_highlight, event})
        {:noreply, state}
    end
  end

  @spec editor_event_identity(term()) ::
          {:versioned, non_neg_integer(), pos_integer()}
          | {:unversioned, non_neg_integer()}
          | :global
  defp editor_event_identity({:conceal_spans, buffer_id, version, _spans}),
    do: {:versioned, buffer_id, version}

  defp editor_event_identity({:fold_ranges, buffer_id, version, _ranges}),
    do: {:versioned, buffer_id, version}

  defp editor_event_identity({:textobject_positions, buffer_id, version, _positions}),
    do: {:versioned, buffer_id, version}

  defp editor_event_identity({:document_symbols, buffer_id, version, _symbols}),
    do: {:versioned, buffer_id, version}

  defp editor_event_identity({:highlight_names, buffer_id, _names}),
    do: {:unversioned, buffer_id}

  defp editor_event_identity({:injection_ranges, buffer_id, _ranges}),
    do: {:unversioned, buffer_id}

  defp editor_event_identity(_event), do: :global

  @spec broadcast_versioned_editor_event(t(), non_neg_integer(), pos_integer(), term()) ::
          {:noreply, t()}
  defp broadcast_versioned_editor_event(state, buffer_id, version, event) do
    with buffer_pid when is_pid(buffer_pid) <- BufferRegistry.resolve(state.buffers, buffer_id),
         {:ok, registration} <- BufferRegistry.fetch(state.buffers, buffer_pid),
         true <- BufferRegistration.accepts_version?(registration, version) do
      editor_event = tag_editor_buffer(event, buffer_pid)
      broadcast(state.subscribers, {:minga_highlight, editor_event})
    end

    {:noreply, state}
  end

  @spec broadcast_registered_editor_event(t(), non_neg_integer(), term()) :: {:noreply, t()}
  defp broadcast_registered_editor_event(state, buffer_id, event) do
    case BufferRegistry.resolve(state.buffers, buffer_id) do
      buffer_pid when is_pid(buffer_pid) ->
        editor_event = tag_editor_buffer(event, buffer_pid)
        broadcast(state.subscribers, {:minga_highlight, editor_event})

      nil ->
        :ok
    end

    {:noreply, state}
  end

  @spec tag_editor_buffer(term(), pid()) :: term()
  defp tag_editor_buffer({:highlight_names, _buffer_id, names}, buffer_pid),
    do: {:highlight_names, buffer_pid, names}

  defp tag_editor_buffer({:highlight_spans, _buffer_id, _version, spans}, buffer_pid),
    do: {:highlight_spans, buffer_pid, spans}

  defp tag_editor_buffer({:injection_ranges, _buffer_id, ranges}, buffer_pid),
    do: {:injection_ranges, buffer_pid, ranges}

  defp tag_editor_buffer({:conceal_spans, _buffer_id, _version, spans}, buffer_pid),
    do: {:conceal_spans, buffer_pid, spans}

  defp tag_editor_buffer({:fold_ranges, _buffer_id, _version, ranges}, buffer_pid),
    do: {:fold_ranges, buffer_pid, ranges}

  defp tag_editor_buffer({:textobject_positions, _buffer_id, _version, positions}, buffer_pid),
    do: {:textobject_positions, buffer_pid, positions}

  defp tag_editor_buffer({:document_symbols, _buffer_id, _version, symbols}, buffer_pid),
    do: {:document_symbols, buffer_pid, symbols}

  defp tag_editor_buffer(event, _buffer_pid), do: event

  @spec complete_editor_parse(t(), pid(), pos_integer(), term()) :: {:noreply, t()}
  defp complete_editor_parse(state, buffer_pid, version, event) do
    case BufferRegistry.fetch(state.buffers, buffer_pid) do
      {:ok, registration} ->
        finish_matching_parse(state, buffer_pid, registration, version, event)

      :error ->
        {:noreply, state}
    end
  end

  @spec finish_matching_parse(t(), pid(), BufferRegistration.t(), pos_integer(), term()) ::
          {:noreply, t()}
  defp finish_matching_parse(state, buffer_pid, registration, version, event) do
    case BufferRegistration.complete_parse(registration, version) do
      {:ok, completed} ->
        buffers = BufferRegistry.put(state.buffers, buffer_pid, completed)

        state =
          state
          |> Map.put(:buffers, buffers)
          |> release_parse_admission(buffer_pid)
          |> pump_buffer(buffer_pid)
          |> dispatch_next_parse()

        editor_event = tag_editor_buffer(event, buffer_pid)
        broadcast(state.subscribers, {:minga_highlight, editor_event})
        {:noreply, state}

      :stale ->
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
      state = restart_parse_pumps(state)
      broadcast(state.subscribers, {:minga_highlight, :parser_restarted})
      # Reset backoff on success
      %{state | current_backoff_ms: @initial_backoff_ms}
    else
      # Binary missing; schedule another attempt
      schedule_restart(state)
    end
  end

  @spec register_editor_buffer(t(), pid(), BufferConfig.t()) :: {pos_integer(), t()}
  defp register_editor_buffer(state, buffer_pid, %BufferConfig{} = config) do
    {buffer_id, status, buffers} =
      BufferRegistry.register(state.buffers, buffer_pid, config, monotonic_ms())

    buffers =
      case status do
        :new ->
          BufferRegistry.put_monitor(buffers, buffer_pid, Process.monitor(buffer_pid))

        :existing ->
          buffers

        {:replaced, old_id} ->
          maybe_close_editor_buffer(state.port, old_id)
          buffers
      end

    parse_scheduler =
      case status do
        {:replaced, _old_id} -> ParseScheduler.release(state.parse_scheduler, buffer_pid)
        _other -> state.parse_scheduler
      end

    {buffer_id, %{state | buffers: buffers, parse_scheduler: parse_scheduler}}
  end

  @spec unregister_editor_buffer(t(), pid(), boolean()) :: t()
  defp unregister_editor_buffer(state, buffer_pid, demonitor? \\ true) do
    {buffer_id, monitor_ref, buffers} = BufferRegistry.unregister(state.buffers, buffer_pid)
    maybe_demonitor(monitor_ref, demonitor?)
    maybe_close_editor_buffer(state.port, buffer_id)
    parse_scheduler = ParseScheduler.release(state.parse_scheduler, buffer_pid)
    dispatch_next_parse(%{state | buffers: buffers, parse_scheduler: parse_scheduler})
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

  @spec recover_parser_buffer(t(), non_neg_integer()) :: t()
  defp recover_parser_buffer(state, buffer_id) do
    case BufferRegistry.resolve(state.buffers, buffer_id) do
      buffer_pid when is_pid(buffer_pid) -> force_parse(state, buffer_pid)
      nil -> state
    end
  end

  @spec force_parse(t(), pid()) :: t()
  defp force_parse(state, buffer_pid) do
    case BufferRegistry.fetch(state.buffers, buffer_pid) do
      {:ok, registration} ->
        buffers =
          BufferRegistry.put(state.buffers, buffer_pid, BufferRegistration.restart(registration))

        parse_scheduler = ParseScheduler.release(state.parse_scheduler, buffer_pid)
        pump_buffer(%{state | buffers: buffers, parse_scheduler: parse_scheduler}, buffer_pid)

      :error ->
        state
    end
  end

  @spec mark_buffer_dirty(t(), pid(), non_neg_integer()) :: t()
  defp mark_buffer_dirty(state, buffer_pid, sequence) do
    case BufferRegistry.fetch(state.buffers, buffer_pid) do
      {:ok, registration} ->
        registration = BufferRegistration.mark_dirty(registration, sequence)

        buffers =
          state.buffers
          |> BufferRegistry.put(buffer_pid, registration)
          |> BufferRegistry.touch(buffer_pid, monotonic_ms())

        pump_buffer(%{state | buffers: buffers}, buffer_pid)

      :error ->
        state
    end
  end

  @spec pump_buffer(t(), pid()) :: t()
  defp pump_buffer(%{port: nil} = state, _buffer_pid), do: state

  defp pump_buffer(state, buffer_pid) do
    case BufferRegistry.fetch(state.buffers, buffer_pid) do
      {:ok, registration} ->
        if BufferRegistration.pumpable?(registration) do
          parse_scheduler = ParseScheduler.enqueue(state.parse_scheduler, buffer_pid)
          dispatch_next_parse(%{state | parse_scheduler: parse_scheduler})
        else
          state
        end

      :error ->
        state
    end
  end

  @spec dispatch_next_parse(t()) :: t()
  defp dispatch_next_parse(%{port: nil} = state), do: state

  defp dispatch_next_parse(state) do
    case ParseScheduler.activate_next(state.parse_scheduler) do
      {:ok, buffer_pid, parse_scheduler} ->
        state
        |> Map.put(:parse_scheduler, parse_scheduler)
        |> dispatch_activated_buffer(buffer_pid)

      :busy ->
        state

      :empty ->
        state
    end
  end

  @spec dispatch_activated_buffer(t(), pid()) :: t()
  defp dispatch_activated_buffer(state, buffer_pid) do
    case BufferRegistry.fetch(state.buffers, buffer_pid) do
      {:ok, registration} ->
        if BufferRegistration.pumpable?(registration) do
          request_active_snapshot(state, buffer_pid, registration)
        else
          continue_parse_dispatch(state, buffer_pid)
        end

      :error ->
        continue_parse_dispatch(state, buffer_pid)
    end
  end

  @spec continue_parse_dispatch(t(), pid()) :: t()
  defp continue_parse_dispatch(state, buffer_pid) do
    state
    |> release_parse_admission(buffer_pid)
    |> dispatch_next_parse()
  end

  @spec request_active_snapshot(t(), pid(), BufferRegistration.t()) :: t()
  defp request_active_snapshot(state, buffer_pid, registration) do
    token = make_ref()
    cursor = BufferRegistration.snapshot_cursor(registration)
    awaiting = BufferRegistration.await_snapshot(registration, token)
    buffers = BufferRegistry.put(state.buffers, buffer_pid, awaiting)
    :ok = Buffer.request_sync_snapshot(buffer_pid, cursor, self(), token)

    state
    |> Map.put(:buffers, buffers)
    |> arm_parse_admission_timeout(buffer_pid, {:snapshot, token})
  end

  @spec handle_sync_snapshot(t(), SyncSnapshot.t()) :: t()
  defp handle_sync_snapshot(state, %SyncSnapshot{buffer: buffer_pid, token: token} = snapshot) do
    case BufferRegistry.fetch(state.buffers, buffer_pid) do
      {:ok, registration} ->
        handle_current_snapshot(state, buffer_pid, registration, snapshot, token)

      :error ->
        state
    end
  end

  @spec handle_current_snapshot(t(), pid(), BufferRegistration.t(), SyncSnapshot.t(), reference()) ::
          t()
  defp handle_current_snapshot(state, buffer_pid, registration, snapshot, token) do
    if BufferRegistration.awaiting?(registration, token) do
      apply_sync_snapshot(state, buffer_pid, registration, snapshot)
    else
      state
    end
  end

  @spec apply_sync_snapshot(t(), pid(), BufferRegistration.t(), SyncSnapshot.t()) :: t()
  defp apply_sync_snapshot(state, buffer_pid, registration, %SyncSnapshot{
         changes: :unchanged,
         sequence: sequence
       }) do
    completed = BufferRegistration.complete_unchanged(registration, sequence)
    buffers = BufferRegistry.put(state.buffers, buffer_pid, completed)

    state
    |> Map.put(:buffers, buffers)
    |> release_parse_admission(buffer_pid)
    |> pump_buffer(buffer_pid)
    |> dispatch_next_parse()
  end

  defp apply_sync_snapshot(%{port: nil} = state, buffer_pid, registration, _snapshot) do
    buffers =
      BufferRegistry.put(state.buffers, buffer_pid, BufferRegistration.restart(registration))

    state |> Map.put(:buffers, buffers) |> release_parse_admission(buffer_pid)
  end

  defp apply_sync_snapshot(state, buffer_pid, registration, snapshot) do
    {version, buffers} = BufferRegistry.next_parse_version(state.buffers)
    commands = snapshot_commands(registration, version, snapshot.changes)
    full? = match?({:full, _content}, snapshot.changes)

    if send_command_batch(state.port, commands) do
      parsing = BufferRegistration.begin_parse(registration, version, snapshot.sequence, full?)

      state
      |> Map.put(:buffers, BufferRegistry.put(buffers, buffer_pid, parsing))
      |> arm_parse_admission_timeout(buffer_pid, {:parse, make_ref()})
    else
      Minga.Log.warning(:port, "Parser: parse write failed; scheduling restart")
      retained = BufferRegistration.restart(registration)
      buffers = BufferRegistry.put(buffers, buffer_pid, retained)

      state
      |> Map.put(:buffers, buffers)
      |> fail_pending_requests()
      |> reset_parse_admission()
      |> close_port()
      |> schedule_restart()
    end
  end

  @spec snapshot_commands(BufferRegistration.t(), pos_integer(), SyncSnapshot.changes()) :: [
          binary()
        ]
  defp snapshot_commands(registration, version, {:full, content}) do
    parse = Protocol.encode_parse_buffer(registration.id, version, content)

    if registration.force_full? do
      setup_commands(registration.id, registration.config) ++ [parse]
    else
      [parse]
    end
  end

  defp snapshot_commands(registration, version, {:edits, edits}) do
    encoded_edits = Enum.map(edits, &Map.from_struct/1)
    [Protocol.encode_edit_buffer(registration.id, version, encoded_edits)]
  end

  @spec setup_commands(pos_integer(), BufferConfig.t()) :: [binary()]
  defp setup_commands(buffer_id, %BufferConfig{} = config) do
    [Protocol.encode_set_language(buffer_id, config.language)]
    |> append_query(config.highlight_query, &Protocol.encode_set_highlight_query(buffer_id, &1))
    |> append_query(config.injection_query, &Protocol.encode_set_injection_query(buffer_id, &1))
    |> append_query(config.fold_query, &Protocol.encode_set_fold_query(buffer_id, &1))
    |> append_query(config.textobject_query, &Protocol.encode_set_textobject_query(buffer_id, &1))
    |> append_query(config.tags_query, &Protocol.encode_set_tags_query(buffer_id, &1))
  end

  @spec append_query([binary()], String.t() | nil, (String.t() -> binary())) :: [binary()]
  defp append_query(commands, nil, _encoder), do: commands
  defp append_query(commands, query, encoder), do: commands ++ [encoder.(query)]

  @spec send_command_batch(port(), [binary()]) :: boolean()
  defp send_command_batch(port, commands) do
    payload = IO.iodata_to_binary(commands)

    try do
      Port.command(port, payload)
    rescue
      ArgumentError -> false
    catch
      :exit, _reason -> false
    end
  end

  @spec maybe_close_editor_buffer(port() | nil, pos_integer() | nil) :: :ok
  defp maybe_close_editor_buffer(_port, nil), do: :ok
  defp maybe_close_editor_buffer(nil, _buffer_id), do: :ok

  defp maybe_close_editor_buffer(port, buffer_id) do
    _sent? = send_command_batch(port, [Protocol.encode_close_buffer(buffer_id)])
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

    evicted_pids = Enum.map(evicted, &elem(&1, 0))

    parse_scheduler =
      Enum.reduce(evicted_pids, state.parse_scheduler, &ParseScheduler.release(&2, &1))

    state = %{state | buffers: buffers, parse_scheduler: parse_scheduler}
    {evicted_pids, dispatch_next_parse(state)}
  end

  @spec monotonic_ms() :: integer()
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  @spec arm_parse_admission_timeout(t(), pid(), term()) :: t()
  defp arm_parse_admission_timeout(state, buffer_pid, token) do
    state = cancel_parse_admission_timer(state)

    timer_ref =
      Process.send_after(
        self(),
        {:parse_admission_timeout, buffer_pid, token},
        @parse_admission_timeout_ms
      )

    %{
      state
      | parse_scheduler: ParseScheduler.arm_timeout(state.parse_scheduler, token, timer_ref)
    }
  end

  @spec release_parse_admission(t(), pid()) :: t()
  defp release_parse_admission(state, buffer_pid) do
    if ParseScheduler.active?(state.parse_scheduler, buffer_pid) do
      state = cancel_parse_admission_timer(state)
      %{state | parse_scheduler: ParseScheduler.release(state.parse_scheduler, buffer_pid)}
    else
      state
    end
  end

  @spec reset_parse_admission(t()) :: t()
  defp reset_parse_admission(state) do
    state = cancel_parse_admission_timer(state)
    %{state | parse_scheduler: ParseScheduler.reset(state.parse_scheduler)}
  end

  @spec cancel_parse_admission_timer(t()) :: t()
  defp cancel_parse_admission_timer(state) do
    case ParseScheduler.timeout_ref(state.parse_scheduler) do
      nil ->
        state

      timer_ref ->
        Process.cancel_timer(timer_ref)
        state
    end
  end

  @spec restart_parse_pumps(t()) :: t()
  defp restart_parse_pumps(state) do
    buffer_count = BufferRegistry.count(state.buffers)

    if buffer_count > 0 do
      Minga.Log.info(:port, "Parser: re-syncing #{buffer_count} buffer(s)")
    end

    state = %{
      state
      | buffers: BufferRegistry.restart_all(state.buffers),
        parse_scheduler: ParseScheduler.reset(state.parse_scheduler)
    }

    state.buffers
    |> BufferRegistry.entries()
    |> Map.keys()
    |> Enum.reduce(state, &pump_buffer(&2, &1))
  end

  @spec enqueue_buffer_request(
          t(),
          pid(),
          GenServer.from(),
          pos_integer(),
          (pos_integer(), non_neg_integer() -> binary())
        ) :: {:noreply, t()} | {:reply, nil, t()}
  defp enqueue_buffer_request(state, buffer_pid, from, timeout_ms, command_fn) do
    case BufferRegistry.fetch(state.buffers, buffer_pid) do
      {:ok, registration} ->
        if BufferRegistration.ready?(registration) do
          request_id = state.next_request_id
          command = command_fn.(registration.id, request_id)
          enqueue_pending_request(state, from, request_id, command, timeout_ms)
        else
          {:reply, nil, state}
        end

      :error ->
        {:reply, nil, state}
    end
  end

  @spec enqueue_pending_request(
          t(),
          GenServer.from(),
          non_neg_integer(),
          binary(),
          pos_integer()
        ) :: {:noreply, t()}
  defp enqueue_pending_request(state, from, request_id, cmd, timeout_ms) do
    if send_command_batch(state.port, [cmd]) do
      pending = Map.put(state.pending_requests, request_id, from)
      Process.send_after(self(), {:request_timeout, request_id}, timeout_ms)
      {:noreply, %{state | next_request_id: request_id + 1, pending_requests: pending}}
    else
      Minga.Log.warning(:port, "Parser: command write failed; scheduling restart")
      GenServer.reply(from, nil)

      state =
        state
        |> close_port()
        |> fail_pending_requests()
        |> reset_parse_admission()
        |> schedule_restart()

      {:noreply, state}
    end
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
