defmodule MingaAgent.ArtifactStore do
  @moduledoc "Durable, bounded, session-authorized storage for exact streamed tool output."

  use GenServer

  alias MingaAgent.ArtifactStore.Capture
  alias MingaAgent.ArtifactStore.CaptureProgress
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias MingaAgent.ArtifactStore.Fetched
  alias MingaAgent.ArtifactStore.PinKey
  alias MingaAgent.ArtifactStore.State
  alias MingaAgent.ArtifactStore.Stored
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference

  @type server :: GenServer.server()
  @type error_reason ::
          :unauthorized
          | :unknown_reference
          | :expired
          | :invalid_range
          | :artifact_corrupt
          | :unknown_delivery
          | :delivery_in_progress
          | :record_in_use
          | :capture_byte_limit
          | :session_disk_quota
          | :root_disk_quota
          | :session_item_quota
          | :root_item_quota
          | :disk_full
          | :interrupted
          | :storage_unavailable
          | term()

  @doc "Starts one store for a durable session ID and explicit root quota actor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Begins or resumes a stable streamed capture."
  @spec begin(server(), CaptureSpec.t()) :: {:ok, Capture.t()} | {:error, error_reason()}
  def begin(server, %CaptureSpec{} = spec), do: GenServer.call(server, {:begin, spec})

  @doc "Appends at most 64KiB and optionally records chunk-relative item ends."
  @spec append(server(), Capture.t(), binary(), keyword()) ::
          {:ok, CaptureProgress.t()} | {:error, error_reason()}
  def append(server, %Capture{} = capture, chunk, opts \\ []) do
    GenServer.call(server, {:append, capture, chunk, opts})
  end

  @doc "Durably completes or marks a capture incomplete and returns its stable reference."
  @spec finish(server(), Capture.t(), :complete | {:incomplete, atom()}) ::
          {:ok, Stored.t()} | {:error, error_reason()}
  def finish(server, %Capture{} = capture, status) do
    GenServer.call(server, {:finish, capture, status})
  end

  @doc "Durably cancels one open capture and releases all of its quota reservations."
  @spec cancel(server(), Capture.t()) :: :ok | {:error, error_reason()}
  def cancel(server, %Capture{} = capture) do
    GenServer.call(server, {:cancel, capture}, :infinity)
  end

  @doc "Fetches exact immutable captured bytes for an authorized bounded range."
  @spec fetch(server(), Reference.t(), Range.t()) ::
          {:ok, Fetched.t()} | {:error, error_reason()}
  def fetch(server, %Reference{} = reference, %Range{} = range) do
    GenServer.call(server, {:fetch, reference, range})
  end

  @doc """
  Returns the retained capture for a canonical delivery key.

  A terminal capture means output capture is durable; it does not assert that
  the enclosing tool effect or result persistence has completed.
  """
  @spec lookup_delivery(server(), {:delivery, String.t(), String.t()}) ::
          {:ok, Stored.t()} | {:error, error_reason()}
  def lookup_delivery(server, {:delivery, checkpoint, call_id} = delivery_key)
      when is_binary(checkpoint) and is_binary(call_id) do
    GenServer.call(server, {:lookup_delivery, delivery_key}, :infinity)
  end

  def lookup_delivery(_server, _delivery_key), do: {:error, :unknown_delivery}

  @doc "Atomically and idempotently replaces one snapshot or task pin set."
  @spec pin(server(), PinKey.t() | tuple(), [Reference.t()], keyword()) ::
          :ok | {:error, error_reason()}
  def pin(server, pin_key, references, opts \\ []) do
    GenServer.call(server, {:pin, pin_key, references, opts})
  end

  @doc "Releases one complete pin set without deleting retained content."
  @spec release(server(), PinKey.t() | tuple()) :: :ok | {:error, error_reason()}
  def release(server, pin_key), do: GenServer.call(server, {:release, pin_key})
  @doc "Releases snapshot pins not named by the durable session JSON generation."
  @spec reconcile_snapshot_pins(server(), String.t() | nil) ::
          :ok | {:error, error_reason()}
  def reconcile_snapshot_pins(server, durable_generation) do
    GenServer.call(server, {:reconcile_snapshot_pins, durable_generation})
  end

  @doc "Explicitly removes only unpinned artifacts and returns the deletion count."
  @spec cleanup_unreferenced(server()) ::
          {:ok, non_neg_integer()} | {:error, error_reason()}
  def cleanup_unreferenced(server), do: GenServer.call(server, :cleanup_unreferenced, :infinity)

  @doc "Explicitly deletes this whole durable record namespace; ordinary process exit never does."
  @spec delete_record(server()) :: :ok | {:error, error_reason()}
  def delete_record(server), do: GenServer.call(server, :delete_record, :infinity)

  @impl GenServer
  @spec init(keyword()) :: {:ok, State.t()} | {:stop, term()}
  def init(opts) do
    Process.flag(:trap_exit, true)

    case State.open(opts) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  @spec handle_call(term(), GenServer.from(), State.t()) ::
          {:reply, term(), State.t()}
  def handle_call({:begin, spec}, _from, state) do
    {reply, next_state} = State.begin_capture(state, spec)
    {:reply, reply, next_state}
  end

  def handle_call({:append, capture, chunk, opts}, _from, state) do
    {reply, next_state} = State.append(state, capture, chunk, opts)
    {:reply, reply, next_state}
  end

  def handle_call({:finish, capture, status}, _from, state) do
    {reply, next_state} = State.finish(state, capture, status)
    {:reply, reply, next_state}
  end

  def handle_call({:cancel, capture}, _from, state) do
    {reply, next_state} = State.cancel(state, capture)
    {:reply, reply, next_state}
  end

  def handle_call({:fetch, reference, range}, _from, state) do
    {reply, next_state} = State.fetch(state, reference, range)
    {:reply, reply, next_state}
  end

  def handle_call({:lookup_delivery, delivery_key}, _from, state) do
    {reply, next_state} = State.lookup_delivery(state, delivery_key)
    {:reply, reply, next_state}
  end

  def handle_call({:pin, pin_key, references, opts}, _from, state) do
    {reply, next_state} = State.pin(state, pin_key, references, opts)
    {:reply, reply, next_state}
  end

  def handle_call({:release, pin_key}, _from, state) do
    {reply, next_state} = State.release(state, pin_key)
    {:reply, reply, next_state}
  end

  def handle_call({:reconcile_snapshot_pins, durable_generation}, _from, state) do
    {reply, next_state} = State.reconcile_snapshot_pins(state, durable_generation)
    {:reply, reply, next_state}
  end

  def handle_call(:cleanup_unreferenced, _from, state) do
    {reply, next_state} = State.cleanup_unreferenced(state)
    {:reply, reply, next_state}
  end

  def handle_call(:delete_record, _from, state) do
    case State.delete_record(state) do
      {reply, next_state, :keep} -> {:reply, reply, next_state}
      {reply, next_state, :stop} -> {:stop, :normal, reply, next_state}
    end
  end

  @impl GenServer
  @spec handle_info(term(), State.t()) :: {:noreply, State.t()}
  def handle_info({:DOWN, monitor, :process, owner_pid, _reason}, state) do
    {:noreply, State.owner_down(state, monitor, owner_pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  @spec terminate(term(), State.t()) :: :ok
  def terminate(_reason, state) do
    case State.close(state) do
      :ok ->
        :ok

      {:error, reason} ->
        Minga.Log.error(
          :agent,
          "Retained artifact namespace #{state.namespace} failed to close: #{inspect(reason)}"
        )
    end
  end
end
