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

  Subscribers register via `subscribe/1` and receive messages as:

      {:minga_highlight, event}

  where `event` is one of the highlight response types from
  `Minga.Port.Protocol`.
  """

  use GenServer

  alias Minga.Port.Protocol

  @typedoc "Options for starting the parser manager."
  @type start_opt ::
          {:name, GenServer.name()}
          | {:parser_path, String.t()}

  defmodule State do
    @moduledoc false
    @enforce_keys [:parser_path]
    defstruct port: nil,
              subscribers: [],
              parser_path: "",
              ready: false

    @type t :: %__MODULE__{
            port: port() | nil,
            subscribers: [pid()],
            parser_path: String.t(),
            ready: boolean()
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

  # ── Server Callbacks ──

  @impl true
  @spec init(keyword()) :: {:ok, State.t()}
  def init(opts) do
    parser_path = Keyword.get(opts, :parser_path, default_parser_path())
    state = %State{parser_path: parser_path}
    {:ok, start_port(state)}
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), State.t()) :: {:reply, term(), State.t()}
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    subscribers = [pid | state.subscribers] |> Enum.uniq()
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl true
  @spec handle_cast(term(), State.t()) :: {:noreply, State.t()}
  def handle_cast({:send_commands, _commands}, %{port: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:send_commands, commands}, state) do
    batch = IO.iodata_to_binary(commands)
    Port.command(state.port, batch)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()}
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Protocol.decode_event(data) do
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
    {:noreply, %{state | port: nil, ready: false}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Minga.Log.error(:port, "Parser process exited with status #{status}")
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
