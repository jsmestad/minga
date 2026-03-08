defmodule Minga.Port.Manager do
  @moduledoc """
  GenServer that manages the Zig renderer Port process.

  Spawns the Zig binary as an Erlang Port with `{:packet, 4}` framing.
  Incoming input events from Zig are decoded and forwarded to subscribers.
  Outgoing render commands are encoded and sent to the Port.

  Subscribers register via `subscribe/1` and receive messages as:

      {:minga_input, event}

  where `event` is a `Minga.Port.Protocol.input_event()`.
  """

  use GenServer

  @behaviour Minga.Port.Frontend

  alias Minga.Port.Protocol

  require Logger

  @typedoc "Renderer backend."
  @type backend :: :tui | :gui

  @typedoc "Options for starting the port manager."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:renderer_path, String.t()}
          | {:backend, backend()}

  alias Minga.Port.Manager.State, as: PortState

  @typedoc "Internal state."
  @type state :: PortState.t()

  # ── Client API ──

  @doc "Starts the port manager."
  @impl Minga.Port.Frontend
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Sends a list of encoded render command binaries to the Zig renderer."
  @impl Minga.Port.Frontend
  @spec send_commands(GenServer.server(), [binary()]) :: :ok
  def send_commands(server \\ __MODULE__, commands) when is_list(commands) do
    GenServer.cast(server, {:send_commands, commands})
  end

  @doc "Subscribes the calling process to receive input events."
  @impl Minga.Port.Frontend
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc "Returns the terminal size as `{width, height}`, or nil if not yet ready."
  @impl Minga.Port.Frontend
  @spec terminal_size(GenServer.server()) :: {pos_integer(), pos_integer()} | nil
  def terminal_size(server \\ __MODULE__) do
    GenServer.call(server, :terminal_size)
  end

  @doc "Returns whether the Zig renderer has sent its ready signal."
  @impl Minga.Port.Frontend
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server \\ __MODULE__) do
    GenServer.call(server, :ready?)
  end

  @doc "Returns the frontend's reported capabilities."
  @impl Minga.Port.Frontend
  @spec capabilities(GenServer.server()) :: Minga.Port.Capabilities.t()
  def capabilities(server \\ __MODULE__) do
    GenServer.call(server, :capabilities)
  end

  # ── Server Callbacks ──

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    backend = Keyword.get(opts, :backend, :tui)
    renderer_path = Keyword.get(opts, :renderer_path, default_renderer_path(backend))

    state = %PortState{renderer_path: renderer_path}
    {:ok, start_port(state)}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()}
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    subscribers = [pid | state.subscribers] |> Enum.uniq()
    {:reply, :ok, %{state | subscribers: subscribers}}
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

  @impl true
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast({:send_commands, _commands}, %{port: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:send_commands, commands}, state) do
    batch = IO.iodata_to_binary(commands)
    Port.command(state.port, batch)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Debug: log all port data opcodes
    opcode = if byte_size(data) > 0, do: :binary.at(data, 0), else: nil

    File.write(
      "/tmp/minga_port.log",
      "opcode=0x#{if opcode, do: Integer.to_string(opcode, 16), else: "nil"} size=#{byte_size(data)}\n",
      [:append]
    )

    case Protocol.decode_event(data) do
      {:ok, {:ready, width, height, caps}} ->
        new_state = %{state | ready: true, terminal_size: {width, height}, capabilities: caps}
        broadcast(new_state.subscribers, {:minga_input, {:ready, width, height}})
        {:noreply, new_state}

      {:ok, {:ready, width, height}} ->
        new_state = %{state | ready: true, terminal_size: {width, height}}
        broadcast(new_state.subscribers, {:minga_input, {:ready, width, height}})
        {:noreply, new_state}

      {:ok, {:capabilities_updated, caps}} ->
        new_state = %{state | capabilities: caps}
        broadcast(new_state.subscribers, {:minga_input, {:capabilities_updated, caps}})
        {:noreply, new_state}

      {:ok, {:resize, width, height}} ->
        File.write(
          "/tmp/minga_resize.log",
          "RESIZE w=#{width} h=#{height} subs=#{length(state.subscribers)}\n",
          [:append]
        )

        new_state = %{state | terminal_size: {width, height}}
        broadcast(new_state.subscribers, {:minga_input, {:resize, width, height}})
        {:noreply, new_state}

      {:ok, event} ->
        broadcast(state.subscribers, {:minga_input, event})
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Failed to decode event: #{inspect(reason)}, data: #{inspect(data)}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    Logger.info("Zig renderer exited normally")
    Minga.Editor.log_to_messages("Renderer: exited normally")
    maybe_stop_system(0)
    {:noreply, %{state | port: nil, ready: false}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Zig renderer exited with status #{status}")
    Minga.Editor.log_to_messages("Renderer: crashed (exit #{status})")
    maybe_stop_system(1)
    {:noreply, %{state | port: nil, ready: false}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    subscribers = Enum.reject(state.subscribers, &(&1 == pid))
    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ──

  @spec start_port(state()) :: state()
  defp start_port(state) do
    if File.exists?(state.renderer_path) do
      env = tty_env()

      port =
        Port.open(
          {:spawn_executable, state.renderer_path},
          [:binary, :exit_status, {:packet, 4}, :use_stdio, {:env, env}]
        )

      %{state | port: port}
    else
      state
    end
  end

  # Detect the tty device path and pass it to the Zig renderer.
  #
  # When spawned as a BEAM Port, the child process loses access to /dev/tty
  # because Erlang's erl_child_setup calls setsid().  We detect the real tty
  # device path and pass it via the MINGA_TTY env var.
  #
  # Detection order:
  #   1. MINGA_TTY env var (set by bin/minga shell wrapper or user)
  #   2. `ps -o tty=` on the BEAM process (reads from kernel, not stdin)
  #   3. Empty (Zig renderer falls back to /dev/tty — may fail)
  @spec tty_env() :: [{charlist(), charlist()}]
  defp tty_env do
    tty_path = System.get_env("MINGA_TTY") || detect_tty()

    case tty_path do
      nil -> []
      path -> [{~c"MINGA_TTY", String.to_charlist(path)}]
    end
  end

  @spec detect_tty() :: String.t() | nil
  defp detect_tty do
    # `ps -o tty=` returns the controlling terminal's short name (e.g. "s003")
    # from the kernel — works even though System.cmd's child has piped stdin.
    with {output, 0} <- System.cmd("ps", ["-o", "tty=", "-p", to_string(:os.getpid())]),
         tty_short = String.trim(output),
         true <- tty_short != "" and tty_short != "??" do
      # macOS: "s003" → "/dev/ttys003"
      # Linux: "pts/3" → "/dev/pts/3"
      "/dev/tty#{tty_short}"
    else
      _ -> nil
    end
  end

  @spec broadcast([pid()], term()) :: :ok
  defp broadcast(subscribers, message) do
    Enum.each(subscribers, &send(&1, message))
  end

  @spec default_renderer_path(backend()) :: String.t()
  defp default_renderer_path(backend) do
    binary_name = renderer_binary_name(backend)

    # In a release (or Burrito binary), the renderer lives in priv/
    priv_path = Application.app_dir(:minga, "priv/#{binary_name}")

    if File.exists?(priv_path) do
      priv_path
    else
      # Dev/test fallback: look in the source tree.
      case backend do
        :gui ->
          # Swift GUI binary built by Xcode.
          # In dev, find it in DerivedData via the build settings output.
          find_xcode_build_product("minga-mac")

        _tui ->
          # Zig TUI binary in zig-out/bin/
          Path.join([File.cwd!(), "zig", "zig-out", "bin", "minga-renderer"])
      end
    end
  end

  # Only stop the BEAM when running as a real editor (not in tests).
  @spec maybe_stop_system(non_neg_integer()) :: :ok
  defp maybe_stop_system(code) do
    if Application.get_env(:minga, :start_editor) do
      System.stop(code)
    end

    :ok
  end

  @spec renderer_binary_name(backend()) :: String.t()
  defp renderer_binary_name(:tui), do: "minga-renderer"
  defp renderer_binary_name(:gui), do: "minga-mac"

  # Find the Xcode build product in DerivedData.
  # Uses `xcodebuild -showBuildSettings` to get the exact path.
  @spec find_xcode_build_product(String.t()) :: String.t()
  defp find_xcode_build_product(product_name) do
    project_path = Path.join([File.cwd!(), "macos", "Minga.xcodeproj"])

    case System.cmd(
           "xcodebuild",
           [
             "-project",
             project_path,
             "-scheme",
             "minga-mac",
             "-configuration",
             "Debug",
             "-showBuildSettings"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Regex.run(~r/BUILT_PRODUCTS_DIR = (.+)/, output) do
          [_, dir] -> Path.join(String.trim(dir), product_name)
          _ -> Path.join([File.cwd!(), "macos", "build", "Debug", product_name])
        end

      _ ->
        Path.join([File.cwd!(), "macos", "build", "Debug", product_name])
    end
  end
end
