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
  @spec handle_continue(:open, WriterState.t()) ::
          {:noreply, WriterState.t()} | {:stop, term(), WriterState.t()}
  def handle_continue(:open, state) do
    case state.backend.open_writer(state.path, state.backend_opts) do
      {:ok, db} -> finish_open(state, db, state.backend.file_edit_events(db))
      {:error, reason} -> report_unavailable(state, reason)
    end
  end

  @spec finish_open(WriterState.t(), term(), {:ok, [EventRecord.t()]} | {:error, term()}) ::
          {:noreply, WriterState.t()} | {:stop, term(), WriterState.t()}
  defp finish_open(state, db, {:ok, events}) do
    send(state.owner, {:event_log_writer_ready, self(), events})
    {:noreply, WriterState.opened(state, db)}
  end

  defp finish_open(state, db, {:error, reason}) do
    _ = state.backend.close(db)
    report_unavailable(state, {:reconstruction_failed, reason})
  end

  @spec report_unavailable(WriterState.t(), term()) :: {:stop, term(), WriterState.t()}
  defp report_unavailable(state, reason) do
    send(state.owner, {:event_log_writer_unavailable, self(), reason})
    {:stop, {:shutdown, {:open_failed, reason}}, state}
  end

  @impl GenServer
  @spec handle_info(term(), WriterState.t()) ::
          {:noreply, WriterState.t()} | {:stop, term(), WriterState.t()}
  def handle_info({:write_event, token, %EventRecord{} = record}, state) do
    result = state.backend.insert(state.db, record)
    send(state.owner, {:event_log_writer_result, self(), token, record.event_type, result})
    {:noreply, state}
  end

  def handle_info({:delete_before, token, %DateTime{} = cutoff}, state) do
    result =
      case state.backend.delete_before(state.db, cutoff) do
        {:ok, deleted_count} ->
          case state.backend.file_edit_events(state.db) do
            {:ok, events} -> {:ok, deleted_count, events}
            {:error, reason} -> {:error, {:reload_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:delete_failed, reason}}
      end

    send(state.owner, {:event_log_retention_result, self(), token, result})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, owner, reason}, %{owner_ref: ref, owner: owner} = state) do
    {:stop, {:owner_terminated, reason}, state}
  end

  @impl GenServer
  @spec terminate(term(), WriterState.t()) :: :ok
  def terminate(_reason, %{db: nil}), do: :ok

  def terminate(_reason, state) do
    _ = state.backend.close(state.db)
    :ok
  end
end
