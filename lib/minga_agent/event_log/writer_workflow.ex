defmodule MingaAgent.EventLog.WriterWorkflow do
  @moduledoc """
  Performs the ordered database workflows requested of the EventLog writer.

  `MingaAgent.EventLog.Writer` remains the process boundary. This module owns the effectful open, insert, retention, and shutdown sequences so each GenServer callback only routes a message.
  """

  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.StoreBackend
  alias MingaAgent.EventLog.TouchedFiles
  alias MingaAgent.EventLog.WriterState

  @type callback_result ::
          {:noreply, WriterState.t()} | {:stop, term(), WriterState.t()}

  @doc "Opens the writer connection and loads the durable touched-file projection."
  @spec open(WriterState.t()) :: callback_result()
  def open(state) do
    case state.backend.open_writer(state.path, state.backend_opts) do
      {:ok, db} -> finish_open(state, db, state.backend.load_touched_files(db))
      {:error, reason} -> report_unavailable(state, reason)
    end
  end

  @doc "Persists one event and reports its correlated result to the EventLog owner."
  @spec write_event(WriterState.t(), reference(), EventRecord.t()) :: callback_result()
  def write_event(state, token, %EventRecord{} = record) when is_reference(token) do
    result = state.backend.insert(state.db, record)
    send(state.owner, {:event_log_writer_result, self(), token, record.event_type, result})
    {:noreply, state}
  end

  @doc "Deletes expired events, reloads touched files, and reports one correlated result."
  @spec delete_before(WriterState.t(), reference(), DateTime.t()) :: callback_result()
  def delete_before(state, token, %DateTime{} = cutoff) when is_reference(token) do
    result = retention_result(state, cutoff)
    send(state.owner, {:event_log_retention_result, self(), token, result})
    {:noreply, state}
  end

  @doc "Stops the writer after its EventLog owner terminates."
  @spec owner_down(WriterState.t(), term()) :: callback_result()
  def owner_down(state, reason), do: {:stop, {:owner_terminated, reason}, state}

  @doc "Closes the writer-owned database connection when one was opened."
  @spec terminate(WriterState.t()) :: :ok
  def terminate(%WriterState{db: nil}), do: :ok

  def terminate(state) do
    _ = state.backend.close(state.db)
    :ok
  end

  @spec finish_open(WriterState.t(), term(), StoreBackend.load_touched_files_result()) ::
          callback_result()
  defp finish_open(state, db, {:ok, %TouchedFiles{} = touched_files}) do
    send(state.owner, {:event_log_writer_ready, self(), touched_files})
    {:noreply, WriterState.opened(state, db)}
  end

  defp finish_open(state, db, {:error, {_kind, reason}}) do
    _ = state.backend.close(db)
    report_unavailable(state, {:reconstruction_failed, reason})
  end

  @spec report_unavailable(WriterState.t(), term()) :: callback_result()
  defp report_unavailable(state, reason) do
    send(state.owner, {:event_log_writer_unavailable, self(), reason})
    {:stop, {:shutdown, {:open_failed, reason}}, state}
  end

  @spec retention_result(WriterState.t(), DateTime.t()) ::
          {:ok, non_neg_integer(), TouchedFiles.t()}
          | {:error, {:delete_failed | :reload_failed, term()}}
          | {:error, {:rebuild_failed, TouchedFiles.rejection()}}
  defp retention_result(state, cutoff) do
    case state.backend.delete_before(state.db, cutoff) do
      {:ok, deleted_count} -> reload_touched_files(state, deleted_count)
      {:error, reason} -> {:error, {:delete_failed, reason}}
    end
  end

  @spec reload_touched_files(WriterState.t(), non_neg_integer()) ::
          {:ok, non_neg_integer(), TouchedFiles.t()}
          | {:error, {:reload_failed, term()}}
          | {:error, {:rebuild_failed, TouchedFiles.rejection()}}
  defp reload_touched_files(state, deleted_count) do
    case state.backend.load_touched_files(state.db) do
      {:ok, touched_files} -> {:ok, deleted_count, touched_files}
      {:error, {:read_failed, reason}} -> {:error, {:reload_failed, reason}}
      {:error, {:validation_failed, reason}} -> {:error, {:rebuild_failed, reason}}
    end
  end
end
