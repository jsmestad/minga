defmodule MingaAgent.EventLog.ControllableStore do
  @moduledoc "Deterministic event-log store backend controlled by the owning test process."

  @behaviour MingaAgent.EventLog.StoreBackend

  alias MingaAgent.EventLog.EventRecord

  @doc "Requests an open result from the configured test controller."
  @impl MingaAgent.EventLog.StoreBackend
  @spec open_writer(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def open_writer(path, opts) do
    controller = Keyword.fetch!(opts, :controller)
    send(controller, {:event_log_store_open, self(), path})

    receive do
      {:event_log_store_open_result, result} -> normalize_open_result(result, controller)
    end
  end

  @doc "Reports that the controlled connection closed."
  @impl MingaAgent.EventLog.StoreBackend
  @spec close(map()) :: :ok
  def close(%{controller: controller}) do
    send(controller, {:event_log_store_closed, self()})
    :ok
  end

  @doc "Requests a deterministic insert result from the test controller."
  @impl MingaAgent.EventLog.StoreBackend
  @spec insert(map(), EventRecord.t()) :: {:ok, pos_integer()} | {:error, term()}
  def insert(%{controller: controller}, %EventRecord{} = record) do
    send(controller, {:event_log_store_insert, self(), record})

    receive do
      {:event_log_store_insert_result, {:committed, event_id}} ->
        wait_after_commit(controller, record, event_id)

      {:event_log_store_insert_result, result} ->
        result
    end
  end

  @doc "Requests a deterministic retention result from the test controller."
  @impl MingaAgent.EventLog.StoreBackend
  @spec delete_before(map(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_before(%{controller: controller}, %DateTime{} = cutoff) do
    send(controller, {:event_log_store_delete_before, self(), cutoff})

    receive do
      {:event_log_store_delete_before_result, result} -> result
    end
  end

  @spec wait_after_commit(pid(), EventRecord.t(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp wait_after_commit(controller, record, event_id) do
    send(controller, {:event_log_store_committed, self(), record, event_id})

    receive do
      {:event_log_store_publish_result, result} -> result
    end
  end

  @spec normalize_open_result(:ok | {:error, term()}, pid()) ::
          {:ok, map()} | {:error, term()}
  defp normalize_open_result(:ok, controller), do: {:ok, %{controller: controller}}
  defp normalize_open_result({:error, _reason} = error, _controller), do: error
end
