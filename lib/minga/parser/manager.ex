defmodule Minga.Parser.Manager do
  @moduledoc """
  GenServer that manages the tree-sitter parser Port process.

  Spawns the `minga-parser` binary as an Erlang Port with `{:packet, 4}`
  framing. Incoming highlight responses from the parser are decoded and
  forwarded to subscribers. Outgoing highlight commands are encoded and
  sent to the Port.

  This is the parsing counterpart to `Minga.Port.Manager` (which handles
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
  `Minga.Port.Protocol`.
  """

  use GenServer

  alias Minga.Port.Protocol

  # ── Restart constants ──

  @initial_backoff_ms 100
  @max_backoff_ms 5_000
  @max_restart_attempts 5
  @restart_window_ms 30_000

  @typedoc "Options for starting the parser manager."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:parser_path, String.t()}

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
  Requests a tree-sitter text object range synchronously.

  Sends a `request_textobject` command to the Zig parser and blocks until
  the result arrives (or times out after 2 seconds).

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
    GenServer.call(server, {:request_textobject, buffer_id, row, col, capture_name}, 2_000)
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
        {:request_textobject, _buffer_id, _row, _col, _capture},
        _from,
        %{port: nil} = state
      ) do
    {:reply, nil, state}
  end

  def handle_call({:request_textobject, buffer_id, row, col, capture_name}, from, state) do
    request_id = state.next_request_id
    cmd = Protocol.encode_request_textobject(buffer_id, request_id, row, col, capture_name)
    Port.command(state.port, cmd)

    pending = Map.put(state.pending_requests, request_id, from)

    {:noreply, %{state | next_request_id: request_id + 1, pending_requests: pending}}
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
      {:ok, {:textobject_result, request_id, result}} ->
        case Map.pop(state.pending_requests, request_id) do
          {nil, _pending} ->
            {:noreply, state}

          {from, pending} ->
            GenServer.reply(from, result)
            {:noreply, %{state | pending_requests: pending}}
        end

      {:ok, {:log_message, _level, _text} = event} ->
        broadcast(state.subscribers, {:minga_highlight, event})
        {:noreply, state}

      {:ok, event} ->
        broadcast(state.subscribers, {:minga_highlight, event})
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

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    subscribers = Enum.reject(state.subscribers, &(&1 == pid))
    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
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

      Minga.Editor.log_to_messages(
        "Parser crashed repeatedly, syntax highlighting disabled. Use :parser-restart to retry."
      )

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

  @spec fail_pending_requests(State.t()) :: State.t()
  defp fail_pending_requests(%{pending_requests: pending} = state) when pending == %{}, do: state

  defp fail_pending_requests(state) do
    Enum.each(state.pending_requests, fn {_id, from} ->
      GenServer.reply(from, nil)
    end)

    %{state | pending_requests: %{}}
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
