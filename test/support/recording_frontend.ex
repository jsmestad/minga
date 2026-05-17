defmodule Minga.Test.RecordingFrontend do
  @moduledoc """
  Minimal frontend adapter used by integration tests that need to observe raw command batches.
  """

  use GenServer

  @behaviour MingaEditor.Frontend.Adapter

  alias MingaEditor.Frontend.Capabilities

  @type start_opt ::
          {:owner, pid()}
          | {:width, pos_integer()}
          | {:height, pos_integer()}
          | {:capabilities, Capabilities.t()}

  @type state :: %{
          owner: pid(),
          width: pos_integer(),
          height: pos_integer(),
          capabilities: Capabilities.t(),
          commands: [binary()]
        }

  @impl MingaEditor.Frontend.Adapter
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl MingaEditor.Frontend.Adapter
  @spec send_commands(GenServer.server(), [binary()]) :: :ok
  def send_commands(server, commands) when is_list(commands) do
    GenServer.cast(server, {:send_commands, commands})
  end

  @impl MingaEditor.Frontend.Adapter
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server) do
    GenServer.call(server, {:subscribe, self()})
  end

  @impl MingaEditor.Frontend.Adapter
  @spec terminal_size(GenServer.server()) :: {pos_integer(), pos_integer()}
  def terminal_size(server) do
    GenServer.call(server, :terminal_size)
  end

  @impl MingaEditor.Frontend.Adapter
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server) do
    GenServer.call(server, :ready?)
  end

  @impl MingaEditor.Frontend.Adapter
  @spec capabilities(GenServer.server()) :: Capabilities.t()
  def capabilities(server) do
    GenServer.call(server, :capabilities)
  end

  @doc "Returns all commands recorded so far in receive order."
  @spec commands(GenServer.server()) :: [binary()]
  def commands(server) do
    GenServer.call(server, :commands)
  end

  @doc "Clears recorded commands."
  @spec reset(GenServer.server()) :: :ok
  def reset(server) do
    GenServer.call(server, :reset)
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       owner: Keyword.get(opts, :owner, self()),
       width: Keyword.get(opts, :width, 80),
       height: Keyword.get(opts, :height, 24),
       capabilities: Keyword.get(opts, :capabilities, Capabilities.default()),
       commands: []
     }}
  end

  @impl GenServer
  def handle_call({:subscribe, _pid}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:terminal_size, _from, state) do
    {:reply, {state.width, state.height}, state}
  end

  def handle_call(:ready?, _from, state) do
    {:reply, true, state}
  end

  def handle_call(:capabilities, _from, state) do
    {:reply, state.capabilities, state}
  end

  def handle_call(:commands, _from, state) do
    {:reply, Enum.reverse(state.commands), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | commands: []}}
  end

  @impl GenServer
  def handle_cast({:send_commands, commands}, state) do
    send(state.owner, {:frontend_commands, self(), commands})
    {:noreply, %{state | commands: Enum.reverse(commands) ++ state.commands}}
  end
end
