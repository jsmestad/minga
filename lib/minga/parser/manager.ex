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

  alias Minga.Buffer.SyncSnapshot
  alias Minga.Events
  alias Minga.Language.Highlight.Span
  alias Minga.Language.Registry, as: LanguageRegistry
  alias Minga.Parser.BufferConfig
  alias Minga.Parser.BufferRegistry
  alias Minga.Parser.BufferLifecycle
  alias Minga.Parser.EventCorrelation
  alias Minga.Parser.EventRouter
  alias Minga.Parser.ParseScheduler
  alias Minga.Parser.ParseSync
  alias Minga.Parser.PortLifecycle
  alias Minga.Parser.PortState
  alias Minga.Parser.Protocol
  alias Minga.Parser.RequestHandler
  alias Minga.Parser.RequestState
  alias Minga.Parser.SnippetState
  alias Minga.Parser.StructuralNavResult

  # ── Restart constants ──

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
          | {:events_registry, Events.registry()}

  @typedoc "Synchronous syntax highlight result for a small source snippet."
  @type highlight_source_result ::
          {:ok, [String.t()], [Span.t()]}
          | :unsupported
          | :timeout
          | :unavailable

  @typedoc "Structural navigation result returned by the parser."
  @type structural_nav_result :: StructuralNavResult.t()

  defstruct port: nil,
            requests: RequestState.new(),
            snippets: SnippetState.new(),
            buffers: BufferRegistry.new(),
            parse_scheduler: ParseScheduler.new(),
            subscribers: %{},
            events_registry: Events.default_registry()

  @type t :: %__MODULE__{
          port: PortState.t(),
          requests: RequestState.t(),
          snippets: SnippetState.t(),
          buffers: BufferRegistry.t(),
          parse_scheduler: ParseScheduler.t(),
          subscribers: %{pid() => reference()},
          events_registry: Events.registry()
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

  @doc "Registers a buffer and returns editor-facing event correlation metadata."
  @spec register_buffer_correlated(pid(), BufferConfig.t(), [register_opt()]) ::
          EventCorrelation.t()
  def register_buffer_correlated(buffer_pid, %BufferConfig{} = config, opts \\ [])
      when is_pid(buffer_pid) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:register_buffer_correlated, buffer_pid, config})
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
    state = %__MODULE__{port: PortState.new(parser_path), events_registry: events_registry}
    state = install_port_start(state, PortLifecycle.start(parser_path))
    Minga.Telemetry.StartupTimer.mark(:parser_port_ready)
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    subscribers = monitor_subscriber(state.subscribers, pid)
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:request_indent, buffer, line, timeout}, from, state) do
    enqueue_request(state, buffer, from, timeout, fn id, request_id ->
      Protocol.encode_request_indent(id, request_id, line)
    end)
  end

  def handle_call({:request_textobject, buffer, row, col, capture, timeout}, from, state) do
    enqueue_request(state, buffer, from, timeout, fn id, request_id ->
      Protocol.encode_request_textobject(id, request_id, row, col, capture)
    end)
  end

  def handle_call({:request_match_item, buffer, row, col, timeout}, from, state) do
    enqueue_request(state, buffer, from, timeout, fn id, request_id ->
      Protocol.encode_request_match_item(id, request_id, row, col)
    end)
  end

  def handle_call({:request_structural_nav, buffer, row, col, action, timeout}, from, state) do
    enqueue_request(state, buffer, from, timeout, fn id, request_id ->
      Protocol.encode_request_structural_nav(id, request_id, row, col, action)
    end)
  end

  def handle_call(
        {:highlight_source, _language, _source, _timeout},
        _from,
        %{port: %{handle: nil}} = state
      ),
      do: {:reply, :unavailable, state}

  def handle_call({:highlight_source, language, source, timeout}, from, state) do
    case EventRouter.start_highlight(
           language,
           source,
           timeout,
           from,
           state.port.handle,
           state.snippets
         ) do
      {:noreply, snippets} -> {:noreply, %{state | snippets: snippets}}
      {:reply, result, snippets} -> {:reply, result, %{state | snippets: snippets}}
    end
  end

  def handle_call(:restart, _from, state), do: handle_manual_restart(state)

  def handle_call(:available?, _from, state),
    do: {:reply, state.port.handle != nil and state.port.ready?, state}

  def handle_call({:register_buffer, buffer, config}, _from, state) do
    {buffer_id, state} = register_buffer_state(state, buffer, config)
    {:reply, buffer_id, pump(state, buffer)}
  end

  def handle_call({:register_buffer_correlated, buffer, config}, _from, state) do
    {_buffer_id, state} = register_buffer_state(state, buffer, config)
    {:ok, registration} = BufferRegistry.fetch(state.buffers, buffer)

    correlation =
      EventCorrelation.new(registration.generation, registration.last_completed_version)

    {:reply, correlation, pump(state, buffer)}
  end

  def handle_call({:buffer_id, buffer}, _from, state),
    do: {:reply, BufferRegistry.buffer_id(state.buffers, buffer), state}

  def handle_call({:resolve_buffer, buffer_id}, _from, state),
    do: {:reply, BufferRegistry.resolve(state.buffers, buffer_id), state}

  def handle_call({:unregister_buffer, buffer}, _from, state),
    do: {:reply, :ok, unregister_buffer_state(state, buffer)}

  def handle_call({:evict_inactive, protected, ttl_ms}, _from, state) do
    {evicted, result} =
      BufferLifecycle.evict_inactive(
        state.port.handle,
        state.buffers,
        state.parse_scheduler,
        state.requests,
        protected,
        ttl_ms
      )

    {:reply, evicted, install_sync_result(state, result)}
  end

  @impl true
  def handle_cast({:send_commands, _commands}, %{port: %{handle: nil}} = state),
    do: {:noreply, state}

  def handle_cast({:send_commands, commands}, state) do
    if PortLifecycle.send_batch(state.port.handle, commands) do
      {:noreply, state}
    else
      Minga.Log.warning(:port, "Parser: command write failed; scheduling restart")
      {:noreply, recover_write_failure(state)}
    end
  end

  def handle_cast({:request_parse, buffer}, state),
    do: {:noreply, force_parse(state, buffer)}

  def handle_cast({:touch_buffer, buffer}, state),
    do: {:noreply, %{state | buffers: BufferLifecycle.touch(state.buffers, buffer)}}

  @impl true
  def handle_info(
        {:minga_event, :buffer_changed,
         %Events.BufferChangedEvent{buffer: buffer, sequence: sequence}},
        state
      ) do
    result =
      ParseSync.mark_dirty(
        state.port.handle,
        state.buffers,
        state.parse_scheduler,
        state.requests,
        buffer,
        sequence
      )

    {:noreply, install_sync_result(state, result)}
  end

  def handle_info({:buffer_sync_snapshot, %SyncSnapshot{} = snapshot}, state) do
    case RequestHandler.handle_snapshot(state.requests, state.buffers, snapshot) do
      {:handled, requests, buffers, buffer} ->
        state = %{state | requests: requests, buffers: buffers}
        state = pump(state, buffer)

        requests =
          RequestHandler.flush_buffer(state.port.handle, state.requests, state.buffers, buffer)

        {:noreply, %{state | requests: requests}}

      :unhandled ->
        result =
          ParseSync.handle_snapshot(
            state.port.handle,
            state.buffers,
            state.parse_scheduler,
            state.requests,
            snapshot
          )

        {:noreply, install_sync_result(state, result)}
    end
  end

  def handle_info({port, {:data, data}}, %{port: %{handle: port}} = state) do
    result =
      EventRouter.route(
        data,
        state.port.handle,
        state.buffers,
        state.parse_scheduler,
        state.requests,
        state.snippets,
        state.subscribers
      )

    {:noreply, install_route_result(state, result)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: %{handle: port}} = state),
    do: handle_port_exit(status, state)

  def handle_info(:restart_parser, state), do: handle_scheduled_restart(state)

  def handle_info({:highlight_source_timeout, buffer_id}, state) do
    {:noreply, snippets} =
      EventRouter.timeout_highlight(buffer_id, state.port.handle, state.snippets)

    {:noreply, %{state | snippets: snippets}}
  end

  def handle_info({:request_timeout, request_id}, state) do
    {:noreply, requests} = RequestHandler.reply(state.requests, request_id, nil)
    {:noreply, %{state | requests: requests}}
  end

  def handle_info({:buffer_request_timeout, token}, state),
    do: {:noreply, %{state | requests: RequestHandler.timeout(state.requests, token)}}

  def handle_info({:parse_admission_timeout, buffer, token}, state),
    do:
      handle_parse_timeout(
        ParseSync.handle_timeout(state.parse_scheduler, state.requests, buffer, token),
        buffer,
        state
      )

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state = handle_buffer_down(state, pid, ref)
    {:noreply, %{state | subscribers: remove_down_subscriber(state.subscribers, pid, ref)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  @spec terminate(term(), t()) :: :ok
  def terminate(_reason, state), do: PortLifecycle.close(state.port.handle)

  @spec enqueue_request(
          t(),
          pid(),
          GenServer.from(),
          pos_integer(),
          RequestState.command_builder()
        ) ::
          {:noreply, t()} | {:reply, nil, t()}
  defp enqueue_request(state, buffer, from, timeout, builder) do
    case RequestHandler.enqueue(
           state.port.handle,
           state.buffers,
           state.requests,
           buffer,
           from,
           timeout,
           builder
         ) do
      {:noreply, requests} -> {:noreply, %{state | requests: requests}}
      {:reply, nil, requests} -> {:reply, nil, %{state | requests: requests}}
    end
  end

  @spec register_buffer_state(t(), pid(), BufferConfig.t()) :: {pos_integer(), t()}
  defp register_buffer_state(state, buffer, config) do
    {buffer_id, {buffers, scheduler, requests}} =
      BufferLifecycle.register(
        state.port.handle,
        state.buffers,
        state.parse_scheduler,
        state.requests,
        buffer,
        config
      )

    {buffer_id, %{state | buffers: buffers, parse_scheduler: scheduler, requests: requests}}
  end

  @spec unregister_buffer_state(t(), pid()) :: t()
  defp unregister_buffer_state(state, buffer) do
    result =
      BufferLifecycle.unregister(
        state.port.handle,
        state.buffers,
        state.parse_scheduler,
        state.requests,
        buffer
      )

    install_sync_result(state, result)
  end

  @spec handle_buffer_down(t(), pid(), reference()) :: t()
  defp handle_buffer_down(state, pid, ref) do
    case BufferLifecycle.handle_down(
           state.port.handle,
           state.buffers,
           state.parse_scheduler,
           state.requests,
           pid,
           ref
         ) do
      :ignored -> state
      result -> install_sync_result(state, result)
    end
  end

  @spec pump(t(), pid()) :: t()
  defp pump(state, buffer) do
    result =
      ParseSync.pump(
        state.port.handle,
        state.buffers,
        state.parse_scheduler,
        state.requests,
        buffer
      )

    install_sync_result(state, result)
  end

  @spec force_parse(t(), pid()) :: t()
  defp force_parse(state, buffer) do
    result =
      ParseSync.force_parse(
        state.port.handle,
        state.buffers,
        state.parse_scheduler,
        state.requests,
        buffer
      )

    install_sync_result(state, result)
  end

  @spec install_sync_result(t(), ParseSync.result()) :: t()
  defp install_sync_result(state, {:ok, buffers, scheduler, requests}),
    do: %{state | buffers: buffers, parse_scheduler: scheduler, requests: requests}

  defp install_sync_result(state, {:port_write_failed, buffers, scheduler, requests}) do
    state = %{state | buffers: buffers, parse_scheduler: scheduler, requests: requests}
    recover_write_failure(state)
  end

  @spec install_route_result(t(), EventRouter.route_result()) :: t()
  defp install_route_result(state, {:noreply, buffers, scheduler, requests, snippets}),
    do: %{
      state
      | buffers: buffers,
        parse_scheduler: scheduler,
        requests: requests,
        snippets: snippets
    }

  defp install_route_result(state, {:port_write_failed, buffers, scheduler, requests, snippets}) do
    state = %{
      state
      | buffers: buffers,
        parse_scheduler: scheduler,
        requests: requests,
        snippets: snippets
    }

    recover_write_failure(state)
  end

  @spec handle_manual_restart(t()) :: {:reply, :ok | {:error, :binary_not_found}, t()}
  defp handle_manual_restart(state) do
    port_state = PortState.reset_restart_policy(state.port)

    case PortLifecycle.manual_restart(port_state.handle, port_state.parser_path) do
      {:restarted, handle} ->
        state = %{state | port: PortState.restarted(port_state, handle)}
        state = restart_pumps(state)
        broadcast(state.subscribers, {:minga_highlight, :parser_restarted})
        {:reply, :ok, state}

      :unavailable ->
        {:reply, {:error, :binary_not_found}, %{state | port: PortState.closed(port_state)}}
    end
  end

  @spec handle_scheduled_restart(t()) :: {:noreply, t()}
  defp handle_scheduled_restart(state) do
    case PortLifecycle.attempt_restart(
           state.port.gave_up?,
           state.port.handle,
           state.port.parser_path
         ) do
      {:restarted, handle} ->
        state = %{state | port: PortState.restarted(state.port, handle)}
        state = restart_pumps(state)
        broadcast(state.subscribers, {:minga_highlight, :parser_restarted})
        {:noreply, state}

      :unavailable ->
        {:noreply, schedule_restart(state)}

      :unchanged ->
        {:noreply, state}
    end
  end

  @spec restart_pumps(t()) :: t()
  defp restart_pumps(state) do
    result =
      ParseSync.restart_pumps(
        state.port.handle,
        state.buffers,
        state.parse_scheduler,
        state.requests
      )

    install_sync_result(state, result)
  end

  @spec handle_port_exit(non_neg_integer(), t()) :: {:noreply, t()}
  defp handle_port_exit(status, state) do
    log_port_exit(status)
    state = fail_pending(state)
    state = %{state | parse_scheduler: ParseSync.reset_admission(state.parse_scheduler)}
    :ok = PortLifecycle.close(state.port.handle)
    state = %{state | port: PortState.closed(state.port)}

    if status != 0 do
      broadcast(state.subscribers, {:minga_highlight, :parser_crashed})
    end

    {:noreply, schedule_restart(state)}
  end

  @spec recover_write_failure(t()) :: t()
  defp recover_write_failure(state) do
    state = fail_pending(state)
    state = %{state | parse_scheduler: ParseSync.reset_admission(state.parse_scheduler)}
    :ok = PortLifecycle.close(state.port.handle)
    state = %{state | port: PortState.closed(state.port)}
    schedule_restart(state)
  end

  @spec fail_pending(t()) :: t()
  defp fail_pending(state) do
    {requests, snippets} = PortLifecycle.fail_pending(state.requests, state.snippets)
    %{state | requests: requests, snippets: snippets}
  end

  @spec schedule_restart(t()) :: t()
  defp schedule_restart(state) do
    result =
      PortLifecycle.schedule_restart(
        state.port.gave_up?,
        state.port.restart_timestamps,
        state.port.backoff_ms,
        state.subscribers
      )

    case result do
      :unchanged ->
        state

      {:scheduled, timestamps, next_backoff} ->
        %{state | port: PortState.scheduled(state.port, timestamps, next_backoff)}

      {:gave_up, timestamps} ->
        %{state | port: PortState.gave_up(state.port, timestamps)}
    end
  end

  @spec install_port_start(t(), PortLifecycle.start_result()) :: t()
  defp install_port_start(state, {:ok, handle}),
    do: %{state | port: PortState.opened(state.port, handle)}

  defp install_port_start(state, :unavailable), do: state

  @spec handle_parse_timeout(ParseSync.timeout_result(), pid(), t()) :: {:noreply, t()}
  defp handle_parse_timeout(:ok, _buffer, state), do: {:noreply, state}

  defp handle_parse_timeout({:drop_buffer, requests}, buffer, state) do
    state = %{state | requests: requests}
    {:noreply, unregister_buffer_state(state, buffer)}
  end

  defp handle_parse_timeout(:restart_port, _buffer, state) do
    broadcast(state.subscribers, {:minga_highlight, :parser_crashed})
    {:noreply, recover_write_failure(state)}
  end

  @spec log_port_exit(non_neg_integer()) :: :ok
  defp log_port_exit(0), do: Minga.Log.warning(:port, "Parser process exited unexpectedly")

  defp log_port_exit(status),
    do: Minga.Log.error(:port, "Parser process crashed (exit status #{status})")

  @spec append_query([binary()], String.t() | nil, (String.t() -> binary())) :: [binary()]
  defp append_query(commands, nil, _encoder), do: commands
  defp append_query(commands, query, encoder), do: List.insert_at(commands, -1, encoder.(query))

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
    subscribers |> Map.keys() |> Enum.each(&send(&1, message))
  end

  @spec log_unavailable(atom(), term(), term()) :: term()
  defp log_unavailable(operation, reason, fallback) do
    Minga.Log.warning(:port, "Parser manager #{operation} unavailable: #{inspect(reason)}")
    fallback
  end

  @spec default_parser_path() :: String.t()
  defp default_parser_path do
    priv_path = Application.app_dir(:minga, "priv/minga-parser")

    if File.exists?(priv_path) do
      priv_path
    else
      Path.join([File.cwd!(), "zig", "zig-out", "bin", "minga-parser"])
    end
  end
end
