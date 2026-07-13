defmodule MingaAgent.EventLog.Writer do
  @moduledoc """
  Single ordered SQLite writer for `MingaAgent.EventLog`.

  This process exclusively owns the write connection and executes at most one insert or retention operation at a time. It monitors its EventLog owner so the connection is closed when that owner terminates, including an untrappable kill.
  """

  use GenServer

  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.WriterState

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
  def handle_continue(:open, state) do
    case state.backend.open_writer(state.path, state.backend_opts) do
      {:ok, db} ->
        send(state.owner, {:event_log_writer_ready, self()})
        {:noreply, WriterState.opened(state, db)}

      {:error, reason} ->
        send(state.owner, {:event_log_writer_unavailable, self(), reason})
        {:stop, {:shutdown, {:open_failed, reason}}, state}
    end
  end

  @impl GenServer
  def handle_info({:write_event, token, %EventRecord{} = record}, state) do
    result = state.backend.insert(state.db, record)
    send(state.owner, {:event_log_writer_result, self(), token, record.event_type, result})
    {:noreply, state}
  end

  def handle_info({:delete_before, token, %DateTime{} = cutoff}, state) do
    result = state.backend.delete_before(state.db, cutoff)
    send(state.owner, {:event_log_retention_result, self(), token, result})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, owner, reason}, %{owner_ref: ref, owner: owner} = state) do
    {:stop, {:owner_terminated, reason}, state}
  end

  @impl GenServer
  def terminate(_reason, %{db: nil}), do: :ok

  def terminate(_reason, state) do
    _ = state.backend.close(state.db)
    :ok
  end
end
