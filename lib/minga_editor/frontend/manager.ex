defmodule MingaEditor.Frontend.Manager do
  @moduledoc """
  GenServer that manages the frontend renderer Port.

  Operates in two modes depending on the `MINGA_PORT_MODE` env var:

  - **Spawn mode** (default): BEAM is the parent process. Port.Manager
    spawns the GUI/TUI binary as a child via `Port.open({:spawn_executable, ...})`.
    Used in development, TUI mode, and Burrito releases.

  - **Connected mode** (`MINGA_PORT_MODE=connected`): BEAM is a child of
    the GUI process. The GUI set up stdin/stdout pipes before launching us.
    Port.Manager opens `{:fd, 0, 1}` as a Port instead of spawning a child.
    Used when launching from `Minga.app` (Finder, Spotlight, Dock).

  Both modes use identical `{:packet, 4}` framing. The protocol layer (event decoding, render commands, subscriber broadcasting) is the same.

  Output admission always uses `Port.command/3` with `:nosuspend`. If the transport is unwritable, the manager retains one current frame and one latest coalesced replacement, retries within a short budget, then requests correlated keyframe recovery. Synchronous admission calls keep frame binaries out of the manager mailbox while leaving the process free to receive frontend input between attempts.

  Subscribers register via `subscribe/1` and receive messages as:

      {:minga_input, event}

  where `event` is a `MingaEditor.Frontend.Protocol.input_event()`.
  """

  use GenServer

  @behaviour MingaEditor.Frontend.Adapter

  alias Minga.Telemetry
  alias Minga.Telemetry.StartupTimer
  alias MingaEditor.Frontend.Manager.OutputHandler
  alias MingaEditor.Frontend.Manager.OutputPressure
  alias MingaEditor.Frontend.Protocol

  @typedoc "Renderer backend."
  @type backend :: :tui | :gui

  @typedoc "Non-suspending frontend transport admission result."
  @type admission :: :accepted | :unwritable

  @typedoc "Options for starting the port manager."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:renderer_path, String.t()}
          | {:backend, backend()}
          | {:port_mode, MingaEditor.Frontend.Manager.State.port_mode()}
          | {:port_opener, (term(), [term()] -> port())}
          | {:port_commander, MingaEditor.Frontend.Manager.State.port_commander()}
          | {:output_retry_ms, pos_integer()}
          | {:output_failure_ms, non_neg_integer()}
          | {:tty_path, String.t() | nil}

  alias MingaEditor.Frontend.Manager.State, as: PortState

  @typedoc "Internal state."
  @type state :: PortState.t()

  # ── Client API ──

  @doc "Starts the port manager."
  @impl MingaEditor.Frontend.Adapter
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Attempts non-suspending admission of encoded commands to the renderer."
  @impl MingaEditor.Frontend.Adapter
  @spec send_commands(GenServer.server() | nil, [binary()]) :: admission()
  def send_commands(server \\ __MODULE__, commands)
  def send_commands(nil, commands) when is_list(commands), do: :unwritable

  def send_commands(server, commands) when is_list(commands) do
    GenServer.call(server, {:send_commands, commands}, :infinity)
  end

  @doc """
  Like `send_commands/2` but stamps the synchronous admission request with a monotonic send time. The receiver emits a `[:minga, :render, :hop_latency]` (`hop: :send_commands`) sample measuring the Renderer.Server to Port.Manager scheduling delay. Used only for the per-frame render batch on the keystroke path.
  """
  @spec send_render_commands(GenServer.server() | nil, [binary()]) :: admission()
  def send_render_commands(server \\ __MODULE__, commands)
  def send_render_commands(nil, commands) when is_list(commands), do: :unwritable

  def send_render_commands(server, commands) when is_list(commands) do
    sent_at = System.monotonic_time(:microsecond)
    GenServer.call(server, {:send_render_commands, commands, sent_at}, :infinity)
  end

  @doc "Returns bounded output-pressure diagnostics."
  @spec output_pressure(GenServer.server()) :: OutputPressure.stats()
  def output_pressure(server \\ __MODULE__), do: GenServer.call(server, :output_pressure)

  @doc "Subscribes the calling process to receive input events."
  @impl MingaEditor.Frontend.Adapter
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc "Returns the terminal size as `{width, height}`, or nil if not yet ready."
  @impl MingaEditor.Frontend.Adapter
  @spec terminal_size(GenServer.server()) :: {pos_integer(), pos_integer()} | nil
  def terminal_size(server \\ __MODULE__) do
    GenServer.call(server, :terminal_size)
  end

  @doc "Returns whether the renderer has sent its ready signal."
  @impl MingaEditor.Frontend.Adapter
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server \\ __MODULE__) do
    GenServer.call(server, :ready?)
  end

  @doc "Returns the frontend's reported capabilities."
  @impl MingaEditor.Frontend.Adapter
  @spec capabilities(GenServer.server()) :: MingaEditor.Frontend.Capabilities.t()
  def capabilities(server \\ __MODULE__) do
    GenServer.call(server, :capabilities)
  end

  # ── Server Callbacks ──

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    StartupTimer.mark(:frontend_port_spawn)

    # Port.Manager sends large binary render commands every frame.
    # Frequent full sweeps reclaim binary refs promptly.
    Process.flag(:fullsweep_after, 20)

    port_mode = Keyword.get(opts, :port_mode, Application.get_env(:minga, :port_mode, :spawn))
    renderer_path = Keyword.fetch!(opts, :renderer_path)
    port_opener = Keyword.get(opts, :port_opener, &Port.open/2)
    tty_path = Keyword.get(opts, :tty_path)

    state = %PortState{
      renderer_path: renderer_path,
      port_mode: port_mode,
      tty_path: tty_path,
      output_pressure: OutputPressure.new(),
      port_commander: Keyword.get(opts, :port_commander, &Port.command/3),
      output_retry_ms: Keyword.get(opts, :output_retry_ms, 2),
      output_failure_ms: Keyword.get(opts, :output_failure_ms, 50)
    }

    result = {:ok, start_port(state, port_opener)}
    StartupTimer.mark(:frontend_port_ready)
    result
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    subscribers = [pid | state.subscribers] |> Enum.uniq()
    new_state = %{state | subscribers: subscribers}

    # Replay the ready event to late subscribers. In connected mode
    # (GUI frontend), the frontend may send the ready event before any
    # subscriber registers. The event gets broadcast to an empty list
    # and is lost. Replaying it here ensures the Editor always receives
    # the initial dimensions and capabilities regardless of startup
    # ordering.
    case new_state do
      %{ready: true, terminal_size: {width, height}} ->
        send(pid, {:minga_input, {:ready, width, height}})

      _ ->
        :ok
    end

    {:reply, :ok, new_state}
  end

  def handle_call(:terminal_size, _from, state) do
    {:reply, state.terminal_size, state}
  end

  def handle_call(:ready?, _from, state) do
    {:reply, state.ready, state}
  end

  def handle_call(:capabilities, _from, state) do
    {:reply, state.capabilities, state}
  end

  def handle_call(:output_pressure, _from, state) do
    {:reply, OutputPressure.stats(state.output_pressure), state}
  end

  def handle_call({:send_commands, commands}, _from, state) do
    {admission, state} = OutputHandler.admit_commands(state, commands)
    {:reply, admission, state}
  end

  def handle_call({:send_render_commands, commands, sent_at}, _from, state) do
    Telemetry.hop_latency(:send_commands, sent_at)
    {admission, state} = OutputHandler.admit_commands(state, commands)
    {:reply, admission, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Protocol.decode_event(data) do
      {:ok, {:ready, width, height, caps, protocol_version}} ->
        handle_ready(state, width, height, caps, protocol_version)

      {:ok, {:ready, width, height}} ->
        new_state = %{state | ready: true, terminal_size: {width, height}}
        broadcast(new_state.subscribers, {:minga_input, {:ready, width, height}})
        {:noreply, new_state}

      {:ok, {:capabilities_updated, caps}} ->
        new_state = %{state | capabilities: caps}
        broadcast(new_state.subscribers, {:minga_input, {:capabilities_updated, caps}})
        {:noreply, new_state}

      {:ok, {:resize, width, height}} ->
        new_state = %{state | terminal_size: {width, height}}
        broadcast(new_state.subscribers, {:minga_input, {:resize, width, height}})
        {:noreply, new_state}

      {:ok, {:frame_applied, generation, frame_seq} = event} ->
        {:noreply, OutputHandler.frame_applied(state, event, generation, frame_seq)}

      {:ok, {:log_message, level, text}} ->
        log_renderer_message(level, text)
        {:noreply, state}

      {:ok, event} ->
        broadcast(state.subscribers, {:minga_input, event})
        {:noreply, state}

      {:error, reason} ->
        Minga.Log.warning(
          :port,
          "Failed to decode event: #{inspect(reason)}, data: #{inspect(data)}"
        )

        {:noreply, state}
    end
  end

  def handle_info({:retry_frontend_output, token}, state),
    do: {:noreply, OutputHandler.retry(state, token)}

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    Minga.Log.info(:port, "Renderer: exited normally")
    maybe_stop_system(0)
    {:noreply, OutputHandler.disconnect(state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Minga.Log.error(:port, "Renderer: crashed (exit #{status})")
    maybe_stop_system(1)
    {:noreply, OutputHandler.disconnect(state)}
  end

  # In connected mode ({:fd, 0, 1}), stdin EOF means the GUI parent exited.
  # Shut down cleanly, same as a normal exit in spawn mode.
  def handle_info({port, :eof}, %{port: port} = state) do
    Minga.Log.info(:port, "GUI parent disconnected (stdin EOF)")
    maybe_stop_system(0)
    {:noreply, OutputHandler.disconnect(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    subscribers = Enum.reject(state.subscribers, &(&1 == pid))
    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ──

  @spec start_port(state(), fun()) :: state()
  defp start_port(%{port_mode: :connected} = state, port_opener) do
    # Connected mode: the GUI parent already set up stdin/stdout pipes.
    # Open fd 0 (stdin) and fd 1 (stdout) as an Erlang Port with the
    # same {:packet, 4} framing used in spawn mode. The entire protocol
    # layer (event decoding, render commands, subscriber broadcasting)
    # works identically over both transports.
    port = port_opener.({:fd, 0, 1}, [:binary, {:packet, 4}, :eof])
    %{state | port: port}
  end

  defp start_port(state, port_opener) do
    # Spawn mode: we're the parent. Launch the GUI binary as a child process.
    if File.exists?(state.renderer_path) do
      env = tty_env(state.tty_path)

      port =
        port_opener.(
          {:spawn_executable, state.renderer_path},
          [:binary, :exit_status, {:packet, 4}, :use_stdio, {:env, env}]
        )

      %{state | port: port}
    else
      state
    end
  end

  @spec tty_env(String.t() | nil) :: [{charlist(), charlist()}]
  defp tty_env(nil), do: []
  defp tty_env(path) when is_binary(path), do: [{~c"MINGA_TTY", String.to_charlist(path)}]

  @doc """
  Builds a `/dev/` path from the tty name returned by `ps -o tty=`.

  The format varies by OS and version:
  - macOS long form: `"ttys008"` → `"/dev/ttys008"`
  - macOS short form: `"s003"` → `"/dev/ttys003"`
  - Linux: `"pts/3"` → `"/dev/pts/3"`

  Checks if `/dev/{name}` exists first (handles long form and Linux).
  Falls back to `/dev/tty{name}` for short forms.

  Returns `nil` when the process has no controlling terminal. `ps -o tty=`
  reports this as all question marks: `"??"` on macOS, `"?"` on Linux. Without
  this guard we would build a bogus path like `/dev/tty?`, which the Go renderer
  cannot open and crashes on. Returning `nil` lets the renderer fall back to
  `/dev/tty`.
  """
  @spec tty_path_for(String.t()) :: String.t() | nil
  def tty_path_for(tty_name) do
    if no_controlling_tty?(tty_name) do
      nil
    else
      path = "/dev/#{tty_name}"

      if File.exists?(path) do
        path
      else
        "/dev/tty#{tty_name}"
      end
    end
  end

  @spec no_controlling_tty?(String.t()) :: boolean()
  defp no_controlling_tty?(tty_name) do
    trimmed = String.trim(tty_name)
    trimmed == "" or trimmed == String.duplicate("?", String.length(trimmed))
  end

  @spec log_renderer_message(String.t(), String.t()) :: :ok
  defp log_renderer_message("ERR", text), do: Minga.Log.error(:port, text)
  defp log_renderer_message("WARN", text), do: Minga.Log.warning(:port, text)
  defp log_renderer_message(_level, text), do: Minga.Log.info(:port, text)

  # Handle a `ready` handshake that carries the frontend's compiled-in
  # protocol_version. Only an exact match proceeds: a mismatch (including 0, a
  # frontend built before this mechanism) means the frontend was built against a
  # different wire contract, so the BEAM sends an explicit `protocol_error` and
  # does NOT mark it ready. This way the BEAM never streams frames the frontend
  # cannot decode (silent desync); the frontend displays the error and the
  # operator rebuilds it with `mix protocol.gen`.
  @spec handle_ready(
          state(),
          pos_integer(),
          pos_integer(),
          MingaEditor.Frontend.Capabilities.t(),
          non_neg_integer()
        ) :: {:noreply, state()}
  defp handle_ready(state, width, height, caps, protocol_version) do
    expected = Minga.Protocol.Opcodes.protocol_version()

    case protocol_version do
      ^expected ->
        new_state = %{state | ready: true, terminal_size: {width, height}, capabilities: caps}
        broadcast(new_state.subscribers, {:minga_input, {:ready, width, height}})
        {:noreply, new_state}

      other ->
        reject_protocol_mismatch(state, expected, other)
    end
  end

  @spec reject_protocol_mismatch(state(), non_neg_integer(), non_neg_integer()) ::
          {:noreply, state()}
  defp reject_protocol_mismatch(state, expected, actual) do
    message =
      "Protocol version mismatch: this frontend speaks protocol v#{actual} but the editor " <>
        "speaks v#{expected}. Rebuild the frontend (mix protocol.gen) to match the editor."

    Minga.Log.error(:port, message)

    state =
      if state.port do
        {_admission, state} =
          OutputHandler.write_control(state, Protocol.encode_protocol_error(message))

        state
      else
        state
      end

    {:noreply, %{state | ready: false}}
  end

  @spec broadcast([pid()], term()) :: :ok
  defp broadcast(subscribers, message) do
    Enum.each(subscribers, &send(&1, message))
  end

  @spec maybe_stop_system(non_neg_integer()) :: :ok
  defp maybe_stop_system(code) do
    if Application.get_env(:minga, :start_editor) do
      System.stop(code)
    end

    :ok
  end
end
