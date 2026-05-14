defmodule Minga.Parser.Manager do
  @moduledoc """
  GenServer that manages the tree-sitter parser Port process.

  Spawns the `minga-parser` binary as an Erlang Port with `{:packet, 4}`
  framing. Incoming highlight responses from the parser are decoded and
  forwarded to subscribers. Outgoing highlight commands are encoded and
  sent to the Port.

  This is the parsing counterpart to the frontend manager (which handles
  rendering). Separating parsing from rendering means every frontend gets
  syntax highlighting for free, and a parser crash does not kill the
  renderer.

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
  alias Minga.Parser.Protocol

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

  @typedoc "Tracked buffer metadata for re-sync after parser restart."
  @type buffer_meta :: %{
          language: String.t(),
          content_fn: (-> String.t()),
          setup_commands_fn: (non_neg_integer() -> [binary()]) | nil
        }

  defmodule State do
    @moduledoc false
    @enforce_keys [:parser_path]
    defstruct port: nil,
              subscribers: [],
              parser_path: "",
              ready: false,
              next_request_id: 1,
              pending_requests: %{},
              next_snippet_buffer_id: 4_000_000_000,
              pending_highlights: %{},
              # Crash recovery
              restart_timestamps: [],
              current_backoff_ms: 100,
              gave_up: false,
              # Buffer tracking for re-sync
              buffer_registry: %{}

    @type t :: %__MODULE__{
            port: port() | nil,
            subscribers: [pid()],
            parser_path: String.t(),
            ready: boolean(),
            next_request_id: non_neg_integer(),
            pending_requests: %{non_neg_integer() => GenServer.from()},
            next_snippet_buffer_id: non_neg_integer(),
            pending_highlights: %{non_neg_integer() => Minga.Parser.Manager.pending_highlight()},
            restart_timestamps: [integer()],
            current_backoff_ms: non_neg_integer(),
            gave_up: boolean(),
            buffer_registry: %{non_neg_integer() => Minga.Parser.Manager.buffer_meta()}
          }
  end

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
  Registers a buffer with language and a content function for crash recovery.

  Called by HighlightSync when setting up a buffer. If the parser crashes,
  Manager replays the full setup using `setup_commands_fn` (if provided) or
  falls back to `set_language` + `parse_buffer` using the stored content_fn.

  ## Options

    * `:setup_commands_fn` — a function that takes `buffer_id` and returns
      the full list of encoded protocol commands needed to set up the buffer
      (language, queries, parse). Used to replay custom highlight/fold/textobject
      queries that users may have in `~/.config/minga/queries/`.
    * `:server` — the GenServer to send the registration to (default: `__MODULE__`).
  """
  @spec register_buffer(non_neg_integer(), String.t(), (-> String.t()), [register_opt()]) :: :ok
  def register_buffer(buffer_id, language, content_fn, opts \\ [])
      when is_integer(buffer_id) and is_binary(language) and is_function(content_fn, 0) do
    server = Keyword.get(opts, :server, __MODULE__)
    setup_fn = Keyword.get(opts, :setup_commands_fn)
    GenServer.cast(server, {:register_buffer, buffer_id, language, content_fn, setup_fn})
  end

  @doc """
  Unregisters a buffer from crash recovery tracking.
  """
  @spec unregister_buffer(non_neg_integer(), GenServer.server()) :: :ok
  def unregister_buffer(buffer_id, server \\ __MODULE__) when is_integer(buffer_id) do
    GenServer.cast(server, {:unregister_buffer, buffer_id})
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

    timeout =
      normalize_highlight_timeout(Keyword.get(opts, :timeout, @default_highlight_timeout_ms))

    GenServer.call(server, {:highlight_source, language, source, timeout}, timeout + 100)
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
  @spec init(keyword()) :: {:ok, State.t()}
  def init(opts) do
    parser_path = Keyword.get(opts, :parser_path, default_parser_path())
    state = %State{parser_path: parser_path}
    {:ok, start_port(state)}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    subscribers = [pid | state.subscribers] |> Enum.uniq()
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call(
        {:request_indent, _buffer_id, _line, _timeout_ms},
        _from,
        %{port: nil} = state
      ) do
    {:reply, nil, state}
  end

  def handle_call({:request_indent, buffer_id, _line, _timeout_ms}, _from, state)
      when not is_map_key(state.buffer_registry, buffer_id) do
    {:reply, nil, state}
  end

  def handle_call({:request_indent, buffer_id, line, timeout_ms}, from, state) do
    request_id = state.next_request_id
    cmd = Protocol.encode_request_indent(buffer_id, request_id, line)
    enqueue_pending_request(state, from, request_id, cmd, timeout_ms)
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

  @impl true
  def handle_cast({:send_commands, _commands}, %{port: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:send_commands, commands}, state) do
    batch = IO.iodata_to_binary(commands)
    Port.command(state.port, batch)
    {:noreply, state}
  end

  def handle_cast({:register_buffer, buffer_id, language, content_fn, setup_fn}, state) do
    meta = %{language: language, content_fn: content_fn, setup_commands_fn: setup_fn}
    registry = Map.put(state.buffer_registry, buffer_id, meta)
    {:noreply, %{state | buffer_registry: registry}}
  end

  def handle_cast({:unregister_buffer, buffer_id}, state) do
    registry = Map.delete(state.buffer_registry, buffer_id)
    {:noreply, %{state | buffer_registry: registry}}
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

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    subscribers = Enum.reject(state.subscribers, &(&1 == pid))
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
          State.t()
        ) :: {:noreply, State.t()}
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

  @spec handle_highlight_source_event_or_broadcast(term(), State.t()) :: {:noreply, State.t()}
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

  @spec handle_highlight_source_event(highlight_source_event(), State.t()) ::
          {:handled | :miss, State.t()}
  defp handle_highlight_source_event({:highlight_names, buffer_id, names}, state) do
    update_highlight_source_pending(buffer_id, :names, names, state)
  end

  defp handle_highlight_source_event({:highlight_spans, buffer_id, _version, spans}, state) do
    update_highlight_source_pending(buffer_id, :spans, spans, state)
  end

  @spec broadcast_or_drop_snippet_event(term(), State.t()) :: {:noreply, State.t()}
  defp broadcast_or_drop_snippet_event(event, state) do
    case snippet_buffer_event?(event) do
      true ->
        Minga.Log.debug(
          :port,
          "Parser: dropping late snippet event #{inspect(event_name(event))}"
        )

        {:noreply, state}

      false ->
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

  @spec update_highlight_source_pending(non_neg_integer(), :names | :spans, [term()], State.t()) ::
          {:handled | :miss, State.t()}
  defp update_highlight_source_pending(buffer_id, field, value, state) do
    case Map.fetch(state.pending_highlights, buffer_id) do
      :error ->
        {:miss, state}

      {:ok, pending_highlight} ->
        pending_highlight = Map.put(pending_highlight, field, value)
        maybe_complete_highlight_source(buffer_id, pending_highlight, state)
    end
  end

  @spec maybe_complete_highlight_source(non_neg_integer(), pending_highlight(), State.t()) ::
          {:handled, State.t()}
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

  @spec close_highlight_source_buffer(State.t(), non_neg_integer()) :: State.t()
  defp close_highlight_source_buffer(%{port: nil} = state, _buffer_id), do: state

  defp close_highlight_source_buffer(state, buffer_id) do
    Port.command(state.port, Protocol.encode_close_buffer(buffer_id))
    state
  end

  # ── Private: Port lifecycle ──

  @spec start_port(State.t()) :: State.t()
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

  @spec close_port(State.t()) :: State.t()
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

  @spec schedule_restart(State.t()) :: State.t()
  defp schedule_restart(%{gave_up: true} = state), do: state

  defp schedule_restart(state) do
    now = System.monotonic_time(:millisecond)

    # Prune timestamps outside the restart window
    recent = Enum.filter(state.restart_timestamps, fn ts -> now - ts < @restart_window_ms end)
    recent = [now | recent]

    if length(recent) >= @max_restart_attempts do
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
        "Parser: scheduling restart in #{backoff}ms (attempt #{length(recent)}/#{@max_restart_attempts})"
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

  @spec attempt_restart(State.t()) :: State.t()
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

  @spec resync_all_buffers(State.t()) :: State.t()
  defp resync_all_buffers(%{port: nil} = state), do: state

  defp resync_all_buffers(state) do
    buffer_count = map_size(state.buffer_registry)

    if buffer_count > 0 do
      Minga.Log.info(:port, "Parser: re-syncing #{buffer_count} buffer(s)")

      commands =
        Enum.flat_map(state.buffer_registry, fn {buffer_id, meta} ->
          resync_buffer_commands(buffer_id, meta)
        end)

      if commands != [] do
        batch = IO.iodata_to_binary(commands)
        Port.command(state.port, batch)
      end
    end

    state
  end

  # Uses the full setup_commands_fn if available (replays custom queries),
  # otherwise falls back to set_language + parse_buffer.
  @spec resync_buffer_commands(non_neg_integer(), buffer_meta()) :: [binary()]
  defp resync_buffer_commands(buffer_id, meta) do
    if is_function(meta.setup_commands_fn, 1) do
      try do
        meta.setup_commands_fn.(buffer_id)
      rescue
        _ ->
          Minga.Log.warning(
            :port,
            "Parser: setup_commands_fn failed for buffer #{buffer_id}, falling back"
          )

          resync_buffer_fallback(buffer_id, meta)
      end
    else
      resync_buffer_fallback(buffer_id, meta)
    end
  end

  @spec resync_buffer_fallback(non_neg_integer(), buffer_meta()) :: [binary()]
  defp resync_buffer_fallback(buffer_id, meta) do
    content =
      try do
        meta.content_fn.()
      rescue
        _ ->
          Minga.Log.warning(:port, "Parser: content_fn failed for buffer #{buffer_id}, skipping")
          nil
      end

    case content do
      nil ->
        []

      text ->
        [
          Protocol.encode_set_language(buffer_id, meta.language),
          Protocol.encode_parse_buffer(buffer_id, 0, text)
        ]
    end
  end

  @spec enqueue_pending_request(
          State.t(),
          GenServer.from(),
          non_neg_integer(),
          binary(),
          pos_integer()
        ) :: {:noreply, State.t()}
  defp enqueue_pending_request(state, from, request_id, cmd, timeout_ms) do
    Port.command(state.port, cmd)
    pending = Map.put(state.pending_requests, request_id, from)
    Process.send_after(self(), {:request_timeout, request_id}, timeout_ms)
    {:noreply, %{state | next_request_id: request_id + 1, pending_requests: pending}}
  end

  @spec fail_pending_requests(State.t()) :: State.t()
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

  @spec reply_to_pending_request(State.t(), non_neg_integer(), term()) :: {:noreply, State.t()}
  defp reply_to_pending_request(state, request_id, result) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, _pending} ->
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, result)
        {:noreply, %{state | pending_requests: pending}}
    end
  end

  @spec broadcast([pid()], term()) :: :ok
  defp broadcast(subscribers, message) do
    Enum.each(subscribers, &send(&1, message))
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
