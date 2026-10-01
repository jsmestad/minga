defmodule MingaAgent.ArtifactQuota do
  @moduledoc "Durable root actor for aggregate retained-artifact admission and accounting."

  use GenServer

  alias MingaAgent.ArtifactQuota.State
  alias MingaAgent.ArtifactQuota.Usage
  alias MingaAgent.ArtifactStore.Limits

  @type server :: GenServer.server()
  @type error_reason ::
          :invalid_limits
          | :invalid_namespace
          | :invalid_artifact_root
          | :artifact_root_in_use
          | :record_in_use
          | :root_namespace_limit
          | :root_disk_quota
          | :session_disk_quota
          | :root_item_quota
          | :session_item_quota
          | :root_artifact_limit
          | :session_artifact_limit
          | :root_open_capture_limit
          | :session_open_capture_limit
          | :storage_unavailable
          | term()

  @doc "Starts the sole quota actor for one artifact root."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Admits one namespace SQLite envelope before namespace files are created."
  @spec register_namespace(server(), String.t(), String.t(), keyword() | map()) ::
          {:ok, Limits.t()} | {:error, error_reason()}
  def register_namespace(server, root, namespace, limits \\ []) do
    GenServer.call(server, {:register_namespace, root, namespace, limits})
  end

  @doc "Reserves an artifact, open capture, headers, and any expected data bytes."
  @spec reserve_capture(server(), String.t(), non_neg_integer()) ::
          :ok | {:error, error_reason()}
  def reserve_capture(server, namespace, bytes) do
    GenServer.call(server, {:reserve_capture, namespace, bytes})
  end

  @doc "Reserves logical blob and index bytes before an append writes either file."
  @spec reserve_append(server(), String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, error_reason()}
  def reserve_append(server, namespace, bytes, items) do
    GenServer.call(server, {:reserve_append, namespace, bytes, items})
  end

  @doc "Releases unused conservative capture reservations without deleting the artifact."
  @spec release_reservation(server(), String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, error_reason()}
  def release_reservation(server, namespace, bytes, items) do
    GenServer.call(server, {:release_reservation, namespace, bytes, items})
  end

  @doc "Releases an open-capture slot after terminal metadata is durable."
  @spec finish_capture(server(), String.t()) :: :ok | {:error, error_reason()}
  def finish_capture(server, namespace) do
    GenServer.call(server, {:finish_capture, namespace})
  end

  @doc "Releases every reservation for one durably canceled open capture."
  @spec cancel_capture(server(), String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, error_reason()}
  def cancel_capture(server, namespace, bytes, items) do
    GenServer.call(server, {:cancel_capture, namespace, bytes, items})
  end

  @doc "Releases conservative artifact reservations after owned files are deleted."
  @spec release_artifact(server(), String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, error_reason()}
  def release_artifact(server, namespace, bytes, items) do
    GenServer.call(server, {:release_artifact, namespace, bytes, items})
  end

  @doc "Reconciles aggregate counters to exact durable namespace manifest facts."
  @spec reconcile_namespace(
          server(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok | {:error, error_reason()}
  def reconcile_namespace(server, namespace, bytes, items, artifacts, open_captures) do
    GenServer.call(
      server,
      {:reconcile_namespace, namespace, bytes, items, artifacts, open_captures}
    )
  end

  @doc "Reports whether a valid record namespace already has a durable quota row."
  @spec namespace_registered?(server(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, error_reason()}
  def namespace_registered?(server, root, namespace) do
    GenServer.call(server, {:namespace_registered, root, namespace})
  end

  @doc "Decharges one explicitly deleted record after its directory is durably absent."
  @spec delete_namespace(server(), String.t()) :: :ok | {:error, error_reason()}
  def delete_namespace(server, namespace) do
    GenServer.call(server, {:delete_namespace, namespace})
  end

  @doc "Returns aggregate logical counters without namespace identities or content access."
  @spec usage(server()) :: Usage.t()
  def usage(server), do: GenServer.call(server, :usage)

  @impl GenServer
  @spec init(keyword()) :: {:ok, State.t()} | {:stop, term()}
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, limits} <-
           Limits.new(
             Keyword.get(opts, :limits, []),
             MingaAgent.Config.artifact_limits()
           ),
         {:ok, state} <- State.new(Keyword.put(opts, :limits, limits)) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  @spec handle_call(term(), GenServer.from(), State.t()) :: {:reply, term(), State.t()}
  def handle_call({:register_namespace, root, namespace, limits}, _from, state) do
    {reply, next_state} = State.register_namespace(state, root, namespace, limits)
    {:reply, reply, next_state}
  end

  def handle_call({:namespace_registered, root, namespace}, _from, state) do
    {reply, next_state} = State.namespace_registered(state, root, namespace)
    {:reply, reply, next_state}
  end

  def handle_call({:reserve_capture, namespace, bytes}, _from, state) do
    {reply, next_state} = State.reserve_capture(state, namespace, bytes)
    {:reply, reply, next_state}
  end

  def handle_call({:reserve_append, namespace, bytes, items}, _from, state) do
    {reply, next_state} = State.reserve_append(state, namespace, bytes, items)
    {:reply, reply, next_state}
  end

  def handle_call({:finish_capture, namespace}, _from, state) do
    {reply, next_state} = State.finish_capture(state, namespace)
    {:reply, reply, next_state}
  end

  def handle_call({:cancel_capture, namespace, bytes, items}, _from, state) do
    {reply, next_state} = State.cancel_capture(state, namespace, bytes, items)
    {:reply, reply, next_state}
  end

  def handle_call({:release_artifact, namespace, bytes, items}, _from, state) do
    {reply, next_state} = State.release_artifact(state, namespace, bytes, items)
    {:reply, reply, next_state}
  end

  def handle_call({:release_reservation, namespace, bytes, items}, _from, state) do
    {reply, next_state} = State.release_reservation(state, namespace, bytes, items)
    {:reply, reply, next_state}
  end

  def handle_call(
        {:reconcile_namespace, namespace, bytes, items, artifacts, open_captures},
        _from,
        state
      ) do
    {reply, next_state} =
      State.reconcile_namespace(state, namespace, bytes, items, artifacts, open_captures)

    {:reply, reply, next_state}
  end

  def handle_call({:delete_namespace, namespace}, _from, state) do
    {reply, next_state} = State.delete_namespace(state, namespace)
    {:reply, reply, next_state}
  end

  def handle_call(:usage, _from, state), do: {:reply, State.usage(state), state}

  @impl GenServer
  @spec terminate(term(), State.t()) :: :ok
  def terminate(_reason, state) do
    case State.close(state) do
      :ok ->
        :ok

      {:error, reason} ->
        Minga.Log.error(
          :agent,
          "Retained artifact quota root #{state.root} failed to close: #{inspect(reason)}"
        )
    end
  end
end
