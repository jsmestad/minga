defmodule MingaAgent.EventLog.Writer do
  @moduledoc """
  Single ordered SQLite writer for `MingaAgent.EventLog`.

  This process exclusively owns the write connection and executes at most one insert or retention operation at a time. It monitors its EventLog owner so the connection is closed when that owner terminates, including an untrappable kill.
  """

  use GenServer

  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.WriterState
  alias MingaAgent.EventLog.WriterWorkflow

  @doc "Starts an unlinked writer monitored by its EventLog owner."
  @spec start(pid(), keyword()) :: GenServer.on_start()
  def start(owner, opts) when is_pid(owner) do
    GenServer.start(__MODULE__, {owner, opts})
  end

  @impl GenServer
  @spec init({pid(), keyword()}) :: {:ok, WriterState.t(), {:continue, :open}}
  def init({owner, opts}) do
    Process.link(owner)

    state =
      WriterState.new(
        owner,
        Keyword.fetch!(opts, :path),
        Keyword.fetch!(opts, :backend),
        Keyword.get(opts, :backend_opts, [])
      )

    {:ok, state, {:continue, :open}}
  end

  @impl GenServer
  @spec handle_continue(:open, WriterState.t()) ::
          {:noreply, WriterState.t()} | {:stop, term(), WriterState.t()}
  def handle_continue(:open, state), do: WriterWorkflow.open(state)

  @impl GenServer
  @spec handle_info(term(), WriterState.t()) ::
          {:noreply, WriterState.t()} | {:stop, term(), WriterState.t()}
  def handle_info({:write_event, token, %EventRecord{} = record}, state) do
    WriterWorkflow.write_event(state, token, record)
  end

  def handle_info({:delete_before, token, %DateTime{} = cutoff}, state) do
    WriterWorkflow.delete_before(state, token, cutoff)
  end

  def handle_info({:DOWN, ref, :process, owner, reason}, %{owner_ref: ref, owner: owner} = state) do
    WriterWorkflow.owner_down(state, reason)
  end

  @impl GenServer
  @spec terminate(term(), WriterState.t()) :: :ok
  def terminate(_reason, state), do: WriterWorkflow.terminate(state)
end
