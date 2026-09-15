defmodule Minga.Test.SessionListingManager do
  @moduledoc false

  use GenServer

  @spec start_link([{String.t(), pid()}]) :: GenServer.on_start()
  def start_link(registrations), do: GenServer.start_link(__MODULE__, registrations)

  @impl true
  @spec init([{String.t(), pid()}]) :: {:ok, [{String.t(), pid()}]}
  def init(registrations), do: {:ok, registrations}

  @impl true
  def handle_call(:list_session_registrations, _from, registrations) do
    {:reply, registrations, registrations}
  end
end

defmodule Minga.Test.SessionListingSession do
  @moduledoc false

  use GenServer

  alias MingaAgent.SessionMetadata

  @type state :: %{metadata: SessionMetadata.t(), probe: pid()}

  @spec start_link({SessionMetadata.t(), pid()}) :: GenServer.on_start()
  def start_link({%SessionMetadata{} = metadata, probe}),
    do: GenServer.start_link(__MODULE__, {metadata, probe})

  @impl true
  @spec init({SessionMetadata.t(), pid()}) :: {:ok, state()}
  def init({metadata, probe}), do: {:ok, %{metadata: metadata, probe: probe}}

  @impl true
  def handle_call(:metadata, _from, state) do
    send(state.probe, {:metadata_queried, self()})
    {:reply, state.metadata, state}
  end

  def handle_call(:editor_snapshot, _from, state) do
    send(state.probe, {:snapshot_queried, self()})

    {:reply,
     %{
       status: state.metadata.status,
       pending_approval: nil,
       error: nil,
       active_tool_name: nil,
       credentials_configured: true
     }, state}
  end

  @impl true
  def handle_cast({:add_system_message, text, level}, state) do
    send(state.probe, {:system_message, self(), text, level})
    {:noreply, state}
  end
end
