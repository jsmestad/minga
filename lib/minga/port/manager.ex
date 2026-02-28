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

  alias Minga.Port.Protocol

  require Logger

  @typedoc "Options for starting the port manager."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:renderer_path, String.t()}

  @typedoc "Internal state."
  @type state :: %{
          port: port() | nil,
          subscribers: [pid()],
          renderer_path: String.t(),
          ready: boolean(),
          terminal_size: {width :: pos_integer(), height :: pos_integer()} | nil
        }

  # ── Client API ──

  @doc "Starts the port manager."
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Sends a list of encoded render command binaries to the Zig renderer."
  @spec send_commands(GenServer.server(), [binary()]) :: :ok
  def send_commands(server \\ __MODULE__, commands) when is_list(commands) do
    GenServer.cast(server, {:send_commands, commands})
  end

  @doc "Subscribes the calling process to receive input events."
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc "Returns the terminal size as `{width, height}`, or nil if not yet ready."
  @spec terminal_size(GenServer.server()) :: {pos_integer(), pos_integer()} | nil
  def terminal_size(server \\ __MODULE__) do
    GenServer.call(server, :terminal_size)
  end

  @doc "Returns whether the Zig renderer has sent its ready signal."
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server \\ __MODULE__) do
    GenServer.call(server, :ready?)
  end

  # ── Server Callbacks ──

  @impl true
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    renderer_path = Keyword.get(opts, :renderer_path, default_renderer_path())

    state = %{
      port: nil,
      subscribers: [],
      renderer_path: renderer_path,
      ready: false,
      terminal_size: nil
    }

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

  @impl true
  @spec handle_cast(term(), state()) :: {:noreply, state()}
  def handle_cast({:send_commands, commands}, %{port: nil} = state) do
    Logger.warning("Port not open, dropping #{length(commands)} commands")
    {:noreply, state}
  end

  def handle_cast({:send_commands, commands}, state) do
    Enum.each(commands, fn cmd ->
      Port.command(state.port, cmd)
    end)

    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Protocol.decode_event(data) do
      {:ok, {:ready, width, height}} ->
        Logger.info("Zig renderer ready: #{width}x#{height}")
        new_state = %{state | ready: true, terminal_size: {width, height}}
        broadcast(new_state.subscribers, {:minga_input, {:ready, width, height}})
        {:noreply, new_state}

      {:ok, {:resize, width, height}} ->
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

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Zig renderer exited with status #{status}")
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
      port =
        Port.open(
          {:spawn_executable, state.renderer_path},
          [:binary, :exit_status, {:packet, 4}, :use_stdio]
        )

      %{state | port: port}
    else
      Logger.warning("Renderer binary not found at #{state.renderer_path}")
      state
    end
  end

  @spec broadcast([pid()], term()) :: :ok
  defp broadcast(subscribers, message) do
    Enum.each(subscribers, &send(&1, message))
  end

  @spec default_renderer_path() :: String.t()
  defp default_renderer_path do
    # In a release (or Burrito binary), the renderer lives in priv/
    priv_path = Application.app_dir(:minga, "priv/minga-renderer")

    if File.exists?(priv_path) do
      priv_path
    else
      # Dev/test fallback: compiled Zig binary in the source tree
      Path.join([File.cwd!(), "zig", "zig-out", "bin", "minga-renderer"])
    end
  end
end
