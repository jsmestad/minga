defmodule Minga.Session.ControllableSwapBackend do
  @moduledoc "Deterministic swap backend whose preparation barrier is owned by one test process."

  @behaviour Minga.Session.Swap.Backend

  alias Minga.Session.Swap

  @typep prepared :: {
           controller :: pid(),
           worker :: pid(),
           generation :: non_neg_integer(),
           path :: String.t(),
           content :: binary(),
           Swap.Prepared.t(),
           controls :: keyword()
         }

  @doc "Blocks preparation until the configured controller supplies a result."
  @impl Minga.Session.Swap.Backend
  @spec prepare(String.t(), binary(), keyword()) :: {:ok, prepared()} | {:error, term()}
  def prepare(path, content, opts) do
    controller = Keyword.fetch!(opts, :controller)
    generation = Keyword.fetch!(opts, :generation)
    worker = self()

    case Keyword.get(opts, :prepare_barrier, :before_temp) do
      :before_temp ->
        send(controller, {:swap_prepare, worker, generation, path, content})
        prepare_after_release(controller, worker, generation, path, content, opts)

      :after_temp ->
        prepare_before_release(controller, worker, generation, path, content, opts)
    end
  end

  @spec prepare_after_release(pid(), pid(), non_neg_integer(), String.t(), binary(), keyword()) ::
          {:ok, prepared()} | {:error, term()}
  defp prepare_after_release(controller, worker, generation, path, content, opts) do
    case await_release(generation) do
      {:ok, controls} ->
        prepare_swap(controller, worker, generation, path, content, opts, controls)

      {:error, _reason} = error ->
        error
    end
  end

  @spec prepare_before_release(pid(), pid(), non_neg_integer(), String.t(), binary(), keyword()) ::
          {:ok, prepared()} | {:error, term()}
  defp prepare_before_release(controller, worker, generation, path, content, opts) do
    case Swap.prepare(path, content, opts) do
      {:ok, prepared} ->
        send(controller, {:swap_temp_created, worker, generation, path, prepared.temporary_path})
        send(controller, {:swap_prepare, worker, generation, path, content})

        case await_release(generation) do
          {:ok, controls} ->
            {:ok, {controller, worker, generation, path, content, prepared, controls}}

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec await_release(non_neg_integer()) :: {:ok, keyword()} | {:error, term()}
  defp await_release(generation) do
    receive do
      {:swap_prepare_result, ^generation, :ok} ->
        {:ok, []}

      {:swap_prepare_result, ^generation, {:ok, controls}} when is_list(controls) ->
        {:ok, controls}

      {:swap_prepare_result, ^generation, {:error, _reason} = error} ->
        error
    end
  end

  @spec prepare_swap(
          pid(),
          pid(),
          non_neg_integer(),
          String.t(),
          binary(),
          keyword(),
          keyword()
        ) :: {:ok, prepared()} | {:error, term()}
  defp prepare_swap(controller, worker, generation, path, content, opts, controls) do
    case Swap.prepare(path, content, opts) do
      {:ok, prepared} ->
        {:ok, {controller, worker, generation, path, content, prepared, controls}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Publishes prepared data and reports the committed generation to the controller."
  @impl Minga.Session.Swap.Backend
  @spec publish(prepared()) :: :ok | {:error, term()}
  def publish({controller, worker, generation, path, content, prepared, controls}) do
    result = controlled_operation(controls, :publish, fn -> Swap.publish(prepared) end)
    send(controller, {:swap_published, self(), worker, generation, path, content, result})
    result
  end

  @doc "Discards obsolete prepared data and reports the discarded generation."
  @impl Minga.Session.Swap.Backend
  @spec discard(prepared()) :: :ok | {:error, term()}
  def discard({controller, worker, generation, path, content, prepared, controls}) do
    result = controlled_operation(controls, :discard, fn -> Swap.discard(prepared) end)
    send(controller, {:swap_discarded, self(), worker, generation, path, content, result})
    result
  end

  @doc "Deletes the published swap and reports the invalidation boundary."
  @impl Minga.Session.Swap.Backend
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(path, opts) do
    controller = Keyword.fetch!(opts, :controller)
    result = controlled_operation(opts, :delete, fn -> Swap.delete(path, opts) end)
    send(controller, {:swap_deleted, self(), path, result})
    result
  end

  @spec controlled_operation(keyword(), atom(), (-> :ok | {:error, term()})) ::
          :ok | {:error, term()}
  defp controlled_operation(controls, operation, default) do
    case Keyword.get(controls, operation, :run) do
      :run -> default.()
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end
end
