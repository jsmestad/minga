defmodule MingaAgent.EventLog.WriterWorkflow do
  @moduledoc """
  Performs the ordered database workflows requested of the EventLog writer.

  `MingaAgent.EventLog.Writer` remains the process boundary. This module owns the effectful open, insert, retention, and shutdown sequences so each GenServer callback only routes a message.
  """

  alias MingaAgent.EventLog.EventRecord
  alias MingaAgent.EventLog.WriterState

  @type callback_result ::
          {:noreply, WriterState.t()} | {:stop, term(), WriterState.t()}

  @doc "Opens the writer connection and reconstructs durable file-edit events."
  @spec open(WriterState.t()) :: callback_result()
  def open(state) do
    case state.backend.open_writer(state.path, state.backend_opts) do
      {:ok, db} -> finish_open(state, db, state.backend.file_edit_events(db))
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

  @doc "Deletes expired events, reloads the projection source, and reports one correlated result."
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

  @spec finish_open(WriterState.t(), term(), {:ok, [EventRecord.t()]} | {:error, term()}) ::
          callback_result()
  defp finish_open(state, db, {:ok, events}) do
    send(state.owner, {:event_log_writer_ready, self(), events})
    {:noreply, WriterState.opened(state, db)}
  end

  defp finish_open(state, db, {:error, reason}) do
    _ = state.backend.close(db)
    report_unavailable(state, {:reconstruction_failed, reason})
  end

  @spec report_unavailable(WriterState.t(), term()) :: callback_result()
  defp report_unavailable(state, reason) do
    send(state.owner, {:event_log_writer_unavailable, self(), reason})
    {:stop, {:shutdown, {:open_failed, reason}}, state}
  end

  @spec retention_result(WriterState.t(), DateTime.t()) ::
          {:ok, non_neg_integer(), [EventRecord.t()]}
          | {:error, {:delete_failed | :reload_failed, term()}}
  defp retention_result(state, cutoff) do
    case state.backend.delete_before(state.db, cutoff) do
      {:ok, deleted_count} -> reload_file_edits(state, deleted_count)
      {:error, reason} -> {:error, {:delete_failed, reason}}
    end
  end

  @spec reload_file_edits(WriterState.t(), non_neg_integer()) ::
          {:ok, non_neg_integer(), [EventRecord.t()]} | {:error, {:reload_failed, term()}}
  defp reload_file_edits(state, deleted_count) do
    case state.backend.file_edit_events(state.db) do
      {:ok, events} -> {:ok, deleted_count, events}
      {:error, reason} -> {:error, {:reload_failed, reason}}
    end
  end
end
