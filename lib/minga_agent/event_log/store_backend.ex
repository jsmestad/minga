defmodule MingaAgent.EventLog.StoreBackend do
  @moduledoc """
  Minimal contract used by the event-log writer.

  The production implementation is `MingaAgent.EventLog.Store`. The contract exists so the writer's admission, failure, and recovery behavior can be tested without controlling SQLite itself.
  """

  alias MingaAgent.EventLog.EventRecord

  @type db :: term()

  @doc "Opens the writer-owned database connection."
  @callback open_writer(String.t(), keyword()) :: {:ok, db()} | {:error, term()}

  @doc "Closes the writer-owned database connection."
  @callback close(db()) :: :ok | {:error, term()}

  @doc "Loads persisted file-edit events in durable order for projection reconstruction."
  @callback file_edit_events(db()) :: {:ok, [EventRecord.t()]} | {:error, term()}

  @doc "Inserts one event and returns its committed id."
  @callback insert(db(), EventRecord.t()) :: {:ok, pos_integer()} | {:error, term()}

  @doc "Deletes events older than a retention cutoff."
  @callback delete_before(db(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
end
